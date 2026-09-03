import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:bluechip_rewards/core/theme/app_colors.dart';
import 'package:bluechip_rewards/core/theme/app_palette.dart';
import '../../../core/widgets/common.dart';
import '../../../core/widgets/state_views.dart';
import '../../../providers/repositories.dart';
import '../admin_providers.dart';

class ManageQuizzesScreen extends ConsumerWidget {
  const ManageQuizzesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(adminQuizzesProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Manage Quizzes')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _newQuiz(context, ref),
        icon: const Icon(Icons.add_rounded),
        label: const Text('New quiz'),
      ),
      body: async.when(
        loading: () => const LoadingView(),
        error: (e, _) =>
            ErrorView(error: e, onRetry: () => ref.invalidate(adminQuizzesProvider)),
        data: (quizzes) {
          if (quizzes.isEmpty) {
            return const EmptyView(
                icon: Icons.psychology_rounded, title: 'No quizzes yet');
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 90),
            itemCount: quizzes.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (_, i) {
              final q = quizzes[i];
              final count = ((q['quiz_questions'] as List?)?.isNotEmpty ?? false)
                  ? ((q['quiz_questions'] as List).first['count'] ?? 0)
                  : 0;
              return SectionCard(
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(q['title'] ?? '',
                      style: const TextStyle(fontWeight: FontWeight.w800)),
                  subtitle: Text(
                      '${q['quiz_date']} • $count questions • ${q['reward']} BCP',
                      style: TextStyle(color: context.cx.textSecondary)),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'Delete quiz',
                        onPressed: () => _deleteQuiz(context, ref, q),
                        icon: const Icon(Icons.delete_outline_rounded,
                            color: AppColors.danger),
                      ),
                      const Icon(Icons.chevron_right_rounded),
                    ],
                  ),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => _QuizQuestionsScreen(
                          quizId: q['id'] as String, title: q['title'] ?? ''))),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _newQuiz(BuildContext context, WidgetRef ref) async {
    final title = TextEditingController();
    final reward = TextEditingController(text: '100');
    DateTime date = DateTime.now().toUtc();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('New quiz'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: title, decoration: const InputDecoration(labelText: 'Title')),
              const SizedBox(height: 10),
              TextField(controller: reward, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Reward (BCP)')),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(child: Text('Date: ${date.toIso8601String().split('T').first}')),
                  TextButton(
                    onPressed: () async {
                      final picked = await showDatePicker(
                        context: ctx,
                        initialDate: date,
                        firstDate: DateTime(2020),
                        lastDate: DateTime(2100),
                      );
                      if (picked != null) setState(() => date = picked);
                    },
                    child: const Text('Pick'),
                  ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Create')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    if (title.text.trim().isEmpty) {
      if (context.mounted) showSnack(context, 'A quiz title is required', error: true);
      return;
    }
    final rewardVal = int.tryParse(reward.text.trim());
    if (rewardVal == null || rewardVal < 0) {
      if (context.mounted) showSnack(context, 'Enter a valid reward (0 or more)', error: true);
      return;
    }
    try {
      final id = await ref.read(adminRepositoryProvider).createQuiz(
            date.toIso8601String().split('T').first,
            title.text.trim(),
            rewardVal,
          );
      ref.invalidate(adminQuizzesProvider);
      if (context.mounted) {
        showSnack(context, 'Quiz saved. Add questions to make it go live.');
        // Open the questions editor so the new quiz can be filled in — a quiz
        // with no questions is never served to users.
        Navigator.of(context).push(MaterialPageRoute(
            builder: (_) =>
                _QuizQuestionsScreen(quizId: id, title: title.text.trim())));
      }
    } catch (e) {
      // Real error surfaced — never a fake success.
      if (context.mounted) showSnack(context, _quizError('$e'), error: true);
    }
  }

  /// Confirm, then hard-delete the real quiz record. On success it disappears
  /// from the admin panel and becomes unavailable to users (server cascades its
  /// questions + attempts). On failure the real error is shown — no fake toast.
  Future<void> _deleteQuiz(
      BuildContext context, WidgetRef ref, Map<String, dynamic> q) async {
    final title = (q['title'] as String?) ?? 'this quiz';
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete quiz?'),
        content: Text(
            'Delete "$title" and all of its questions? This cannot be undone, '
            'and the quiz will no longer be available to users.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await ref.read(adminRepositoryProvider).deleteQuiz(q['id'] as String);
      ref.invalidate(adminQuizzesProvider);
      if (context.mounted) showSnack(context, 'Quiz deleted');
    } catch (e) {
      if (context.mounted) showSnack(context, _quizError('$e'), error: true);
    }
  }

  static String _quizError(String e) {
    if (e.contains('QUIZ_NOT_FOUND')) return 'That quiz no longer exists.';
    if (e.contains('NOT_ADMIN') || e.contains('FORBIDDEN')) {
      return 'You do not have permission to do that.';
    }
    return e;
  }
}

