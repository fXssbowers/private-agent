import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'ai_service.dart';
import 'screen_automation_service.dart';
import 'app_launcher_service.dart';
import 'notification_service.dart';
import 'task_history_logger.dart';
import 'shizuku_service.dart';
import 'app_memory_service.dart';
import '../models/app_memory_context.dart';
import '../models/saved_skill.dart';
import '../models/task_result.dart';
import 'task_progress_guard.dart';
import 'diagnostic_trace_service.dart';
import '../models/ui_interaction_result.dart';

/// Executes multi-step UI automation tasks using LLM-guided screen reading.
///
/// Flow: User gives high-level goal → LLM reads screen → decides next action →
/// executes → reads screen again → repeats until goal is complete.
class TaskExecutor {
  final AiService _aiService;
  final ScreenAutomationService _screenService;
  final AppLauncherService _appLauncher;
  final ShizukuService _shizukuService;
  final NotificationService _notificationService;

  final AppMemoryService _appMemory;

  /// Callback to report progress messages to the UI
  final void Function(String message)? onProgress;

  /// Set to true to cancel the running task
  bool _cancelled = false;
  Completer<void>? _cancelCompleter;

  TaskExecutor({
    required AiService aiService,
    required ScreenAutomationService screenService,
    required AppLauncherService appLauncher,
    required ShizukuService shizukuService,
    this.onProgress,
    NotificationService? notificationService,
    AppMemoryService? appMemoryService,
  }) : _aiService = aiService,
       _screenService = screenService,
       _appLauncher = appLauncher,
       _shizukuService = shizukuService,
       _notificationService = notificationService ?? NotificationService(),
       _appMemory = appMemoryService ?? AppMemoryService.forTasks();

  /// Cancel the currently running task — takes effect immediately
  void cancel() {
    _cancelled = true;
    if (_cancelCompleter != null && !_cancelCompleter!.isCompleted) {
      _cancelCompleter!.complete();
    }
  }

