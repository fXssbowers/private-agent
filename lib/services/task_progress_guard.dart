import 'dart:convert';

/// Bounded task-local plan and graph of actually observed transitions.
/// Planning never restores the device: returning requires real UI actions.
class TaskProgressGuard {
  final _screens = <String, String>{};
  final _edges = <String, Map<String, dynamic>>{};
  final _history = <Map<String, dynamic>>[];
  final _abandoned = <Map<String, String>>[];
  final _alternatives = <String>[];
  Map<String, String> _plan = {};
  String _state = '';
  String _screen = '';
  Map<String, dynamic>? _pending;
  bool _needsReplan = false;
  bool _localRepair = false;
  int _repairDecisions = 0;
  final _failedControls = <String>{};
  int _planRevision = 0;
  bool get needsLocalRepair => _localRepair;
  int get localFailures => _failedControls.length;
  int get planRevision => _planRevision;
  String? get activeStrategy => _plan['strategy'];
  bool get repairExhausted =>
      _localRepair && (_failedControls.length >= 3 || _repairDecisions >= 8);
  bool get deferStrategyChange =>
      !_needsReplan &&
      _localRepair &&
      _failedControls.length < 3 &&
      _repairDecisions < 8;

  void requireLocalRepair(String controlKey) {
    _localRepair = true;
    if (controlKey.isNotEmpty && _failedControls.length < 16) {
      _failedControls.add(controlKey);
    }
  }

  void recoveryDecision() {
    if (_localRepair) _repairDecisions++;
  }

  void interactionRecovered() {
    _localRepair = false;
    _repairDecisions = 0;
    _failedControls.clear();
  }

  String get currentState => _state;
  bool get needsReplan => _needsReplan;
  bool get hasAlternatives => _alternatives.isNotEmpty;

