import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart' show FileOptions;

import '../../core/error/failure.dart';
import '../../core/supabase/supabase_client.dart';
import '../../models/earn_models.dart';

/// All earning actions go through server RPCs — the client only expresses intent.
class EarnRepository {
  Future<Map<String, dynamic>> _rpc(String fn,
      [Map<String, dynamic>? params]) async {
    try {
      final res = await Db.client.rpc(fn, params: params);
      return (res as Map).cast<String, dynamic>();
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  // ---- Daily reward --------------------------------------------------------
  Future<DailyStatus> dailyStatus() async =>
      DailyStatus.fromJson(await _rpc('daily_reward_status'));

  Future<Map<String, dynamic>> claimDaily({String? nonce}) =>
      _rpc('claim_daily_reward', {if (nonce != null) 'p_nonce': nonce});

  // ---- Mining --------------------------------------------------------------
  Future<MiningStatus> miningStatus() async =>
      MiningStatus.fromJson(await _rpc('mining_status'));

  Future<Map<String, dynamic>> startMining() => _rpc('start_mining');

  Future<Map<String, dynamic>> claimMining() => _rpc('claim_mining');

  // ---- Scratch -------------------------------------------------------------
  Future<Map<String, dynamic>> scratchStatus() => _rpc('scratch_status');

  Future<Map<String, dynamic>> scratchReveal(String cardId, {String? nonce}) =>
      _rpc('scratch_reveal',
          {'p_card_id': cardId, if (nonce != null) 'p_nonce': nonce});

  // ---- Ads -----------------------------------------------------------------
  Future<AdsConfig> adsConfig() async =>
      AdsConfig.fromJson(await _rpc('ads_config'));

  Future<Map<String, dynamic>> rewardAd(String nonce) =>
      _rpc('reward_ad', {'p_nonce': nonce});

  /// Ad funnel: begin an ad show → returns a server nonce that ties the funnel
  /// events together and later authorises a gated reward.
  Future<String> adBegin(String placement) async {
    final res = await _rpc('ad_begin', {'p_placement': placement});
    return res['nonce'] as String;
  }

  /// Advance the ad funnel state: 'impressed' or 'rewarded'.
  Future<void> adMark(String nonce, String state) =>
      _rpc('ad_mark', {'p_nonce': nonce, 'p_state': state});

  // ---- Quiz ----------------------------------------------------------------
  Future<DailyQuiz> quizToday() async =>
      DailyQuiz.fromJson(await _rpc('quiz_today'));

  Future<Map<String, dynamic>> submitQuiz(
          String quizId, List<Map<String, dynamic>> answers, {String? nonce}) =>
      _rpc('submit_quiz', {
        'p_quiz_id': quizId,
        'p_answers': answers,
        if (nonce != null) 'p_nonce': nonce,
      });

  // ---- Mining boost --------------------------------------------------------
  Future<Map<String, dynamic>> boostMining({String? nonce}) =>
      _rpc('boost_mining', {if (nonce != null) 'p_nonce': nonce});

  // ---- Tasks ---------------------------------------------------------------
  Future<List<TaskItem>> fetchTasks() async {
    try {
      final uid = Db.uid!;
      final tasks = await Db.client
          .from('tasks')
          .select()
          .eq('active', true)
          .order('position');
      final completions = await Db.client
          .from('task_completions')
          .select('task_id, state')
          .eq('user_id', uid);
      final stateByTask = {
        for (final c in (completions as List))
          c['task_id'] as String: c['state'] as String
      };
      return (tasks as List).map((e) {
        final m = (e as Map).cast<String, dynamic>();
        m['completion_state'] = stateByTask[m['id']];
        return TaskItem.fromJson(m);
      }).toList();
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  Future<Map<String, dynamic>> submitTask(String taskId,
          {Map<String, dynamic>? proof, String? nonce}) =>
      _rpc('submit_task', {
        'p_task_id': taskId,
        'p_proof': proof ?? {},
        if (nonce != null) 'p_nonce': nonce,
      });

  // ---- Contests ------------------------------------------------------------
  Future<List<Contest>> contests() async {
    final res = await Db.client.rpc('contests_overview');
    return (res as List)
        .map((e) => Contest.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
  }

  Future<void> startContest(String contestId) =>
      _rpc('start_contest', {'p_contest_id': contestId});

  Future<Map<String, dynamic>> claimContest(String participationId,
          {String? nonce}) =>
      _rpc('claim_contest', {
        'p_participation_id': participationId,
        if (nonce != null) 'p_nonce': nonce,
      });

  // ---- Invite milestones ---------------------------------------------------
  Future<InviteMilestonesOverview> inviteMilestones() async =>
      InviteMilestonesOverview.fromJson(await _rpc('invite_milestones_overview'));

  /// Auto-verify milestones need no proof. Manual milestones require a proof
  /// screenshot path uploaded to the private `proofs` bucket.
  Future<Map<String, dynamic>> claimInviteMilestone(String milestoneId,
          {String? proofPath}) =>
      _rpc('claim_invite_milestone', {
        'p_milestone_id': milestoneId,
        if (proofPath != null) 'p_proof_url': proofPath,
      });

  /// Upload proof image bytes to the user's folder in the `proofs` bucket and
  /// return the stored object path (used as the claim's proof reference).
  Future<String> uploadProof(String milestoneId, List<int> bytes,
      {String ext = 'jpg'}) async {
    try {
      final uid = Db.uid!;
      final path =
          '$uid/${milestoneId}_${DateTime.now().millisecondsSinceEpoch}.$ext';
      await Db.client.storage.from('proofs').uploadBinary(
            path,
            Uint8List.fromList(bytes),
            fileOptions: const FileOptions(upsert: true),
          );
      return path;
    } catch (e) {
      throw AppFailure.from(e);
    }
  }
}