class _QuizQuestionsScreen extends ConsumerWidget {
  final String quizId;
  final String title;
  const _QuizQuestionsScreen({required this.quizId, required this.title});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(adminQuizQuestionsProvider(quizId));
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addQuestion(context, ref),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Add question'),
      ),
      body: async.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(
            error: e, onRetry: () => ref.invalidate(adminQuizQuestionsProvider(quizId))),
        data: (qs) {
          if (qs.isEmpty) {
            return const EmptyView(
                icon: Icons.quiz_rounded,
                title: 'No questions',
                subtitle: 'Add questions so the quiz can go live.');
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 90),
            itemCount: qs.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (_, i) {
              final q = qs[i];
              final options = (q['options'] as List).cast<dynamic>();
              final correct = (q['correct_index'] as num?)?.toInt() ?? 0;
              return SectionCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text('Q${i + 1}. ${q['question']}',
                              style: const TextStyle(fontWeight: FontWeight.w700)),
                        ),
                        IconButton(
                          onPressed: () async {
                            try {
                              await ref
                                  .read(adminRepositoryProvider)
                                  .deleteQuizQuestion(q['id'] as String);
                              ref.invalidate(adminQuizQuestionsProvider(quizId));
                            } catch (e) {
                              if (context.mounted) showSnack(context, '$e', error: true);
                            }
                          },
                          icon: const Icon(Icons.delete_outline_rounded,
                              color: AppColors.danger),
                        ),
                      ],
                    ),
                    for (var oi = 0; oi < options.length; oi++)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Row(
                          children: [
                            Icon(
                                oi == correct
                                    ? Icons.check_circle_rounded
                                    : Icons.circle_outlined,
                                size: 16,
                                color: oi == correct
                                    ? AppColors.success
                                    : context.cx.textSecondary),
                            const SizedBox(width: 8),
                            Expanded(child: Text('${options[oi]}')),
                          ],
                        ),
                      ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _addQuestion(BuildContext context, WidgetRef ref) async {
    final question = TextEditingController();
    final opts = List.generate(4, (_) => TextEditingController());
    int correct = 0;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('Add question'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: question, decoration: const InputDecoration(labelText: 'Question')),
                const SizedBox(height: 8),
                for (var i = 0; i < 4; i++)
                  Row(
                    children: [
                      Radio<int>(value: i, groupValue: correct, onChanged: (v) => setState(() => correct = v ?? 0)),
                      Expanded(
                        child: TextField(
                          controller: opts[i],
                          decoration: InputDecoration(labelText: 'Option ${i + 1}'),
                        ),
                      ),
                    ],
                  ),
                const SizedBox(height: 4),
                Text('Select the radio next to the correct answer',
                    style: TextStyle(color: context.cx.textSecondary, fontSize: 12)),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Add')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final options =
        opts.map((c) => c.text.trim()).where((t) => t.isNotEmpty).toList();
    if (question.text.trim().isEmpty || options.length < 2) {
      if (context.mounted) {
        showSnack(context, 'Need a question and at least 2 options', error: true);
      }
      return;
    }
    try {
      await ref.read(adminRepositoryProvider).addQuizQuestion(
          quizId, question.text.trim(), options, correct, 0);
      ref.invalidate(adminQuizQuestionsProvider(quizId));
    } catch (e) {
      if (context.mounted) showSnack(context, '$e', error: true);
    }
  }
}
