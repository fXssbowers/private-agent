import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_agent/models/agent_action.dart';
import 'package:private_agent/models/task_result.dart';
import 'package:private_agent/services/action_handler.dart';
import 'package:private_agent/services/ai_service.dart';
import 'package:private_agent/services/app_launcher_service.dart';
import 'package:private_agent/services/notification_service.dart';
import 'package:private_agent/services/screen_automation_service.dart';
import 'package:private_agent/services/shizuku_service.dart';
import 'package:private_agent/services/task_executor.dart';
import 'package:private_agent/services/task_progress_guard.dart';
import 'package:private_agent/services/app_memory_service.dart';

class Screen extends ScreenAutomationService {
  bool running = true;
  bool acceptsClick = true;
  int backs = 0;
  int clicks = 0;
  int touches = 0;
  bool touchSupported = true;
  @override
  Future<bool> canDispatchTouch() async => touchSupported;
  @override
  Future<bool> tapAt(double x, double y) async {
    touches++;
    return true;
  }

  @override
  Future<bool> isServiceRunning() async => running;
  @override
  Future<String?> getAppVersion(String packageName) async => '1';
  @override
  Future<String?> getCurrentPackage() async => 'fixture.app';
  @override
  Future<String> getCompressedScreenDescription(String task) async =>
      'Search results: Interstellar 2014';
  @override
  Future<bool> clickAt(double x, double y) async {
    clicks++;
    return acceptsClick;
  }

  @override
  Future<bool> pressBack() async {
    backs++;
    return true;
  }

  @override
  Future<bool> scroll(String direction, {String? target}) async => false;
  @override
  Future<bool> swipe(
    double startX,
    double startY,
    double endX,
    double endY,
  ) async => false;
  @override
  Future<void> showToast(String text) async {}
}

class CyclingScreen extends Screen {
  String state = 'player';
  int routeClicks = 0;
  int searchClicks = 0;
  @override
  Future<String> getCompressedScreenDescription(String task) async => state;
  @override
  Future<bool> clickAt(double x, double y) async {
    if (x == 10) {
      routeClicks++;
      state = state == 'player' ? 'guide' : 'player';
    } else if (x == 20) {
      searchClicks++;
      state = 'requested search result';
    }
    return true;
  }
}

class MemoryScreen extends Screen {
  @override
  Future<String> getCompressedScreenDescription(String task) async =>
      'APP: fixture.app\n[0] view "" [tap] center:(960,540)\n[1] btn "Cerca" [tap] center:(100,100)';
}

class Notices extends NotificationService {
  @override
  Future<void> showTaskCompleteNotification(String title, String body) async {}
}

class Model extends AiService {
  final List<String> responses;
  Model(this.responses, {this.limit = 15});
  final int limit;
  int calls = 0;
  final prompts = <String>[];
  Completer<AiResponse>? pending;
  Completer<AiResponse>? retryPending;
  @override
  int get maxSteps => limit;
  @override
  Future<AiResponse> sendTaskMessage(String system, String prompt) {
    calls++;
    prompts.add(prompt);
    if (calls > 1 && retryPending != null) return retryPending!.future;
    return pending?.future ??
        Future.value(AiResponse(responses.removeAt(0), 10));
  }
}

class UnapprovedShell extends ShizukuService {
  UnapprovedShell({this.granted = false});
  final bool granted;
  int commands = 0;
  @override
  Future<bool> checkAvailability() async => true;
  @override
  bool get hasPermission => granted;
  @override
  Future<String> runCommand(String command) async {
    commands++;
    return '';
  }
}

