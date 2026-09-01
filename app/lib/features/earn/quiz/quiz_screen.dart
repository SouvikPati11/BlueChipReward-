import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/common.dart';
import '../../../core/widgets/state_views.dart';
import '../../../models/earn_models.dart';
import '../../../providers/data_providers.dart';
import '../../../providers/repositories.dart';
import 'package:bluechip_rewards/core/theme/app_palette.dart';

class QuizScreen extends ConsumerStatefulWidget {
  const QuizScreen({super.key});

  @override
  ConsumerState<QuizScreen> createState() => _QuizScreenState();
}

class _QuizScreenState extends ConsumerState<QuizScreen> {
  final Map<String, int> _answers = {};
  bool _submitting = false;

  Future<void> _submit(DailyQuiz quiz) async {
    setState(() => _submitting = true);
    try {
      final answers = _answers.entries
          .map((e) => {'question_id': e.key, 'answer_index': e.value})
          .toList();
      final res = await ref
          .read(earnRepositoryProvider)
          .submitQuiz(quiz.quizId!, answers);
      ref.invalidate(quizProvider);
      ref.invalidate(walletProvider);
      ref.invalidate(transactionsProvider);
      final reward = (res['reward'] as num).toInt();
      final correct = (res['correct'] as num).toInt();
      final total = (res['total'] as num).toInt();
      if (mounted) {
        showDialog(
          context: context,
          builder: (_) => AlertDialog(
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20)),
            title: const Text('Quiz complete'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                    correct == total
                        ? Icons.emoji_events_rounded
                        : Icons.check_circle_rounded,
                    color: AppColors.gold,
                    size: 56),
                const SizedBox(height: 12),
                Text('You got $correct of $total correct',
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                Text('+$reward BCP',
                    style: const TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w900,
                        color: AppColors.gold)),
              ],
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Done')),
            ],
          ),
        );
      }
    } catch (e) {
      if (mounted) showSnack(context, '$e', error: true);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final quizAsync = ref.watch(quizProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Daily Quiz')),
      body: SafeArea(
        top: false,
        child: quizAsync.when(
          loading: () => const LoadingView(),
          error: (e, _) =>
              ErrorView(error: e, onRetry: () => ref.invalidate(quizProvider)),
          data: (quiz) {
            if (!quiz.available) {
              return const EmptyView(
                icon: Icons.psychology_rounded,
                title: 'No quiz right now',
                subtitle: 'Check back later for today\'s quiz.',
              );
            }
            if (quiz.attempted) {
              return EmptyView(
                icon: Icons.verified_rounded,
                title: 'Already completed',
                subtitle:
                    'You scored ${quiz.resultCorrect}/${quiz.resultTotal} and earned ${quiz.resultReward} BCP today.',
              );
            }
            final allAnswered = _answers.length == quiz.questions.length;
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                SectionCard(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF8B5CF6), Color(0xFFA78BFA)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.psychology_rounded,
                          color: Colors.white, size: 36),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(quiz.title,
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 18,
                                    fontWeight: FontWeight.w800)),
                            Text('Up to ${quiz.reward} BCP',
                                style: TextStyle(
                                    color: Colors.white.withValues(alpha: .9))),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                for (var i = 0; i < quiz.questions.length; i++)
                  _QuestionCard(
                    index: i,
                    question: quiz.questions[i],
                    selected: _answers[quiz.questions[i].id],
                    onSelect: (idx) => setState(
                        () => _answers[quiz.questions[i].id] = idx),
                  ),
                const SizedBox(height: 8),
                ElevatedButton(
                  onPressed:
                      (!allAnswered || _submitting) ? null : () => _submit(quiz),
                  child: _submitting
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2.2, color: Colors.white))
                      : Text(allAnswered
                          ? 'Submit answers'
                          : 'Answer all questions'),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _QuestionCard extends StatelessWidget {
  final int index;
  final QuizQuestion question;
  final int? selected;
  final ValueChanged<int> onSelect;
  const _QuestionCard({
    required this.index,
    required this.question,
    required this.selected,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: SectionCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Q${index + 1}. ${question.question}',
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            for (var i = 0; i < question.options.length; i++)
              GestureDetector(
                onTap: () => onSelect(i),
                child: Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 14),
                  decoration: BoxDecoration(
                    color: selected == i
                        ? AppColors.primary.withValues(alpha: .1)
                        : context.cx.surfaceAlt,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                        color: selected == i
                            ? AppColors.primary
                            : context.cx.border),
                  ),
                  child: Row(
                    children: [
                      Icon(
                          selected == i
                              ? Icons.radio_button_checked_rounded
                              : Icons.radio_button_unchecked_rounded,
                          color: selected == i
                              ? AppColors.primary
                              : context.cx.textSecondary,
                          size: 20),
                      const SizedBox(width: 12),
                      Expanded(child: Text(question.options[i])),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
