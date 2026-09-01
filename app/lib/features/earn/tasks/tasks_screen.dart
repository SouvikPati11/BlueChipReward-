import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/theme/app_colors.dart';
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

  Future<void> _do(TaskItem task) async {
    // Open the action link first (visit / join), then submit for reward.
    if (task.actionUrl != null && task.actionUrl!.isNotEmpty) {
      final uri = Uri.tryParse(task.actionUrl!);
      if (uri != null) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    }
    setState(() => _busyId = task.id);
    try {
      final res =
          await ref.read(earnRepositoryProvider).submitTask(task.id);
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
            'Submitted for review. You\'ll be rewarded once verified.');
      }
    } catch (e) {
      if (mounted) showSnack(context, '$e', error: true);
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tasksAsync = ref.watch(tasksProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Tasks')),
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
                  onTap: () => _do(tasks[i]),
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
  final VoidCallback onTap;
  const _TaskCard({required this.task, required this.busy, required this.onTap});

  @override
  Widget build(BuildContext context) {
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
                  color: AppColors.info.withOpacity(.12),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(Icons.task_alt_rounded,
                    color: AppColors.info),
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
          if (task.isDone)
            const Pill('Completed', color: AppColors.success, icon: Icons.check)
          else if (task.isPending)
            const Pill('Pending review',
                color: AppColors.warning, icon: Icons.hourglass_bottom_rounded)
          else
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: busy ? null : onTap,
                style: ElevatedButton.styleFrom(
                    minimumSize: const Size.fromHeight(46)),
                icon: busy
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : Icon(task.actionUrl != null
                        ? Icons.open_in_new_rounded
                        : Icons.play_arrow_rounded),
                label: Text(task.autoVerify ? 'Start & claim' : 'Start task'),
              ),
            ),
        ],
      ),
    );
  }
}