TaskExecutor executor(Model ai, Screen screen) => TaskExecutor(
  aiService: ai,
  screenService: screen,
  appLauncher: AppLauncherService(),
  shizukuService: ShizukuService(),
  notificationService: Notices(),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('privateagent-test-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => directory.path,
        );
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test('a two-screen cycle requires a different action on return', () {
    final guard = TaskProgressGuard();
    for (var i = 0; i < 2; i++) {
      guard.observe('player');
      expect(guard.rejectionFor('click_text', {'text': 'Guide'}), isNull);
      guard.recordAttempt('click_text', {'text': 'Guide'}, true, 'Accepted');
      guard.observe('guide');
      guard.recordAttempt('press_back', {}, true, 'Accepted');
    }
    guard.observe('player');
    expect(guard.context, contains('STRATEGY CHANGE REQUIRED'));
    expect(guard.context, contains('"observed_after":"S2"'));
    expect(guard.rejectionFor('click_text', {'text': 'Guide'}), isNotNull);
    expect(guard.rejectionFor('click_text', {'text': 'Search'}), isNull);
    expect(guard.rejectionFor('done', {}), isNull);
  });
  test('waits and app reopening cannot erase unsuccessful attempts', () {
    final guard = TaskProgressGuard()..observe('guide');
    guard.recordAttempt('click_text', {'text': 'Guide'}, true, 'Accepted');
    guard.observe('guide');
    guard.recordAttempt('click_text', {'text': 'Guide'}, true, 'Accepted');
    guard.observe('guide');
    guard.recordAttempt('wait', {}, true, 'Waited');
    guard.observe('home');
    guard.recordAttempt('open_app', {'app_name': 'TiviMate'}, true, 'Opened');
    guard.observe('guide');
    guard.recordAttempt('click_text', {'text': 'Guide'}, true, 'Accepted');
    expect(guard.rejectionFor('click_text', {'text': 'Guide'}), isNotNull);
  });
  test('clock and tree-index changes do not evade repeated-action checks', () {
    final guard = TaskProgressGuard();
    for (var i = 0; i < 2; i++) {
      guard.observe('APP: tv\n[3] textclock "01:24:10" center:(50,60)');
      guard.recordAttempt('click_at', {'x': 50, 'y': 60}, true, 'Accepted');
    }
    guard.observe('APP: tv\n[9] textclock "01:24:13" center:(50,60)');
    expect(guard.rejectionFor('click_at', {'y': 60.0, 'x': 50.0}), isNotNull);
  });
  test(
    'new controls, query content and application identity remain distinct',
    () {
      final guard = TaskProgressGuard();
      guard.observe('APP: tv "Search 2014" center:(50,60)');
      guard.recordAttempt('click_at', {'x': 50, 'y': 60}, true, 'Accepted');
      guard.recordAttempt('click_at', {'x': 50, 'y': 60}, true, 'Accepted');
      for (final screen in [
        'APP: tv "Results 2014" center:(50,60)',
        'APP: tv "Search 2015" center:(50,60)',
        'APP: film "Search 2014" center:(50,60)',
      ]) {
        guard.observe(screen);
        expect(guard.rejectionFor('click_at', {'x': 50, 'y': 60}), isNull);
      }
      final nextTask = TaskProgressGuard()
        ..observe('APP: tv "Search 2014" center:(50,60)');
      expect(nextTask.rejectionFor('click_at', {'x': 50, 'y': 60}), isNull);
    },
  );
  test('time-valued queries and result titles are not mistaken for clocks', () {
    final guard = TaskProgressGuard();
    guard.observe(
      'APP: film\n[1] input "12:30" [edit] center:(50,60)\n[2] text "12:30" [tap]',
    );
    guard.recordAttempt('click_at', {'x': 50, 'y': 60}, true, 'Accepted');
    guard.recordAttempt('click_at', {'x': 50, 'y': 60}, true, 'Accepted');
    guard.observe(
      'APP: film\n[1] input "13:30" [edit] center:(50,60)\n[2] text "13:30" [tap]',
    );
    expect(guard.rejectionFor('click_at', {'x': 50, 'y': 60}), isNull);
  });
  test(
    'a rejected click preserves the page for the next observation',
    () async {
      final screen = Screen()..acceptsClick = false;
      final ai = Model([
        '{"action":"click_at","params":{"x":50,"y":50}}',
        '{"action":"failed","reasoning":"Control not available"}',
      ]);
      final result = await executor(ai, screen).executeTask('search');
      expect(result.success, false);
      expect(ai.calls, 2);
      expect(screen.backs, 0);
    },
  );
  test('rejected scrolling has no hidden navigation recovery', () async {
    final ai = Model([
      '{"action":"scroll","params":{"direction":"down"}}',
      '{"action":"failed","reasoning":"No other visible route"}',
    ]);
    final screen = Screen();
    final result = await executor(ai, screen).executeTask('search');
    expect(result.status, TaskStatus.failed);
    expect(screen.backs, 0);
    expect(ai.prompts[1], contains('Could not scroll down'));
    expect(ai.prompts[1], contains('"accepted_by_android":false'));
    expect(ai.prompts[1], contains('"observed_after":"S1"'));
  });
  test(
    'rejected native submit cannot inject shell Enter, even if authorized',
    () async {
      for (final granted in [false, true]) {
        final ai = Model([
          '{"action":"press_enter"}',
          '{"action":"failed","reasoning":"Submit unsupported"}',
        ]);
        final shell = UnapprovedShell(granted: granted);
        final runner = TaskExecutor(
          aiService: ai,
          screenService: Screen(),
          appLauncher: AppLauncherService(),
          shizukuService: shell,
          notificationService: Notices(),
        );
        expect((await runner.executeTask('search')).success, false);
        expect(shell.commands, 0);
      }
    },
  );
  test('disabled accessibility cannot produce a successful task', () async {
    final screen = Screen()..running = false;
    expect(
      (await executor(Model([]), screen).executeTask('search')).status,
      TaskStatus.failed,
    );
  });
  test(
    'reaching step limit propagates failure to the chat action result',
    () async {
      final ai = Model([], limit: 0);
      final handler = ActionHandler(
        createTaskExecutor: (aiService, progress) => executor(ai, Screen()),
      );
      final result = await handler.execute(
        AgentAction(
          action: 'execute_task',
          params: {'goal': 'search'},
          response: 'I will search',
        ),
        aiService: ai,
      );
      expect(result.success, false);
      expect(result.details, contains('allowed steps'));
    },
  );
  test('missing AI service cannot show success', () async {
    final result = await ActionHandler().execute(
      AgentAction(action: 'execute_task', params: {}, response: ''),
    );
    expect(result.success, false);
  });
  test('explicit failure is preserved rather than marked complete', () async {
    final result = await executor(
      Model([
        '{"action":"failed","reasoning":"Search unavailable","is_complete":true}',
      ]),
      Screen(),
    ).executeTask('search');
    expect(result.status, TaskStatus.failed);
    expect(result.message, 'Search unavailable');
  });
  test(
    'an action marked complete still requires a later screen confirmation',
    () async {
      final ai = Model([
        '{"action":"click_at","params":{"x":50,"y":50},"is_complete":true}',
        '{"action":"failed","reasoning":"Wrong film"}',
      ]);
      final result = await executor(ai, Screen()).executeTask('search');
      expect(ai.calls, 2);
      expect(result.success, false);
    },
  );
  test(
    'repeated proposals are blocked before dispatch and stop honestly',
    () async {
      final ai = Model(
        List.generate(
          5,
          (_) => '{"action":"click_at","params":{"x":50,"y":50}}',
        ),
        limit: 5,
      );
      final screen = Screen();
      final result = await executor(ai, screen).executeTask('search');
      expect(result.status, TaskStatus.failed);
      expect(result.message, contains('allowed steps'));
      expect(ai.calls, 5);
      expect(screen.clicks, 2);
      expect(ai.prompts[2], contains('STRATEGY CHANGE REQUIRED'));
      expect(ai.prompts[3], contains('"dispatched":false'));
    },
  );
  test(
    'an alternative route remains executable after a detected cycle',
    () async {
      final ai = Model([
        ...List.filled(5, '{"action":"click_at","params":{"x":10,"y":50}}'),
        '{"action":"click_at","params":{"x":20,"y":50}}',
        '{"action":"done","reasoning":"Requested search result visible","completion_evidence":"requested search result"}',
      ]);
      final screen = CyclingScreen();
      final result = await executor(ai, screen).executeTask('search');
      expect(result.status, TaskStatus.succeeded);
      expect(screen.routeClicks, 4);
      expect(screen.searchClicks, 1);
      expect(screen.state, 'requested search result');
      expect(ai.prompts[4], contains('STRATEGY CHANGE REQUIRED'));
      expect(ai.prompts[5], contains('"dispatched":false'));
      expect(ai.prompts.last, contains('requested search result'));
    },
  );
  test(
    'a fresh executor receives a prior failed navigation lesson without replay',
    () async {
      final screen = MemoryScreen()..acceptsClick = false;
      final first = Model([
        '{"action":"click_at","params":{"x":50,"y":50}}',
        '{"action":"failed","reasoning":"No alternative visible"}',
      ]);
      expect(
        (await executor(first, screen).executeTask('search')).success,
        false,
      );
      final second = Model([
        '{"action":"failed","reasoning":"Try a different route"}',
      ]);
      await executor(second, MemoryScreen()).executeTask('search another film');
      expect(
        second.prompts.single,
        contains('APP MEMORY (fixture.app, version 1)'),
      );
      expect(second.prompts.single, contains('"last_outcome":"rejected"'));
      expect(second.calls, 1);
      expect(screen.clicks, 1);
    },
  );
  test('explicit user advice is included as conditional app context', () async {
    await AppMemoryService().saveUserLesson(
      'fixture.app',
      '1',
      when: 'Player, keyboard closed',
      advice: 'Use Back',
      expected: 'Channel menu',
    );
    final ai = Model([
      '{"action":"failed","reasoning":"Need to inspect menu"}',
    ]);
    await executor(ai, MemoryScreen()).executeTask('search');
    expect(ai.prompts.single, contains('Use Back'));
    expect(ai.prompts.single, contains('"source":"user"'));
    expect(ai.prompts.single, contains('only when its context matches'));
  });
  test('cancellation while waiting for AI propagates cancellation', () async {
    final ai = Model([])..pending = Completer<AiResponse>();
    final runner = executor(ai, Screen());
    final future = runner.executeTask('search');
    while (ai.calls == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    runner.cancel();
    expect((await future).status, TaskStatus.cancelled);
    ai.pending!.complete(AiResponse('{"action":"done"}', 0));
  });
  test(
    'Stop during formatting retry cannot become a successful done action',
    () async {
      final ai = Model(['not JSON'])..retryPending = Completer<AiResponse>();
      final runner = executor(ai, Screen());
      final future = runner.executeTask('search');
      while (ai.calls < 2) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      runner.cancel();
      final result = await future.timeout(const Duration(seconds: 1));
      expect(result.status, TaskStatus.cancelled);
      ai.retryPending!.complete(AiResponse('{"action":"done"}', 0));
    },
  );
  test(
    'legacy saved macros are preserved but never replayed automatically',
    () async {
      await File('${directory.path}/skills_memory.jsonl').writeAsString(
        '{"id":"fixture","task":"search","task_keywords":["search"],"success_count":1,"fail_count":0,"last_used":"2026-11-01T00:00:00","steps":[{"action":"click_at","params":{"x":50,"y":50}}]}\n',
      );
      final ai = Model(['{"action":"failed","reasoning":"Wrong film"}']);
      final screen = Screen();
      final result = await executor(ai, screen).executeTask('search');
      expect(ai.calls, 1);
      expect(screen.clicks, 0);
      expect(
        await File('${directory.path}/skills_memory.jsonl').exists(),
        true,
      );
      expect(result.success, false);
    },
  );
  test(
    'a branch failure tries a remaining approach without moving the device',
    () async {
      final ai = Model([
        '{"action":"replan","plan":{"strategy":"visible controls","subgoal":"find search","alternatives":["global navigation"]}}',
        '{"action":"failed","reasoning":"This branch is exhausted"}',
        '{"action":"done","completion_evidence":"Interstellar 2014","reasoning":"Result visible"}',
      ]);
      final screen = Screen();
      expect((await executor(ai, screen).executeTask('search')).success, true);
      expect(ai.calls, 3);
      expect(screen.backs, 0);
      expect(ai.prompts.last, contains('global navigation'));
      expect(ai.prompts.last, contains('ABANDONED STRATEGIES'));
    },
  );
  test(
    'unsupported completion evidence consumes budget and cannot report success',
    () async {
      final ai = Model([
        '{"action":"done","completion_evidence":"Film is playing"}',
        '{"action":"done"}',
      ], limit: 2);
      expect(
        (await executor(ai, Screen()).executeTask('play')).status,
        TaskStatus.failed,
      );
      expect(ai.calls, 2);
      expect(ai.prompts.last, contains('Completion not accepted'));
    },
  );
  test(
    'completion formatting repair preserves the successful plan and does not move UI',
    () async {
      final ai = Model([
        '{"action":"replan","plan":{"strategy":"inspect requested result","subgoal":"verify detail"}}',
        '{"action":"done","reasoning":"Interstellar 2014 visible"}',
        '{"action":"done","completion_evidence":"Interstellar 2014","reasoning":"Result visible"}',
      ]);
      final screen = Screen();
      expect((await executor(ai, screen).executeTask('search')).success, true);
      expect(
        ai.prompts.last,
        contains('missing top-level completion_evidence'),
      );
      expect(
        ai.prompts.last,
        contains('"strategy":"inspect requested result"'),
      );
      expect(ai.prompts.last, contains('ABANDONED STRATEGIES: []'));
      expect(screen.clicks, 0);
      expect(screen.backs, 0);
    },
  );
  test('same navigation action across distinct states remains available', () {
    final guard = TaskProgressGuard();
    for (final state in [
      'player',
      'side panel',
      'groups',
      'channels',
      'search',
    ]) {
      guard.observe(state);
      expect(guard.rejectionFor('press_back', {}), isNull);
      guard.recordAttempt('press_back', {}, true, 'Accepted');
    }
  });
  test('shared corridors and actual backtracking allow three new branches', () {
    final guard = TaskProgressGuard()..observe('A');
    void move(String action, String next) {
      expect(
        guard.rejectionFor(action, {}),
        isNull,
        reason: 'Must be able to reach $next',
      );
      guard.recordAttempt(action, {}, true, 'Accepted');
      guard.observe(next);
    }

    for (final endpoint in ['E1', 'E2', 'E3']) {
      move('forward', 'B');
      move('forward', 'C');
      move('forward', 'D');
      move('forward', endpoint);
      move('press_back', 'D');
      move('press_back', 'C');
      move('press_back', 'B');
      move('press_back', 'A');
    }
    expect(guard.rejectionFor('forward', {}), isNull);
  });
  test(
    'renaming a plan cannot erase ineffective edges; query and focus differ',
    () {
      final guard = TaskProgressGuard()..observe('input "query" [focused]');
      for (var i = 0; i < 2; i++) {
        guard.recordAttempt('press_back', {}, true, 'Accepted');
        guard.observe('input "query" [focused]');
      }
      guard.abandon('stalled');
      guard.adoptPlan({'strategy': 'new name'});
      expect(guard.rejectionFor('press_back', {}), isNotNull);
      guard.observe('input "query"');
      expect(guard.rejectionFor('press_back', {}), isNull);
      guard.observe('input "another query" [focused]');
      expect(guard.rejectionFor('press_back', {}), isNull);
    },
  );
  test(
    'physical touch remains an executable alternative to an ineffective accessible click',
    () async {
      final ai = Model([
        '{"action":"click_at","params":{"x":50,"y":50}}',
        '{"action":"click_at","params":{"x":50,"y":50}}',
        '{"action":"tap_at","params":{"x":50,"y":50}}',
        '{"action":"done","completion_evidence":"Interstellar 2014"}',
      ]);
      final screen = Screen();
      expect((await executor(ai, screen).executeTask('search')).success, true);
      expect(screen.clicks, 2);
      expect(screen.touches, 1);
    },
  );
  test(
    'unsupported touch is declared before planning and cannot be dispatched',
    () async {
      final screen = Screen()..touchSupported = false;
      final ai = Model([
        '{"action":"tap_at","params":{"x":50,"y":50}}',
        '{"action":"failed","reasoning":"No applicable route"}',
      ]);
      expect((await executor(ai, screen).executeTask('search')).success, false);
      expect(screen.touches, 0);
      expect(ai.prompts.first, contains('UNAVAILABLE on this display'));
      expect(ai.prompts.last, contains('Direct touch rejected'));
    },
  );
  test('confirmed completion propagates success', () async {
    final ai = Model([
      '{"action":"done","reasoning":"Interstellar 2014 detail is visible","completion_evidence":"Interstellar 2014"}',
    ]);
    final handler = ActionHandler(
      createTaskExecutor: (aiService, progress) => executor(ai, Screen()),
    );
    final result = await handler.execute(
      AgentAction(
        action: 'execute_task',
        params: {'goal': 'search'},
        response: '',
      ),
      aiService: ai,
    );
    expect(result.success, true);
    expect(result.details, contains('2014'));
  });
}
