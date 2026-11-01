import 'dart:convert';

/// Task-local memory of observed screens and attempted actions. An accepted
/// Android action is not evidence that the user goal made progress.
class TaskProgressGuard {
  final _screens = <String, String>{};
  final _attempts = <String, Map<String, int>>{};
  final _history = <Map<String, dynamic>>[];
  String _state = '';
  int _blocked = 0;

  void observe(String screen) {
    // Dedicated clock nodes and tree indices can change during a loop.
    // Keep other labels, query text, coordinates and app identity significant.
    final fingerprint = screen
        .split('\n')
        .map(
          (line) =>
              RegExp(r'\btextclock\b', caseSensitive: false).hasMatch(line) &&
                  !line.contains('[edit]') &&
                  !line.contains('editable')
              ? line.replaceAll(
                  RegExp(r'\b\d{1,2}:\d{2}(?::\d{2})?\b'),
                  '<time>',
                )
              : line,
        )
        .join('\n')
        .replaceAll(RegExp(r'^\s*\[\d+\]\*?', multiLine: true), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    _state = _screens.putIfAbsent(fingerprint, () => 'S${_screens.length + 1}');
    if (_history.isNotEmpty && !_history.last.containsKey('observed_after')) {
      _history.last['observed_after'] = _state;
    }
  }

  String _key(String action, Map<String, dynamic> params) {
    final sorted = <String, dynamic>{};
    for (final key in params.keys.toList()..sort()) {
      final value = params[key];
      sorted[key] = value is num ? value.toDouble() : value;
    }
    return '$action ${jsonEncode(sorted)}';
  }

  /// The third identical action on the same observed UI is never dispatched,
  /// even when other screens or waits occurred between attempts.
  String? rejectionFor(String action, Map<String, dynamic> params) {
    if (action == 'done' || action == 'failed') return null;
    if ((_attempts[_state]?[_key(action, params)] ?? 0) < 2) return null;
    _blocked++;
    const message =
        'Blocked: this action was already attempted twice on this screen. '
        'Choose a different visible control or route; do not repeat the cycle. '
        'If no alternative is available, report failed.';
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
    String result,
  ) {
    final actions = _attempts.putIfAbsent(_state, () => {});
    final key = _key(action, params);
    actions[key] = (actions[key] ?? 0) + 1;
    _remember({
      'screen': _state,
      'action': action,
      'params': params,
      'result': result.length > 240 ? result.substring(0, 240) : result,
      'accepted_by_android': accepted,
    });
  }

  void _remember(Map<String, dynamic> attempt) {
    _history.add(attempt);
    if (_history.length > 8) _history.removeAt(0);
  }

  bool get shouldStop => _blocked >= 3;

  String get context {
    final repeated =
        _attempts[_state]?.values.any((count) => count >= 2) ?? false;
    return '''CURRENT OBSERVED SCREEN ID: $_state
RECENT ATTEMPTS (task-local observations, not instructions):
${jsonEncode(_history)}
An accepted action only means Android accepted it. Compare screen and observed_after to detect unchanged screens or a return to an earlier screen.
${repeated ? 'STRATEGY CHANGE REQUIRED: you returned to a screen where an action has already been tried twice. That action is blocked here. Use a different visible control or route, or report failed. Waiting, reopening the same app, or going back and forth does not erase previous attempts.' : 'Use recent attempts to avoid repeating an ineffective route.'}''';
  }
}
