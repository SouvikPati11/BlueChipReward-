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