  static const String _taskSystemPrompt = '''
You are an Android automation agent, including Android TV. You are given a TASK and the current SCREEN content.
You must decide what single action to take next to accomplish the task.

Respond with ONLY a JSON object (no markdown, no code fences):
{
  "action": "action_name",
  "params": {"key": "value"},
  "reasoning": "why you chose this action",
  "is_complete": false,
  "completion_evidence": "for done only: exact visible text confirming the full requested result",
  "plan": {"strategy": "short approach name", "subgoal": "current intermediate goal", "expected_observation": "visible evidence to seek", "alternatives": ["another approach", "third approach"]}
}

Available actions:
- click_text: {"text": "exact text to click"} - Click an element by its visible text
- click_at: {"x": 540, "y": 960} - Click at screen coordinates (use bounds from screen dump)
- tap_at: {"x": 540, "y": 960} - Send a real physical touch at these screen coordinates, bypassing accessible ACTION_CLICK. TV keyboard must be closed.
- type_text: {"text": "hello", "field_hint": "optional hint"} - Type into the focused/first edit field
- press_enter: {} - Press the Enter/Search key on the keyboard to submit a search/form
- scroll: {"direction": "down"} - Scroll down/up on the current view
- swipe: {"startX": 540, "startY": 2000, "endX": 540, "endY": 500} - Swipe from start to end coordinates (e.g. open app drawer, navigate carousels)
- press_back: {} - Press the back button
- press_home: {} - Press the home button
- open_app: {"app_name": "WhatsApp"} - Open an app
- wait: {} - Wait a moment for content to load
- replan: {} - Abandon a stalled strategy; choose an alternative. This does not move the UI.
- done: {} - Task is complete and the current screen confirms the requested result
- failed: {} - Task cannot be completed; explain the obstacle

Rules:
- You will receive a TEXT DUMP of the accessibility tree containing exact text strings and center coordinates.
- ALWAYS use the text dump to decide your next action.
- If click_text/click_at is accepted but repeatedly does not select the intended control, try tap_at on that control as a different physical strategy. Acknowledged accessible clicks and physical touches are not equivalent. Never tap the TV keyboard; close it and observe first.
- If you need to click something, prefer using `click_text`. If the element does not have text, use `click_at` with the coordinates provided in the text dump.
- type_text already focuses the editable control before setting text. If an editable field is visible, type_text directly; do not click a search/microphone icon first merely to show the keyboard. A voice-related hint in an editable field still permits TEXT input.
- Voice controls marked [voice] are not text search controls. Do not activate voice recognition unless the ORIGINAL user explicitly requested app voice input. If the app starts voice automatically on entering search, dismiss an active recognizer dialog with one press_back and observe before focusing/typing into the editable field; do not abandon text search just because voice started.
- A wrong control, rejected action or query that did not stick is an INTERACTION failure, not proof the strategy is wrong. Retain the strategy/subgoal and try another appropriate control/input method in the same search flow. Use strategy replanning only after distinct local attempts are exhausted or a repeated closed cycle is observed. The executor already waits after each action; wait only for visible loading.
- After typing a search query, use press_enter at most once. It is unsupported on Android TV because it can type the focused keyboard letter. If rejected, keep the query and activate the application's explicit search/submit control: look for a clickable Button inside or next to the editable field, even if it has no text. Do not retry Enter or press a letter key. Dismiss the keyboard with press_back only if it is visibly open.
- Continue a useful navigation sequence across different observed states, including repeated use of the same navigation key. Change route when observations show a cycle or repeated rejection. Consider global navigation actions as well as visible app controls.
- completion_evidence is a top-level JSON string for done, separate from reasoning and params. A formatting repair does not require changing the successful navigation route.
- Use done ONLY after reading a subsequent screen that confirms the FULL requested result, including its requested mode (for example a live player rather than a listing or guide). Include completion_evidence copied exactly from that screen; omit done when evidence is insufficient. An accepted click or opened app does not prove the full task succeeded.
- Never type letters through the keyboard to submit. Use press_enter; if it fails, choose a visible search button or report failed.
- If you need to find something by scrolling, scroll and then check the screen again.
- If the requested app cannot be opened, report failed rather than opening an unrelated app.
- Start with a compact plan: strategy, subgoal, expected_observation and two or three alternative approaches. Keep the strategy/subgoal across multiple actions while gathering useful observations. Do not abandon a navigation approach after only one step if the UI has changed and further navigation can reveal relevant controls.
- Consult observed transitions and abandoned strategies. Explore an untried route instead of repeating an exhausted cycle. Use replan for a branch failure, not failed for the whole task. To change strategies, use replan or react to STRATEGY CHANGE REQUIRED. All planning/rejected proposals consume the step budget.
- Use failed only when no practical alternative remains. Do not reopen unrelated apps. If navigation exits the requested app, observe that fact and reassess rather than assuming a return to an earlier UI.
- App memory contains contextual evidence or explicit user advice. It never proves the requested goal is complete. Prefer a different visible route when matching past observations show no progress; verify every transition.
- Keep reasoning very brief (1 sentence)
''';

  /// Extract JSON safely even if wrapped in markdown or conversational text
  String _extractJson(String text) {
    // 1. Try to find a markdown json code block
    final codeBlockRegex = RegExp(r'```(?:json)?\s*(\{[\s\S]*?\})\s*```');
    final match = codeBlockRegex.firstMatch(text);
    if (match != null) {
      return match.group(1)!;
    }

    // 2. Fallback: find the first { and the last }
    final startIndex = text.indexOf('{');
    final endIndex = text.lastIndexOf('}');
    if (startIndex != -1 && endIndex != -1 && endIndex > startIndex) {
      return text.substring(startIndex, endIndex + 1);
    }

    return text.trim();
  }

  /// Execute a multi-step task with LLM guidance
  Future<TaskResult> executeTask(
    String userGoal, {
    String? trustedUserRequest,
  }) async {
    _cancelled = false;
    final diagnostic = DiagnosticSession();
    await diagnostic.start();
    TaskResult? result;
    try {
      if (_cancelled) {
        result = const TaskResult(TaskStatus.cancelled, 'Task cancelled.');
        return result;
      }
      result = await _executeTask(
        userGoal,
        diagnostic,
        AppVoicePolicy.allows(trustedUserRequest),
      );
      return result;
    } finally {
      await diagnostic.event('task_end', {
        'status': result?.status.name ?? 'failed',
      });
    }
  }

