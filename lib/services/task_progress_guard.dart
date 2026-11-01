/// Stop repeated attempts when the visible interface never changes.
class TaskProgressGuard {
  String? _lastScreen;
  int _unchangedActions = 0;

  bool isStuck(String screen, String previousAction) {
    if (previousAction.isEmpty || screen != _lastScreen) {
      _unchangedActions = 0;
    } else if (previousAction != 'wait') {
      _unchangedActions++;
    }
    _lastScreen = screen;
    return _unchangedActions >= 3;
  }
}
