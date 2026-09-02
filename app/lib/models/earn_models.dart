// Models for the earning features. Most are thin wrappers over the jsonb
// envelopes returned by the RPCs.

class DailyStatus {
  final bool claimedToday;
  final int currentStreak;
  final String nextAvailableUtc;

  /// Day-wise reward schedule for the 7-day cycle (server-configured).
  final List<int> days;
  final int nextStreak;
  final int nextAmount;

  const DailyStatus({
    required this.claimedToday,
    required this.currentStreak,
    required this.nextAvailableUtc,
    this.days = const [],
    this.nextStreak = 1,
    this.nextAmount = 0,
  });

  factory DailyStatus.fromJson(Map<String, dynamic> j) => DailyStatus(
        claimedToday: j['claimed_today'] as bool? ?? false,
        currentStreak: (j['current_streak'] as num?)?.toInt() ?? 0,
        nextAvailableUtc: j['next_available_utc'] as String? ?? '',
        days: ((j['days'] as List?) ?? const [])
            .map((e) => (e as num).toInt())
            .toList(),
        nextStreak: (j['next_streak'] as num?)?.toInt() ?? 1,
        nextAmount: (j['next_amount'] as num?)?.toInt() ?? 0,
      );
}

class MiningStatus {
  final bool active;
  final String? sessionId;
  final DateTime? startedAt;
  final DateTime? endsAt;
  final int ratePerHour;
  final int baseRate;
  final int accrued;
  final int claimable;
  final bool completed;
  final int sessionHours;
  final int boosts;
  final int maxBoosts;
  final int boostPct;
  final bool canBoost;
  final DateTime? nextBoostAt;
  final bool boostRequiresAd;

  const MiningStatus({
    required this.active,
    this.sessionId,
    this.startedAt,
    this.endsAt,
    required this.ratePerHour,
    this.baseRate = 0,
    this.accrued = 0,
    this.claimable = 0,
    this.completed = false,
    this.sessionHours = 24,
    this.boosts = 0,
    this.maxBoosts = 3,
    this.boostPct = 20,
    this.canBoost = false,
    this.nextBoostAt,
    this.boostRequiresAd = true,
  });

  factory MiningStatus.fromJson(Map<String, dynamic> j) => MiningStatus(
        active: j['active'] as bool? ?? false,
        sessionId: j['session_id'] as String?,
        startedAt: j['started_at'] != null
            ? DateTime.parse(j['started_at'] as String)
            : null,
        endsAt:
            j['ends_at'] != null ? DateTime.parse(j['ends_at'] as String) : null,
        ratePerHour: (j['rate_per_hour'] as num?)?.toInt() ?? 0,
        baseRate: (j['base_rate'] as num?)?.toInt() ??
            (j['rate_per_hour'] as num?)?.toInt() ?? 0,
        accrued: (j['accrued'] as num?)?.toInt() ?? 0,
        claimable: (j['claimable'] as num?)?.toInt() ?? 0,
        completed: j['completed'] as bool? ?? false,
        sessionHours: (j['session_hours'] as num?)?.toInt() ?? 24,
        boosts: (j['boosts'] as num?)?.toInt() ?? 0,
        maxBoosts: (j['max_boosts'] as num?)?.toInt() ?? 3,
        boostPct: (j['boost_pct'] as num?)?.toInt() ?? 20,
        canBoost: j['can_boost'] as bool? ?? false,
        nextBoostAt: j['next_boost_at'] != null
            ? DateTime.parse(j['next_boost_at'] as String)
            : null,
        boostRequiresAd: j['boost_requires_ad'] as bool? ?? true,
      );
}

class QuizQuestion {
  final String id;
  final String question;
  final List<String> options;

  const QuizQuestion(
      {required this.id, required this.question, required this.options});

  factory QuizQuestion.fromJson(Map<String, dynamic> j) => QuizQuestion(
        id: j['id'] as String,
        question: j['question'] as String,
        options:
            (j['options'] as List).map((e) => e.toString()).toList(growable: false),
      );
}