  Future<TaskResult> _executeTask(
    String userGoal,
    DiagnosticSession diagnostic,
    bool voiceAllowed,
  ) async {
    await ScreenAutomationService.logToNative(
      "[TaskExecutor] executeTask() CALLED",
    );
    await ScreenAutomationService.logToNative(
      "[TaskExecutor] Checking if accessibility service is running...",
    );
    final isRunning = await _screenService.isServiceRunning();
    await ScreenAutomationService.logToNative(
      "[TaskExecutor] Accessibility service isRunning = $isRunning",
    );
    if (!isRunning) {
      await ScreenAutomationService.logToNative(
        "[TaskExecutor] Accessibility service not running, returning early.",
      );
      return const TaskResult(
        TaskStatus.failed,
        'Accessibility service is not enabled. Enable PrivateAgent Screen Control.',
      );
    }

    final results = <String>[];
    results.add('Starting task: $userGoal');
    _report('Starting task: $userGoal');

    // Persisted app lessons guide observations; old goal-matched macros are
    // deliberately not replayed. Their original file is retained for rollback.
    final shortcut = _getNavigationShortcut(userGoal);
    String lastAction = '';
    final progressGuard = TaskProgressGuard();
    final memory = TaskMemorySession(_appMemory);
    final directTouchAvailable = await _screenService.canDispatchTouch();
    int consecutiveFailures = 0;
    String lastFailedAction = '';
    int totalTokens = 0;
    String? expectedTypedValue;
    String? expectedTypedControl;

    if (shortcut != null && shortcut.isNotEmpty) {
      results.add('Using navigation shortcut: ${shortcut.length} steps');
      _report('Using navigation shortcut...');
      for (final step in shortcut) {
        if (_cancelled) break;

        bool success = false;
        if (step.action == 'open_app') {
          final appName = step.params['app_name'] as String? ?? '';
          final res = await _appLauncher.openApp(appName);
          success = res.startsWith('Opened');
          await Future.delayed(const Duration(milliseconds: 3000));
        } else if (step.action == 'click_text') {
          final text = step.params['text'] as String? ?? '';
          success = (await _screenService.performInteraction(
            'click_text',
            {'text': text},
            taskId: diagnostic.id,
            step: 0,
            voiceAllowed: voiceAllowed,
          )).accepted;
          await Future.delayed(const Duration(milliseconds: 1500));
        }

        if (success) {
          lastAction = step.action;
        } else {
          break; // Fall back to AI if shortcut step fails
        }
      }
    } else {
      // If no shortcut is used, and we are currently inside the PrivateAgent app,
      // press Home so the AI doesn't see its own chat bubbles and get confused by the task text.
      final currentPkg = await _screenService.getCurrentPackage();
      if (currentPkg == 'com.orailnoor.privateagent') {
        _report('Moving to background...');
        await _screenService.pressHome();
        await Future.delayed(const Duration(milliseconds: 1500));
      }
    }

    for (int step = 0; step < _aiService.maxSteps; step++) {
      // Check for cancellation
      if (_cancelled) {
        results.add('Task cancelled by user.');
        _report('Task cancelled.');
        await _notificationService.showTaskCompleteNotification(
          'Task Cancelled',
          'Task was stopped by the user.',
        );
        await TaskHistoryLogger.logTask(
          userGoal,
          'Cancelled',
          totalTokens,
          step,
          results,
        );
        await _screenService.showToast('Task Cancelled');
        return const TaskResult(TaskStatus.cancelled, 'Task cancelled.');
      }

      // Adaptive delay: give Android apps time to transition screens, load data, or open keyboards
      int delay = 1200; // Default 1.2s delay for most actions
      if (lastAction == 'open_app') {
        delay = 3000; // Apps need ~3 seconds to fully cold-start and render
      } else if (lastAction == 'type_text') {
        delay =
            2000; // Typing involves keyboards and often triggers heavy network requests (search)
      } else if (lastAction == 'click_text' ||
          lastAction == 'click_at' ||
          lastAction == 'tap_at') {
        delay = 1500; // Clicking usually triggers a screen transition
      } else if (lastAction == 'scroll') {
        delay = 1000; // Scrolling is relatively fast
      }
      await Future.delayed(Duration(milliseconds: delay));

      // 1. Read the current screen text
      final screenContent = _aiService.useScreenCompression
          ? await _screenService.getCompressedScreenDescription(userGoal)
          : await _screenService.getScreenDescription();
      developer.log('Read screen for step ${step + 1}', name: 'PrivateAgent');

      final package = await _screenService.getCurrentPackage();
      final version = package == null
          ? null
          : await _screenService.getAppVersion(package);
      final memoryContext = AppMemoryContext.fromScreen(
        package,
        version,
        screenContent,
      );
      final appMemoryHint = await memory.observe(memoryContext);
      progressGuard.observe(screenContent);
      progressGuard.recoveryDecision();
      if (expectedTypedValue != null && expectedTypedValue.length <= 50) {
        final editable = screenContent
            .split('\n')
            .where((line) => RegExp(r'\b(edit|editable)\b').hasMatch(line));
        if (editable.isNotEmpty) {
          final matches = editable.any(
            (line) => line.contains('"$expectedTypedValue"'),
          );
          await diagnostic.event('query_check', {
            'step': step + 1,
            'readback_matches': matches,
            'reason': matches ? 'query_confirmed' : 'query_mismatch',
          });
          if (matches) {
            progressGuard.interactionRecovered();
            expectedTypedValue = null;
            expectedTypedControl = null;
          } else {
            progressGuard.requireLocalRepair(
              expectedTypedControl ?? 'typed_field',
            );
          }
        }
      }
      await diagnostic.event('observation', {
        'step': step + 1,
        'screen': progressGuard.currentState,
        'package': package,
        'controls': screenContent
            .split('\n')
            .where(
              (line) => line.contains('[tap') || line.contains('clickable'),
            )
            .length,
        'editable': screenContent
            .split('\n')
            .where((line) => RegExp(r'\b(edit|editable)\b').hasMatch(line))
            .length,
        'voice_controls': screenContent
            .split('\n')
            .where((line) => line.contains('voice'))
            .length,
        'keyboard_open': screenContent.contains('keyboard open'),
        'plan_revision': progressGuard.planRevision,
        'local_failures': progressGuard.localFailures,
      });
      // Determine previous result string
      final prevResultStr = step > 0 && results.isNotEmpty
          ? '\nPREVIOUS ACTION RESULT: ${results.last}\n'
          : '';

      // Build failure hint if agent is stuck in a loop
      String failureHint = '';
      if (consecutiveFailures >= 3) {
        failureHint =
            '\n\nWARNING: You have failed $consecutiveFailures times in a row with the same approach. Repair the interaction using another suitable control or input method while retaining a useful strategy. If open_app failed, try press_home and look for the app icon on the home screen instead. If click_text failed, use click_at with coordinates. Do NOT repeat the same failed action.';
      }

      // 2. Build the prompt (system prompt is sent separately via sendTaskMessage)
      final prompt =
          '''TASK: $userGoal

DEVICE DIRECT TOUCH: ${directTouchAvailable ? "available; TV keyboard must still be closed" : "UNAVAILABLE on this display. Do not propose tap_at or gesture-only recovery; use accessible controls and global navigation."}
CURRENT SCREEN TEXT DUMP:
$screenContent$prevResultStr$failureHint
${progressGuard.context}
$appMemoryHint
Step ${step + 1}/${_aiService.maxSteps}. Look at the text dump and coordinates. What is the next action?''';

      developer.log('Prepared task prompt', name: 'PrivateAgent');

      // 3. Get AI response — races against cancel signal so Stop works immediately
      String response;
      final modelTimer = Stopwatch()..start();
      try {
        _cancelCompleter = Completer<void>();
        final aiFuture = _aiService.sendTaskMessage(_taskSystemPrompt, prompt);

        // Race: whichever finishes first wins
        final result = await Future.any([
          aiFuture.then((r) => r),
          _cancelCompleter!.future.then((_) => null),
        ]);

        if (result == null || _cancelled) {
          results.add('Task cancelled by user.');
          _report('Task cancelled.');
          await _notificationService.showTaskCompleteNotification(
            'Task Cancelled',
            'Task was stopped by the user.',
          );
          await TaskHistoryLogger.logTask(
            userGoal,
            'Cancelled',
            totalTokens,
            step,
            results,
          );
          await _screenService.showToast('Task Cancelled');
          return const TaskResult(TaskStatus.cancelled, 'Task cancelled.');
        }

        final aiResponse = result as AiResponse;
        await diagnostic.event('model_response', {
          'step': step + 1,
          'duration_ms': modelTimer.elapsedMilliseconds,
          'tokens': aiResponse.totalTokens,
        });
        response = aiResponse.content;
        totalTokens += aiResponse.totalTokens;

        developer.log('Received task decision', name: 'PrivateAgent');
      } catch (e) {
        if (_cancelled) {
          results.add('Task cancelled by user.');
          _report('Task cancelled.');
          await _notificationService.showTaskCompleteNotification(
            'Task Cancelled',
            'Task was stopped by the user.',
          );
          await TaskHistoryLogger.logTask(
            userGoal,
            'Cancelled',
            totalTokens,
            step,
            results,
          );
          await _screenService.showToast('Task Cancelled');
          await Future.delayed(const Duration(seconds: 2));
          return const TaskResult(TaskStatus.cancelled, 'Task cancelled.');
        }
        await diagnostic.event('model_error', {
          'step': step + 1,
          'reason': e is TimeoutException ? 'timeout' : 'connection_error',
        });
        results.add('AI error: $e');
        _report('Error: $e');
        await _notificationService.showTaskCompleteNotification(
          'Task Error',
          'AI encountered an error.',
        );
        await TaskHistoryLogger.logTask(
          userGoal,
          'Failed',
          totalTokens,
          step,
          results,
        );
        await _screenService.showToast('AI Error: $e');
        await Future.delayed(const Duration(seconds: 3));
        return const TaskResult(
          TaskStatus.failed,
          'I could not complete the task because the AI service failed.',
        );
      }

      // Check for cancellation after AI response
      if (_cancelled) {
        results.add('Task cancelled by user.');
        _report('Task cancelled.');
        await _notificationService.showTaskCompleteNotification(
          'Task Cancelled',
          'Task was stopped by the user.',
        );
        await TaskHistoryLogger.logTask(
          userGoal,
          'Cancelled',
          totalTokens,
          step,
          results,
        );
        await _screenService.showToast('Task Cancelled');
        await Future.delayed(const Duration(seconds: 2));
        return const TaskResult(TaskStatus.cancelled, 'Task cancelled.');
      }

      // 4. Parse the action (with one retry on failure)
      Map<String, dynamic>? actionJson;
      try {
        String jsonStr = _extractJson(response);

        actionJson = jsonDecode(jsonStr) as Map<String, dynamic>;
      } catch (firstError) {
        // First attempt failed — retry once
        developer.log(
          'Task decision formatting failed; retrying',
          name: 'PrivateAgent',
        );
        _report('Retrying step ${step + 1}...\n(Failed to parse: $firstError)');
        // Wait 2 seconds before retrying to prevent rate-limit spam
        await Future.delayed(const Duration(seconds: 2));
        try {
          if (_cancelled) {
            await TaskHistoryLogger.logTask(
              userGoal,
              'Cancelled',
              totalTokens,
              step,
              results,
            );
            return const TaskResult(TaskStatus.cancelled, 'Task cancelled.');
          }
          final retryResponse = await Future.any<AiResponse?>([
            _aiService.sendTaskMessage(_taskSystemPrompt, prompt),
            _cancelCompleter!.future.then((_) => null),
          ]);
          if (retryResponse == null || _cancelled) {
            _report('Task cancelled.');
            await TaskHistoryLogger.logTask(
              userGoal,
              'Cancelled',
              totalTokens,
              step,
              [...results, 'Task cancelled.'],
            );
            return const TaskResult(TaskStatus.cancelled, 'Task cancelled.');
          }
          totalTokens += retryResponse.totalTokens;
          developer.log('Received formatting retry', name: 'PrivateAgent');

          String jsonStr = _extractJson(retryResponse.content);
          actionJson = jsonDecode(jsonStr) as Map<String, dynamic>;
        } catch (e) {
          results.add('Step ${step + 1}: Error after retry: $e');

          String debugInfo = 'Error: $e';
          _report('AI Error: $debugInfo\n\nRaw output:\n${response}');

          await _notificationService.showTaskCompleteNotification(
            'Task Error',
            'AI formatting error.',
          );
          await TaskHistoryLogger.logTask(
            userGoal,
            'Failed',
            totalTokens,
            step,
            results,
          );
          await _screenService.showToast('Agent Error: $e');
          await Future.delayed(const Duration(seconds: 3));
          return const TaskResult(
            TaskStatus.failed,
            'I could not understand the AI response. Please try again.',
          );
        }
      }

      if (_cancelled) {
        await TaskHistoryLogger.logTask(
          userGoal,
          'Cancelled',
          totalTokens,
          step,
          results,
        );
        return const TaskResult(TaskStatus.cancelled, 'Task cancelled.');
      }
      final action = actionJson['action'] as String? ?? 'failed';
      final params = actionJson['params'] as Map<String, dynamic>? ?? {};
      final reasoning = actionJson['reasoning'] as String? ?? '';
      final isComplete = action == 'done';

      developer.log('Parsed task decision', name: 'PrivateAgent');

      _report('Step ${step + 1}: $reasoning');
      await diagnostic.event('decision', {
        'step': step + 1,
        'action': action,
        'plan_revision': progressGuard.planRevision,
      });
      if ((action == 'replan' || action == 'failed') &&
          progressGuard.deferStrategyChange) {
        results.add(
          'Local interaction repair required: keep the current strategy/subgoal. Try another appropriate control or input method; a wrong click is not a failed search strategy.',
        );
        await diagnostic.event('plan_change', {
          'step': step + 1,
          'reason': 'early_replan_deferred',
          'status': 'local_repair',
        });
        continue;
      }
      if (action == 'replan') {
        await diagnostic.event('plan_change', {
          'step': step + 1,
          'reason': 'model_replan',
          'status': 'strategy_replan',
        });
        progressGuard.abandon(reasoning);
        progressGuard.adoptPlan(actionJson['plan']);
        results.add('Replanning from the actual current screen: $reasoning');
        _report('Trying another strategy: $reasoning');
        continue;
      }
      progressGuard.adoptPlan(actionJson['plan']);
      if (action == 'failed' && progressGuard.hasAlternatives) {
        progressGuard.selectAlternative(reasoning);
        results.add(
          'Current branch failed; an alternative remains: $reasoning',
        );
        _report('Branch exhausted; checking another strategy.');
        continue;
      }

      final loopRejection = progressGuard.rejectionFor(action, params);
      if (loopRejection != null) {
        results.add(loopRejection);
        _report(loopRejection);
        if (progressGuard.needsReplan) progressGuard.abandon(loopRejection);
        await diagnostic.event('plan_change', {
          'step': step + 1,
          'reason': progressGuard.needsReplan
              ? 'cycle_detected'
              : 'ineffective_control',
          'status': progressGuard.needsReplan
              ? 'strategy_replan'
              : 'local_repair',
        });
        // No UI action ran. The next decision starts from the same real screen.
        continue;
      }

      lastAction = action; // Track for adaptive delay

      // 5. Execute the action
      bool success = false;
      String actionResult = '';

      UiInteractionResult? interaction;
      if (const {
        'click_text',
        'click_at',
        'tap_at',
        'type_text',
      }.contains(action)) {
        interaction = await _screenService.performInteraction(
          action,
          params,
          taskId: diagnostic.id,
          step: step + 1,
          voiceAllowed: voiceAllowed,
        );
      }
      switch (action) {
        case 'click_text':
          final text = params['text'] as String? ?? '';
          success = interaction!.accepted;
          actionResult = success
              ? 'Clicked "$text"'
              : 'Could not find "$text" to click';
          break;

        case 'click_at':
          final x = (params['x'] as num?)?.toDouble() ?? 0;
          final y = (params['y'] as num?)?.toDouble() ?? 0;
          success = interaction!.accepted;
          actionResult = success ? 'Clicked at ($x, $y)' : 'Click failed';
          break;

        case 'tap_at':
          final x = (params['x'] as num?)?.toDouble() ?? double.nan;
          final y = (params['y'] as num?)?.toDouble() ?? double.nan;
          success = interaction!.accepted;
          actionResult = success
              ? 'Touched at ($x, $y)'
              : 'Direct touch rejected (display support, coordinates or TV keyboard)';
          break;

        case 'type_text':
          final text = params['text'] as String? ?? '';
          success = interaction!.accepted;
          if (success) expectedTypedValue = text;
          actionResult = success ? 'Typed "$text"' : 'Could not type text';
          break;

        case 'press_enter':
          success = await _screenService.pressEnter();
          actionResult = success
              ? 'Submitted the focused search/form field'
              : 'Could not submit the focused field';
          break;

        case 'swipe':
          final startX = (params['startX'] as num?)?.toDouble() ?? 540;
          final startY = (params['startY'] as num?)?.toDouble() ?? 2000;
          final endX = (params['endX'] as num?)?.toDouble() ?? 540;
          final endY = (params['endY'] as num?)?.toDouble() ?? 500;

          success = await _performSwipe(startX, startY, endX, endY);
          actionResult = 'Swiped from ($startX,$startY) to ($endX,$endY)';
          break;

        case 'scroll':
          final direction = params['direction'] as String? ?? 'down';
          success = await _performScroll(direction);
          actionResult = success
              ? 'Scrolled $direction'
              : 'Could not scroll $direction';
          break;

        case 'press_back':
          success = await _screenService.pressBack();
          actionResult = success ? 'Pressed back' : 'Back was rejected';
          break;

        case 'press_home':
          success = await _screenService.pressHome();
          actionResult = success ? 'Pressed home' : 'Home was rejected';
          break;

        case 'open_app':
          final appName = params['app_name'] as String? ?? '';
          actionResult = await _appLauncher.openApp(appName);
          success = actionResult.startsWith('Opened');
          break;

        case 'wait':
          await Future.delayed(const Duration(seconds: 1));
          actionResult = 'Waited';
          success = true;
          break;

        case 'failed':
          final message = reasoning.trim().isEmpty
              ? 'Agent could not complete the task.'
              : reasoning.trim();
          _report(message);
          await TaskHistoryLogger.logTask(
            userGoal,
            'Failed',
            totalTokens,
            step,
            [...results, message],
          );
          await _notificationService.showTaskCompleteNotification(
            'Task Failed',
            message,
          );
          return TaskResult(TaskStatus.failed, message);

        case 'done':
          final evidence = actionJson['completion_evidence'];
          if (evidence is! String ||
              evidence.trim().length < 3 ||
              !screenContent.contains(evidence.trim())) {
            final problem = evidence is! String || evidence.trim().length < 3
                ? 'missing top-level completion_evidence string'
                : 'completion_evidence does not occur in the current screen dump';
            actionResult =
                'Completion not accepted: $problem. '
                'If the FULL goal is visible, reply with {"action":"done","completion_evidence":"<exact visible text>","reasoning":"<why it proves the full goal>"}. '
                'Otherwise verify the result from the actual screen. Keep the current plan; do not navigate away merely to repair JSON. A selected listing is not playback.';
            await diagnostic.event('completion_rejected', {
              'step': step + 1,
              'reason': evidence is String
                  ? 'completion_evidence_mismatch'
                  : 'completion_evidence_missing',
            });
            results.add(actionResult);
            _report(actionResult);
            continue;
          }
          await memory.completed(memoryContext);
          results.add('Task complete: $reasoning');
          _report('Task complete: $reasoning');
          await _notificationService.showTaskCompleteNotification(
            'Task Completed',
            reasoning.trim().isEmpty ? 'Agent finished its goal.' : reasoning,
          );
          await TaskHistoryLogger.logTask(
            userGoal,
            'Success',
            totalTokens,
            step,
            results,
          );
          await _screenService.showToast('Task completed');
          return TaskResult(
            TaskStatus.succeeded,
            reasoning.trim().isEmpty ? 'Done.' : reasoning.trim(),
          );

        default:
          actionResult = 'Unknown action: $action';
      }

      final controlKey = interaction == null
          ? null
          : interaction.controlKey.isNotEmpty
          ? interaction.controlKey
          : action == 'type_text'
          ? 'typed_field'
          : '$action:${jsonEncode(params)}';
      if (action == 'type_text' && success) expectedTypedControl = controlKey;
      if (interaction != null && !success) {
        progressGuard.requireLocalRepair(controlKey ?? '');
        if (interaction.reason == 'voice_control_blocked') {
          actionResult =
              'Voice control blocked: the original user did not request app voice input. Keep the text-search strategy; use the editable field directly.';
        }
      }
      await diagnostic.event('action_result', {
        'step': step + 1,
        'action': action,
        'accepted': success,
        'reason':
            interaction?.reason ?? (success ? 'accepted' : 'native_rejected'),
      });
      memory.record(memoryContext, action, params, success);
      progressGuard.recordAttempt(
        action,
        params,
        success,
        actionResult,
        controlKey: controlKey,
      );
      developer.log('Native action returned', name: 'PrivateAgent');

      // Track consecutive failures to detect stuck loops
      if (!success) {
        if (action == lastFailedAction) {
          consecutiveFailures++;
        } else {
          consecutiveFailures = 1;
          lastFailedAction = action;
        }

        if (consecutiveFailures >= 3) {
          progressGuard.requireLocalRepair('');
          consecutiveFailures = 0;
          lastFailedAction = '';
        }

        results.add('Step ${step + 1}: $actionResult ($reasoning)');
        // Observe the actual failed action before choosing a recovery route.
        // An implicit Back/Home here would hide a second action from task memory.
        _report('Interaction rejected; checking the current screen.');
        continue;
      } else {
        consecutiveFailures = 0;
        lastFailedAction = '';
      }

      results.add('Step ${step + 1}: $actionResult ($reasoning)');

      // Provide progress feedback
      if (!isComplete && (step + 1) % 3 == 0) {
        await _screenService.showToast('Working... (Step ${step + 1})');
      }
    }

    results.add(
      'Reached maximum steps (${_aiService.maxSteps}). Task may be incomplete.',
    );
    _report('Reached maximum steps.');
    await _notificationService.showTaskCompleteNotification(
      'Task Stopped',
      'Reached maximum steps (${_aiService.maxSteps}).',
    );
    await TaskHistoryLogger.logTask(
      userGoal,
      'Failed',
      totalTokens,
      _aiService.maxSteps,
      results,
    );
    await _screenService.showToast('Reached maximum steps.');
    await Future.delayed(const Duration(seconds: 4));

    return const TaskResult(
      TaskStatus.failed,
      'I could not complete the task within the allowed steps.',
    );
  }

