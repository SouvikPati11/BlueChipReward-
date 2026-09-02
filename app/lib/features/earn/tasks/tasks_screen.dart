import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/ad_gate.dart';
import '../../../core/widgets/banner_ad_bar.dart';
import '../../../core/widgets/common.dart';
import '../../../core/widgets/state_views.dart';
import '../../../models/earn_models.dart';
import '../../../providers/data_providers.dart';
import '../../../providers/repositories.dart';
import 'package:bluechip_rewards/core/theme/app_palette.dart';

class TasksScreen extends ConsumerStatefulWidget {
  const TasksScreen({super.key});

  @override
  ConsumerState<TasksScreen> createState() => _TasksScreenState();
}

class _TasksScreenState extends ConsumerState<TasksScreen> {
  String? _busyId;

  /// §25: Opening the task link is NOT completion. It only launches the URL and
  /// leaves the task in its current state so the user can still submit proof.
  Future<void> _openLink(TaskItem task) async {
    if (task.actionUrl == null || task.actionUrl!.isEmpty) return;
    final uri = Uri.tryParse(task.actionUrl!);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      if (mounted) showSnack(context, 'Could not open link', error: true);
    }
  }

  /// Submit proof and claim. For auto-verify tasks this also opens the link
  /// first (single "Start & claim" flow). For manual tasks the user is expected
  /// to have already opened the link via [_openLink]; this only collects proof.
  Future<void> _submit(TaskItem task, {bool openLinkFirst = false}) async {
    // For a manual text task, collect the required proof BEFORE anything else.
    Map<String, dynamic>? proof;
    if (!task.autoVerify && task.proofMethod == 'text') {
      final text = await _askProofText(task);
      if (text == null) return; // cancelled
      proof = {'text': text};
    }

    // Auto-verify convenience: open the action link as part of the claim.
    if (openLinkFirst) {
      await _openLink(task);
    }

    setState(() => _busyId = task.id);
    try {
      final repo = ref.read(earnRepositoryProvider);

      // Screenshot proof: pick + upload to the private proofs bucket.
      if (!task.autoVerify && task.proofMethod == 'screenshot') {
        final picker = ImagePicker();
        final picked = await picker.pickImage(
            source: ImageSource.gallery, imageQuality: 70, maxWidth: 1600);
        if (picked == null) {
          setState(() => _busyId = null);
          return;
        }
        final bytes = await picked.readAsBytes();
        final ext = picked.name.contains('.')
            ? picked.name.split('.').last.toLowerCase()
            : 'jpg';
        final path = await repo.uploadProof(task.id, bytes, ext: ext);
        proof = {'screenshot_url': path};
      }

      // Optional rewarded-ad requirement.
      String? nonce;
      if (task.requiresAd) {
        nonce = await runRewardedGate(ref, 'tasks');
      }

      final res = await repo.submitTask(task.id, proof: proof, nonce: nonce);
      ref.invalidate(tasksProvider);
      ref.invalidate(walletProvider);
      ref.invalidate(transactionsProvider);
      final state = res['state'] as String;
      if (!mounted) return;
      if (state == 'rewarded') {
        await showRewardDialog(context,
            amount: (res['reward'] as num).toInt(), title: 'Task complete!');
      } else {
        showSnack(context,
            'Submitted for review. You\'ll be rewarded once approved.');
      }
    } catch (e) {
      if (mounted) showSnack(context, '$e', error: true);
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  /// Prompt for the admin-specified text (username/link) proof.
  Future<String?> _askProofText(TaskItem task) {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Submit proof'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(task.proofInstruction?.isNotEmpty == true
                ? task.proofInstruction!
                : 'Enter the requested detail'),
            const SizedBox(height: 10),
            TextField(
              controller: ctrl,
              autofocus: true,
              decoration: const InputDecoration(hintText: 'Your answer'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () {
                final t = ctrl.text.trim();
                if (t.isNotEmpty) Navigator.pop(context, t);
              },
              child: const Text('Submit')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tasksAsync = ref.watch(tasksProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Tasks')),
      bottomNavigationBar: const BannerAdBar(placement: 'tasks'),
      body: SafeArea(
        top: false,
        child: tasksAsync.when(
          loading: () => const LoadingView(),
          error: (e, _) =>
              ErrorView(error: e, onRetry: () => ref.invalidate(tasksProvider)),
          data: (tasks) {
            if (tasks.isEmpty) {
              return const EmptyView(
                icon: Icons.checklist_rounded,
                title: 'No tasks available',
                subtitle: 'New tasks are added regularly. Check back soon.',
              );
            }
            return RefreshIndicator(
              onRefresh: () async {
                ref.invalidate(tasksProvider);
                await ref.read(tasksProvider.future);
              },
              child: ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: tasks.length,
                separatorBuilder: (_, __) => const SizedBox(height: 12),
                itemBuilder: (_, i) => _TaskCard(
                  task: tasks[i],
                  busy: _busyId == tasks[i].id,
                  onOpenLink: () => _openLink(tasks[i]),
                  onSubmit: () => _submit(tasks[i]),
                  onStartAndClaim: () =>
                      _submit(tasks[i], openLinkFirst: true),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _TaskCard extends StatelessWidget {
  final TaskItem task;
  final bool busy;
  final VoidCallback onOpenLink;
  final VoidCallback onSubmit;
  final VoidCallback onStartAndClaim;
  const _TaskCard({
    required this.task,
    required this.busy,
    required this.onOpenLink,
    required this.onSubmit,
    required this.onStartAndClaim,
  });

  @override
  Widget build(BuildContext context) {
    final hasLink = task.actionUrl != null && task.actionUrl!.isNotEmpty;
    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: AppColors.info.withValues(alpha: .12),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(Icons.task_alt_rounded, color: AppColors.info),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(task.title,
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w800)),
                    if (task.description != null)
                      Text(task.description!,
                          style: TextStyle(color: context.cx.textSecondary)),
                  ],
                ),
              ),
              BcpAmount(task.reward, showSign: true),
            ],
          ),
          const SizedBox(height: 14),
          ..._buildActions(context, hasLink),
        ],
      ),
    );
  }

  List<Widget> _buildActions(BuildContext context, bool hasLink) {
    // Approved / rewarded → completed, nothing more to do.
    if (task.isDone) {
      return const [
        Pill('Completed', color: AppColors.success, icon: Icons.check),
      ];
    }

    // Pending admin review.
    if (task.isPending) {
      return const [
        Pill('Pending review',
            color: AppColors.warning, icon: Icons.hourglass_bottom_rounded),
      ];
    }

    // Auto-verify: single combined "Start & claim" (opens link then claims).
    if (task.autoVerify) {
      return [
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: busy ? null : onStartAndClaim,
            style:
                ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(46)),
            icon: busy
                ? const _BtnSpinner()
                : Icon(hasLink
                    ? Icons.open_in_new_rounded
                    : Icons.play_arrow_rounded),
            label: const Text('Start & claim'),
          ),
        ),
      ];
    }

    // Manual proof task. §25: the link persists and is independent of proof
    // submission. Rejected tasks show the same controls with a retry hint.
    final widgets = <Widget>[];

    if (task.isRejected) {
      widgets.add(Row(
        children: [
          const Icon(Icons.error_outline_rounded,
              size: 18, color: AppColors.danger),
          const SizedBox(width: 6),
          Expanded(
            child: Text('Rejected — please redo the task and submit again.',
                style: TextStyle(
                    color: AppColors.danger, fontWeight: FontWeight.w600)),
          ),
        ],
      ));
      widgets.add(const SizedBox(height: 10));
    }

    if (hasLink) {
      widgets.add(SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: busy ? null : onOpenLink,
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(46)),
          icon: const Icon(Icons.open_in_new_rounded),
          label: const Text('Open task link'),
        ),
      ));
      widgets.add(const SizedBox(height: 10));
    }

    widgets.add(SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: busy ? null : onSubmit,
        style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(46)),
        icon: busy
            ? const _BtnSpinner()
            : Icon(task.proofMethod == 'screenshot'
                ? Icons.upload_file_rounded
                : Icons.check_circle_outline_rounded),
        label: Text(task.isRejected ? 'Submit proof again' : 'Submit proof'),
      ),
    ));

    return widgets;
  }
}

class _BtnSpinner extends StatelessWidget {
  const _BtnSpinner();
  @override
  Widget build(BuildContext context) => const SizedBox(
        height: 18,
        width: 18,
        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
      );
}