class DailyQuiz {
  final bool available;
  final String? quizId;
  final String title;
  final int reward;
  final List<QuizQuestion> questions;
  final bool attempted;
  final int? resultCorrect;
  final int? resultTotal;
  final int? resultReward;

  const DailyQuiz({
    required this.available,
    this.quizId,
    this.title = '',
    this.reward = 0,
    this.questions = const [],
    this.attempted = false,
    this.resultCorrect,
    this.resultTotal,
    this.resultReward,
  });

  factory DailyQuiz.fromJson(Map<String, dynamic> j) {
    final result = j['result'] as Map<String, dynamic>?;
    return DailyQuiz(
      available: j['available'] as bool? ?? false,
      quizId: j['quiz_id'] as String?,
      title: j['title'] as String? ?? '',
      reward: (j['reward'] as num?)?.toInt() ?? 0,
      questions: ((j['questions'] as List?) ?? [])
          .map((e) => QuizQuestion.fromJson(e as Map<String, dynamic>))
          .toList(),
      attempted: j['attempted'] as bool? ?? false,
      resultCorrect: (result?['correct'] as num?)?.toInt(),
      resultTotal: (result?['total'] as num?)?.toInt(),
      resultReward: (result?['reward'] as num?)?.toInt(),
    );
  }
}

class TaskItem {
  final String id;
  final String title;
  final String? description;
  final String type;
  final int reward;
  final String? actionUrl;
  final String? instructions;
  final bool autoVerify;
  final String? completionState; // null = not attempted

  const TaskItem({
    required this.id,
    required this.title,
    this.description,
    required this.type,
    required this.reward,
    this.actionUrl,
    this.instructions,
    required this.autoVerify,
    this.completionState,
  });

  factory TaskItem.fromJson(Map<String, dynamic> j) => TaskItem(
        id: j['id'] as String,
        title: j['title'] as String,
        description: j['description'] as String?,
        type: j['type'] as String? ?? 'link_visit',
        reward: (j['reward'] as num?)?.toInt() ?? 0,
        actionUrl: j['action_url'] as String?,
        instructions: j['instructions'] as String?,
        autoVerify: j['auto_verify'] as bool? ?? false,
        completionState: j['completion_state'] as String?,
      );

  bool get isDone =>
      completionState == 'rewarded' || completionState == 'verified';
  bool get isPending => completionState == 'pending';
}

/// Invite milestone (dedicated invite-reward system).
class InviteMilestone {
  final String id;
  final int threshold;
  final int reward;
  final bool autoVerify;
  final bool reached;
  final String state; // none | pending | credited | rejected
  final bool claimable;

  const InviteMilestone({
    required this.id,
    required this.threshold,
    required this.reward,
    required this.autoVerify,
    required this.reached,
    required this.state,
    required this.claimable,
  });

  factory InviteMilestone.fromJson(Map<String, dynamic> j) => InviteMilestone(
        id: j['id'] as String,
        threshold: (j['threshold'] as num?)?.toInt() ?? 0,
        reward: (j['reward'] as num?)?.toInt() ?? 0,
        autoVerify: j['auto_verify'] as bool? ?? true,
        reached: j['reached'] as bool? ?? false,
        state: j['state'] as String? ?? 'none',
        claimable: j['claimable'] as bool? ?? false,
      );

  bool get isCredited => state == 'credited';
  bool get isPending => state == 'pending';
  bool get isRejected => state == 'rejected';
}

class InviteMilestonesOverview {
  final int inviteCount;
  final List<InviteMilestone> milestones;
  const InviteMilestonesOverview(
      {required this.inviteCount, required this.milestones});

  factory InviteMilestonesOverview.fromJson(Map<String, dynamic> j) =>
      InviteMilestonesOverview(
        inviteCount: (j['invite_count'] as num?)?.toInt() ?? 0,
        milestones: ((j['milestones'] as List?) ?? const [])
            .map((e) =>
                InviteMilestone.fromJson((e as Map).cast<String, dynamic>()))
            .toList(),
      );
}