  void _report(String message) {
    onProgress?.call(message);
  }

  Future<bool> _performScroll(String direction) async {
    if (await _screenService.scroll(direction)) return true;

    final isDown = direction.toLowerCase() == 'down';
    return _performSwipe(540, isDown ? 1800 : 600, 540, isDown ? 600 : 1800);
  }

  Future<bool> _performSwipe(
    double startX,
    double startY,
    double endX,
    double endY,
  ) async {
    if (await _screenService.swipe(startX, startY, endX, endY)) return true;

    final shizukuAvailable = await _shizukuService.checkAvailability();
    if (!shizukuAvailable || !_shizukuService.hasPermission) return false;

    final result = await _shizukuService.runCommand(
      'input swipe ${startX.toInt()} ${startY.toInt()} '
      '${endX.toInt()} ${endY.toInt()} 600',
    );
    final normalized = result.toLowerCase();
    return !normalized.contains('not running') &&
        !normalized.contains('permission denied') &&
        !normalized.startsWith('error');
  }

  /// Returns predefined navigation steps for common tasks
  List<ActionStep>? _getNavigationShortcut(String goal) {
    final lower = goal.toLowerCase();

    if (lower.contains('dark mode') || lower.contains('dark theme')) {
      return [
        ActionStep(action: 'open_app', params: {'app_name': 'Settings'}),
        ActionStep(action: 'click_text', params: {'text': 'Display'}),
      ];
    }
    if (lower.contains('wifi') || lower.contains('wi-fi')) {
      return [
        ActionStep(action: 'open_app', params: {'app_name': 'Settings'}),
        ActionStep(
          action: 'click_text',
          params: {'text': 'Network & internet'},
        ),
      ];
    }
    if (lower.contains('bluetooth')) {
      return [
        ActionStep(action: 'open_app', params: {'app_name': 'Settings'}),
        ActionStep(action: 'click_text', params: {'text': 'Connected devices'}),
      ];
    }

    final appPatterns = <String, List<String>>{
      'Settings': ['settings', 'brightness', 'display', 'notification'],
      'Play Store': [
        'play store',
        'playstore',
        'download',
        'install app',
        'google play',
      ],
      'YouTube': ['youtube'],
      'WhatsApp': ['whatsapp'],
      'Chrome': ['chrome', 'browse', 'search google'],
      'Camera': ['camera', 'take a photo', 'take photo', 'take a picture'],
      'Gallery': ['gallery', 'photos'],
      'Messages': ['message', 'sms', 'text to'],
      'Phone': ['call', 'dial'],
      'Gmail': ['gmail', 'email'],
      'Maps': ['maps', 'navigate to', 'directions'],
      'Clock': ['alarm', 'timer', 'stopwatch'],
      'Calculator': ['calculator', 'calculate', 'calc'],
    };

    for (final entry in appPatterns.entries) {
      for (final keyword in entry.value) {
        if (lower.contains(keyword)) {
          return [
            ActionStep(action: 'open_app', params: {'app_name': entry.key}),
          ];
        }
      }
    }

    // Generic fallback for "open X"
    final openMatch = RegExp(r'^open\s+([a-zA-Z0-9]+)').firstMatch(lower);
    if (openMatch != null) {
      String app = openMatch.group(1)!;
      app = app[0].toUpperCase() + app.substring(1);
      return [
        ActionStep(action: 'open_app', params: {'app_name': app}),
      ];
    }

    return null;
  }
}
