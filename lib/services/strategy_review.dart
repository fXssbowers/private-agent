import 'completion_verification.dart';

/// Task-local review checkpoints. UI novelty and plan renaming do not reset the
/// budget. Thresholds request an assessment; they do not prove strategy failure.
class StrategyReview {
  int _decisions = 0;
  int _textAttempts = 0;
  int _allowance = 8;
  int _rejections = 0;
  String? _trigger;
  final _usedProgressEvidence = <String>{};

  bool get required => _trigger != null;
  bool get exhausted => _rejections >= 2;
  int get decisions => _decisions;
  String get reason => _trigger ?? 'none';

  void observe({required bool cycle, required bool repairExhausted}) {
    if (cycle) {
      _trigger = 'cycle_detected';
    } else if (repairExhausted) {
      _trigger = 'repair_budget';
    } else if (_textAttempts >= 3) {
      _trigger = 'input_variants';
    } else if (_decisions >= _allowance) {
      _trigger = 'strategy_budget';
    }
  }

  void recordDecision(String action) {
    if (const {'done', 'failed', 'review_strategy'}.contains(action)) return;
    _decisions++;
    if (action == 'type_text') _textAttempts++;
  }

  void reject() => _rejections++;

  /// Null means accepted. Evidence grounds an assessment, not an independent
  /// semantic proof of progress. The model must still relate it to the goal.
  String? assess(
    Map<String, dynamic> params, {
    required String screen,
    required String? activeStrategy,
    required dynamic plan,
    required bool localRepair,
  }) {
    String? invalid(String code) {
      reject();
      return code;
    }

    final outcome = params['outcome'];
    if (!const {'continue', 'repair', 'switch', 'stop'}.contains(outcome) ||
        !_shortText(params['assessment'], 500)) {
      return invalid('review_invalid');
    }
    if (outcome == 'stop') return null;
    final evidence = CompletionEvidence.inspect(params['evidence'], screen);
    if (!evidence.accepted) return invalid('review_evidence_missing');
    if (outcome == 'continue' &&
        const {'cycle_detected', 'repair_budget'}.contains(_trigger)) {
      return invalid('review_change_needed');
    }
    if (outcome == 'repair' &&
        (!localRepair ||
            const {'cycle_detected', 'repair_budget'}.contains(_trigger))) {
      return invalid('review_repair_unavailable');
    }
    final fragments = params['evidence'] is String
        ? [params['evidence'] as String]
        : (params['evidence'] as List).cast<String>();
    final proofFragments = fragments
        .map((f) => f.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase())
        .toSet();
    if (outcome != 'switch' &&
        proofFragments.every(_usedProgressEvidence.contains)) {
      return invalid('review_evidence_reused');
    }
    if (outcome == 'switch' &&
        (!validPlan(plan) ||
            (plan['strategy'] as String).trim().toLowerCase() ==
                activeStrategy?.trim().toLowerCase())) {
      return invalid('review_alternative_required');
    }
    if (outcome != 'switch') {
      _usedProgressEvidence.addAll(proofFragments);
      while (_usedProgressEvidence.length > 128) {
        _usedProgressEvidence.remove(_usedProgressEvidence.first);
      }
    }
    _decisions = 0;
    _textAttempts = 0;
    _allowance = outcome == 'repair' ? 2 : 8;
    _trigger = null;
    _rejections = 0;
    return null;
  }

  static bool validPlan(dynamic plan) =>
      plan is Map &&
      _shortText(plan['strategy'], 180) &&
      _shortText(plan['subgoal'], 180) &&
      _shortText(plan['expected_observation'], 180);

  static bool _shortText(dynamic value, int limit) =>
      value is String && value.trim().length >= 3 && value.length <= limit;

  String get prompt =>
      '''
STRATEGY REVIEW: ${required ? 'REQUIRED — read-only checkpoint' : 'available when useful'}.
Decisions since last accepted review: $_decisions; text attempts: $_textAttempts.
Trigger: $reason. These are suspicion signals, NOT proof that the approach failed.
${required ? 'Do not dispatch UI actions or replan directly. Return review_strategy, done with grounded completion evidence, or failed.' : ''}
Assess the ORIGINAL goal, actual observations and outcomes, not just your intention.
Different queries, renamed plans, accepted clicks and changed layouts alone are not
meaningful progress. A search can span multiple content types. Do not infer that
an item is absent merely because search failed. Consider other observed navigation
routes; do not invent app-specific menus or assume Back restores an earlier state.
review_strategy params:
  outcome: continue | repair | switch | stop
  assessment: short explanation of new goal-relevant progress, the interaction
    failure, or why the alternative changes the mechanism rather than its wording
  evidence: 1–4 exact CURRENT visible fragments, or one exact string (3–512 chars)
continue needs NEW goal-relevant evidence; repeating the query is not evidence of
finding a target. repair is only for an observed interaction problem and grants
two decisions before another review. switch also requires a top-level plan with
strategy, subgoal, expected_observation and useful alternatives. Select a genuinely
different approach, not another name for the same search. stop honestly reports
that the task remains unresolved; it needs an assessment but no evidence.
This action changes task-local planning only. It does not operate the UI, confirm
task success, write a successful route or create a permanent memory lesson.
''';
}
