import 'package:flutter_test/flutter_test.dart';
import 'package:private_agent/services/strategy_review.dart';
import 'package:private_agent/services/task_progress_guard.dart';

void main() {
  test(
    'subsets and recombinations of used fragments cannot renew progress',
    () {
      final review = StrategyReview();
      String? assess(List<String> evidence) => review.assess(
        {
          'outcome': 'continue',
          'assessment': 'Progress towards the target',
          'evidence': evidence,
        },
        screen: 'Category reached. Result identified. Detail opened.',
        activeStrategy: 'browse',
        plan: null,
        localRepair: false,
      );
      expect(assess(['Category reached', 'Result identified']), isNull);
      expect(assess(['Result identified']), 'review_evidence_reused');
      expect(
        assess(['Result identified', 'Category reached']),
        'review_evidence_reused',
      );
      expect(assess(['Category reached', 'Detail opened']), isNull);
    },
  );
  test('automatic alternative selection increments the recorded revision', () {
    final guard = TaskProgressGuard();
    guard.adoptPlan({
      'strategy': 'search',
      'alternatives': ['browse'],
    });
    final previous = guard.planRevision;
    guard.selectAlternative('Search exhausted');
    expect(guard.activeStrategy, 'browse');
    expect(guard.planRevision, previous + 1);
  });
  Map<String, dynamic> assessment(String outcome, String evidence) => {
    'outcome': outcome,
    'assessment': 'Observed a relevant milestone for the requested task',
    'evidence': evidence,
  };
  const nextPlan = {
    'strategy': 'browse categories',
    'subgoal': 'locate the relevant category',
    'expected_observation': 'a matching item in a category',
  };

  test(
    'different queries trigger assessment without claiming search failed',
    () {
      final review = StrategyReview();
      for (var i = 0; i < 3; i++) {
        review.recordDecision('type_text');
        review.observe(cycle: false, repairExhausted: false);
        expect(review.required, i == 2);
      }
      expect(review.reason, 'input_variants');
      expect(review.prompt, contains('NOT proof'));
    },
  );

  test('ordinary replans cannot erase the bounded decision checkpoint', () {
    final review = StrategyReview();
    for (var i = 0; i < 8; i++) {
      review.recordDecision(i.isEven ? 'click_at' : 'replan');
    }
    review.observe(cycle: false, repairExhausted: false);
    expect(review.required, true);
    expect(review.reason, 'strategy_budget');
  });

  test('productive long routes can continue with fresh current evidence', () {
    final review = StrategyReview();
    for (final milestone in ['Category reached', 'Requested item located']) {
      for (var i = 0; i < 8; i++) {
        review.recordDecision('scroll');
      }
      review.observe(cycle: false, repairExhausted: false);
      expect(review.required, true);
      expect(
        review.assess(
          assessment('continue', milestone),
          screen: milestone,
          activeStrategy: 'browse',
          plan: null,
          localRepair: false,
        ),
        isNull,
      );
      expect(review.required, false);
    }
  });

  test('reused evidence cannot renew budget even after a screen changes', () {
    final review = StrategyReview();
    expect(
      review.assess(
        assessment('continue', 'Category reached'),
        screen: 'Category reached',
        activeStrategy: 'browse',
        plan: null,
        localRepair: false,
      ),
      isNull,
    );
    expect(
      review.assess(
        assessment('continue', 'Category reached'),
        screen: 'New clock Category reached',
        activeStrategy: 'browse',
        plan: null,
        localRepair: false,
      ),
      'review_evidence_reused',
    );
  });

  test('stale evidence and incomplete alternatives are rejected', () {
    final review = StrategyReview();
    expect(
      review.assess(
        assessment('switch', 'Old screen'),
        screen: 'New screen',
        activeStrategy: 'search',
        plan: nextPlan,
        localRepair: false,
      ),
      'review_evidence_missing',
    );
    expect(
      review.assess(
        assessment('switch', 'New screen'),
        screen: 'New screen',
        activeStrategy: 'search',
        plan: {'strategy': 'rename'},
        localRepair: false,
      ),
      'review_alternative_required',
    );
    expect(review.exhausted, true);
  });

  test('cycle demands a different route; a valid switch is only a plan', () {
    final review = StrategyReview()
      ..observe(cycle: true, repairExhausted: false);
    expect(
      review.assess(
        assessment('continue', 'Empty results'),
        screen: 'Empty results',
        activeStrategy: 'search',
        plan: null,
        localRepair: false,
      ),
      'review_change_needed',
    );
    expect(
      review.assess(
        assessment('switch', 'Empty results'),
        screen: 'Empty results',
        activeStrategy: 'search',
        plan: nextPlan,
        localRepair: false,
      ),
      isNull,
    );
    expect(review.required, false);
  });

  test(
    'repair gets two decisions and cannot be invented or reused forever',
    () {
      final review = StrategyReview();
      expect(
        review.assess(
          assessment('repair', 'Input field'),
          screen: 'Input field',
          activeStrategy: 'search',
          plan: null,
          localRepair: false,
        ),
        'review_repair_unavailable',
      );
      expect(
        review.assess(
          assessment('repair', 'Input field'),
          screen: 'Input field',
          activeStrategy: 'search',
          plan: null,
          localRepair: true,
        ),
        isNull,
      );
      review.recordDecision('click_at');
      review.recordDecision('type_text');
      review.observe(cycle: false, repairExhausted: false);
      expect(review.required, true);
      expect(
        review.assess(
          assessment('repair', 'Input field'),
          screen: 'Input field',
          activeStrategy: 'search',
          plan: null,
          localRepair: true,
        ),
        'review_evidence_reused',
      );
    },
  );

  test(
    'implicit plan changes are reported and cannot clear an observed cycle',
    () {
      final guard = TaskProgressGuard();
      expect(guard.adoptPlan({'strategy': 'search'}), 'plan_accepted');
      expect(guard.adoptPlan(nextPlan), 'plan_review_required');
      expect(guard.activeStrategy, 'search');
      guard.observe('A');
      for (var i = 0; i < 2; i++) {
        guard.recordAttempt('forward', {}, true, 'accepted');
        guard.observe('B');
        guard.recordAttempt('press_back', {}, true, 'accepted');
        guard.observe('A');
      }
      expect(guard.needsReplan, true);
      guard.adoptPlan({'strategy': 'search'});
      expect(guard.needsReplan, true);
      guard.abandon('A different route is needed');
      guard.adoptPlan(nextPlan);
      expect(guard.needsReplan, false);
    },
  );
}