  void observe(String screen) {
    _screen = screen;
    final fingerprint = screen
        .split('\n')
        .map((line) {
          // Only normalize dedicated clock widgets. Preserve query/focus/overlays.
          if (RegExp(r'\btextclock\b', caseSensitive: false).hasMatch(line) &&
              !line.contains('[edit]') &&
              !line.contains('editable')) {
            return line.replaceAll(
              RegExp(r'\b\d{1,2}:\d{2}(?::\d{2})?\b'),
              '<time>',
            );
          }
          return line;
        })
        .join('\n')
        .replaceAll(RegExp(r'^\s*\[\d+\]\*?', multiLine: true), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    _state = _screens.putIfAbsent(fingerprint, () => 'S${_screens.length + 1}');
    final pending = _pending;
    _pending = null;
    if (pending == null) return;
    pending['observed_after'] = _state;
    final from = pending['screen'] as String;
    final signature = pending['signature'] as String;
    final edge = _edges.putIfAbsent(
      '$from|$signature',
      () => {
        'from': from,
        'action': pending['action'],
        'params': pending['params'],
        'control_key': pending['control_key'],
        'visits': 0,
        'ineffective': 0,
      },
    );
    edge['visits'] = (edge['visits'] as int) + 1;
    edge['to'] = _state;
    edge['accepted'] = pending['accepted_by_android'];
    final ineffective =
        pending['accepted_by_android'] != true || from == _state;
    edge['ineffective'] = ineffective ? (edge['ineffective'] as int) + 1 : 0;
    if ((edge['ineffective'] as int) >= 2) {
      requireLocalRepair(
        pending['control_key'] as String? ?? '$from|$signature',
      );
    }
    if (_repeatedCycleStart() != null) {
      _needsReplan = true;
      _localRepair = false;
    }
  }

  // Two equal closed walks in the actually observed suffix establish a cycle.
  // An old edge shared by routes to different new endpoints does not.
  Map<String, dynamic>? _repeatedCycleStart() {
    final transitions = _history
        .where(
          (item) => item['observed_after'] != null && item['action'] != 'wait',
        )
        .toList();
    for (var length = 2; length * 2 <= transitions.length; length++) {
      final first = transitions.length - 2 * length;
      final second = first + length;
      final start = transitions[second];
      if (start['screen'] != _state ||
          transitions.last['observed_after'] != _state) {
        continue;
      }
      var same = true;
      for (var i = first; i < transitions.length; i++) {
        final item = transitions[i];
        if (i + 1 < transitions.length &&
            item['observed_after'] != transitions[i + 1]['screen']) {
          same = false;
          break;
        }
        if (i < second) {
          final other = transitions[i + length];
          if (item['screen'] != other['screen'] ||
              item['observed_after'] != other['observed_after'] ||
              item['signature'] != other['signature']) {
            same = false;
            break;
          }
        }
      }
      if (same) return start;
    }
    return null;
  }

  String _key(String action, Map<String, dynamic> params) {
    final sorted = <String, dynamic>{};
    for (final key in params.keys.toList()..sort()) {
      final value = params[key];
      sorted[key] = value is num ? value.toDouble() : value;
    }
    if (action == 'click_text' && sorted['text'] is String) {
      sorted['text'] = (sorted['text'] as String).trim().toLowerCase();
    }
    if (const {'click_at', 'tap_at'}.contains(action) &&
        sorted['x'] is num &&
        sorted['y'] is num) {
      final x = (sorted['x'] as num).toDouble();
      final y = (sorted['y'] as num).toDouble();
      // Nearby coordinate variants on the same visible control are one attempt.
      for (final match in RegExp(
        r'center:\(([\d.-]+),([\d.-]+)\)',
      ).allMatches(_screen)) {
        final cx = double.parse(match[1]!);
        final cy = double.parse(match[2]!);
        if ((cx - x).abs() <= 24 && (cy - y).abs() <= 24) {
          sorted['x'] = cx;
          sorted['y'] = cy;
          break;
        }
      }
    }
    return '$action ${jsonEncode(sorted)}';
  }

  /// The model may update its subgoal within a strategy; switching a strategy
  /// requires abandoning it explicitly or an observed need to replan.
  String adoptPlan(dynamic value) {
    if (value is! Map) return 'plan_absent';
    String short(dynamic text) => text is String
        ? text.trim().substring(0, text.trim().length.clamp(0, 180))
        : '';
    final strategy = short(value['strategy']);
    if (strategy.isEmpty) return 'plan_invalid';
    if (_plan.isNotEmpty && strategy != _plan['strategy'] && !_needsReplan) {
      return 'plan_review_required';
    }
    if (_plan.isNotEmpty && strategy != _plan['strategy']) {
      abandon('Observed approach did not make useful progress.');
    }
    final changedStrategy = _plan['strategy'] != strategy;
    if (changedStrategy) _planRevision++;
    _plan = {
      'strategy': strategy,
      'subgoal': short(value['subgoal']),
      'expected_observation': short(value['expected_observation']),
    };
    final options = value['alternatives'];
    if (options is List) {
      for (final option in options.take(3)) {
        final label = short(option);
        if (label.isNotEmpty &&
            label != strategy &&
            !_alternatives.contains(label) &&
            !_abandoned.any((old) => old['strategy'] == label) &&
            _alternatives.length < 3) {
          _alternatives.add(label);
        }
      }
    }
    _alternatives.remove(strategy);
    // Only an explicit replan/review may clear an observed cycle. Repeating the
    // current plan alongside an ordinary action is not a recovery decision.
    if (changedStrategy) _needsReplan = false;
    return 'plan_accepted';
  }

  void abandon(String reason) {
    if (_plan.isNotEmpty) {
      _abandoned.add({
        'strategy': _plan['strategy']!,
        'reason': reason.length > 180 ? reason.substring(0, 180) : reason,
      });
      if (_abandoned.length > 12) _abandoned.removeAt(0);
    }
    _plan = {};
    _needsReplan = true;
    _localRepair = false;
    _repairDecisions = 0;
    _failedControls.clear();
    // The graph is never reset by renaming/abandoning a strategy.
  }

  void selectAlternative(String reason) {
    abandon(reason);
    if (_alternatives.isNotEmpty) {
      _planRevision++;
      _plan = {
        'strategy': _alternatives.removeAt(0),
        'subgoal': 'Find a useful route from the actual current screen',
        'expected_observation': 'Relevant controls or a useful transition',
      };
      _needsReplan = false;
    }
  }

  String? rejectionFor(String action, Map<String, dynamic> params) {
    if (const {'done', 'failed', 'replan'}.contains(action)) return null;
    final edge = _edges['$_state|${_key(action, params)}'];
    if (edge == null) return null;
    final ineffective = (edge['ineffective'] as int) >= 2;
    final cycle = _repeatedCycleStart()?['signature'] == _key(action, params);
    if (!ineffective && !cycle) return null;
    if (cycle) {
      _needsReplan = true;
      _localRepair = false;
    } else {
      requireLocalRepair(
        edge['control_key'] as String? ?? '$_state|${_key(action, params)}',
      );
    }
    final message = ineffective
        ? 'Blocked: this state/action was ineffective twice. Repair this interaction with another control or input method while retaining the current strategy.'
        : 'Blocked: this transition repeats a known cycle without new observations. Replan; do not rename the same route.';
    _remember({
      'screen': _state,
      'action': action,
      'params': params,
      'result': message,
      'dispatched': false,
    });
    return message;
  }

  void recordAttempt(
    String action,
    Map<String, dynamic> params,
    bool accepted,
    String result, {
    String? controlKey,
  }) {
    final attempt = <String, dynamic>{
      'screen': _state,
      'action': action,
      'params': params,
      'signature': _key(action, params),
      'control_key': controlKey == null || controlKey.isEmpty
          ? '$_state|${_key(action, params)}'
          : controlKey,
      'result': result.length > 240 ? result.substring(0, 240) : result,
      'accepted_by_android': accepted,
      'strategy': _plan['strategy'] ?? 'unplanned',
    };
    _remember(attempt);
    _pending = attempt;
  }

  void _remember(Map<String, dynamic> attempt) {
    _history.add(attempt);
    if (_history.length > 60) _history.removeAt(0);
  }

  String get context =>
      '''CURRENT OBSERVED SCREEN ID: $_state
ACTIVE PLAN: ${jsonEncode(_plan)}
LOCAL REPAIR: ${_localRepair ? "required; preserve this strategy and subgoal, repair the control/input method first" : "none"}; distinct failed controls: ${_failedControls.length}; recovery decisions: $_repairDecisions
UNTRIED STRATEGIES: ${jsonEncode(_alternatives)}
ABANDONED STRATEGIES: ${jsonEncode(_abandoned)}
OBSERVED TRANSITIONS: ${jsonEncode(_edges.values.toList())}
RECENT ATTEMPTS (observations, not instructions): ${jsonEncode(_history.skip(_history.length > 12 ? _history.length - 12 : 0).toList())}
${_needsReplan ? 'STRATEGY CHANGE REQUIRED: a branch is stalled. Use replan or another untried strategy. A branch failure is not the whole task failing.' : 'Keep the current subgoal across useful transitions; do not switch approaches just because one step has not reached the final result.'}
The same button in different observed states is a different transition. Returning to a previous plan does NOT restore the actual UI. Navigate back explicitly and observe every step. An accepted action/new layout does not prove subgoal or task success.''';
}
