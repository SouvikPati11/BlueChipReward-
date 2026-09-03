import 'dart:async';

import 'package:flutter/material.dart';

/// Counts down to [target] (a server-authoritative UTC timestamp), rebuilding
/// once a second. When it reaches zero it calls [onFinished] once and shows
/// [finishedChild]. Because it is driven by an absolute timestamp, closing and
/// reopening the app always shows the correct remaining time.
class CountdownText extends StatefulWidget {
  final DateTime? target;
  final TextStyle? style;
  final String prefix;
  final Widget? finishedChild;
  final VoidCallback? onFinished;
  const CountdownText({
    super.key,
    required this.target,
    this.style,
    this.prefix = '',
    this.finishedChild,
    this.onFinished,
  });

  @override
  State<CountdownText> createState() => _CountdownTextState();
}

class _CountdownTextState extends State<CountdownText> {
  Timer? _timer;
  bool _firedFinished = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Duration get _remaining {
    final t = widget.target;
    if (t == null) return Duration.zero;
    final d = t.difference(DateTime.now());
    return d.isNegative ? Duration.zero : d;
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    two(int n) => n.toString().padLeft(2, '0');
    if (h > 0) return '${two(h)}:${two(m)}:${two(s)}';
    return '${two(m)}:${two(s)}';
  }

  @override
  Widget build(BuildContext context) {
    final rem = _remaining;
    if (rem == Duration.zero) {
      if (!_firedFinished) {
        _firedFinished = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          widget.onFinished?.call();
        });
      }
      return widget.finishedChild ?? const SizedBox.shrink();
    }
    _firedFinished = false;
    return Text('${widget.prefix}${_fmt(rem)}', style: widget.style);
  }
}

/// Shared "daily cycle complete → come back tomorrow" panel used by Scratch,
/// Search and Watch-Ads. The countdown targets an absolute server timestamp
/// (start of the next UTC day), so it stays correct across app close/reopen,
/// logout/login, reinstall and device-clock changes. When it reaches zero it
/// calls [onFinished] (typically a reload) so the next cycle unlocks.
class CycleCompleteView extends StatelessWidget {
  final DateTime target;
  final String title;
  final VoidCallback? onFinished;
  final Color color;
  const CycleCompleteView({
    super.key,
    required this.target,
    required this.title,
    this.onFinished,
    this.color = const Color(0xFFF59E0B),
  });

  @override
  Widget build(BuildContext context) {
    final secondary =
        Theme.of(context).textTheme.bodyMedium?.color?.withValues(alpha: .7);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.event_available_rounded, size: 56, color: color),
        const SizedBox(height: 16),
        Text(title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        Text('Come back tomorrow', style: TextStyle(color: secondary)),
        const SizedBox(height: 14),
        CountdownText(
          target: target,
          onFinished: onFinished,
          style: TextStyle(
              fontSize: 34, fontWeight: FontWeight.w900, color: color),
          finishedChild: const Text('Available now',
              style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF16A34A))),
        ),
      ],
    );
  }
}
