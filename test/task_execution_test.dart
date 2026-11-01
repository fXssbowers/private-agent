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

class Screen extends ScreenAutomationService {
  bool running = true;
  bool acceptsClick = true;
  int backs = 0;
  @override
  Future<bool> isServiceRunning() async => running;
  @override
  Future<String?> getCurrentPackage() async => 'fixture.app';
  @override
  Future<String> getCompressedScreenDescription(String task) async =>
      'Search results: Interstellar 2014';
  @override
  Future<bool> clickAt(double x, double y) async => acceptsClick;
  @override
  Future<bool> pressBack() async {
    backs++;
    return true;
  }

  @override
  Future<void> showToast(String text) async {}
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
  Completer<AiResponse>? pending;
  Completer<AiResponse>? retryPending;
  @override
  int get maxSteps => limit;
  @override
  Future<AiResponse> sendTaskMessage(String system, String prompt) {
    calls++;
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

  test(
    'unchanged UI stops after three attempts even when clicks report accepted',
    () {
      final guard = TaskProgressGuard();
      expect(guard.isStuck('screen A', ''), false);
      expect(guard.isStuck('screen A', 'click_at'), false);
      expect(guard.isStuck('screen A', 'click_text'), false);
      expect(guard.isStuck('screen A', 'press_enter'), true);
    },
  );
  test('new UI resets the no-progress counter and waits do not count', () {
    final guard = TaskProgressGuard();
    guard.isStuck('A', '');
    guard.isStuck('A', 'click_at');
    expect(guard.isStuck('B', 'click_at'), false);
    expect(guard.isStuck('B', 'wait'), false);
    expect(guard.isStuck('B', 'click_at'), false);
  });
  test('intermediate waits cannot hide three ineffective interactions', () {
    final guard = TaskProgressGuard();
    guard.isStuck('A', '');
    expect(guard.isStuck('A', 'click_at'), false);
    expect(guard.isStuck('A', 'wait'), false);
    expect(guard.isStuck('A', 'click_at'), false);
    expect(guard.isStuck('A', 'wait'), false);
    expect(guard.isStuck('A', 'click_at'), true);
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
    'accepted clicks on unchanged screen stop without another model request',
    () async {
      final ai = Model(
        List.generate(
          4,
          (_) => '{"action":"click_at","params":{"x":50,"y":50}}',
        ),
      );
      final result = await executor(ai, Screen()).executeTask('search');
      expect(result.success, false);
      expect(result.message, contains('three actions'));
      expect(ai.calls, 3);
    },
  );
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
    'saved actions must verify current screen before claiming success',
    () async {
      await File('${directory.path}/skills_memory.jsonl').writeAsString(
        '{"id":"fixture","task":"search","task_keywords":["search"],"success_count":1,"fail_count":0,"last_used":"2026-11-01T00:00:00","steps":[{"action":"click_at","params":{"x":50,"y":50}}]}\n',
      );
      final ai = Model(['{"action":"failed","reasoning":"Wrong film"}']);
      final result = await executor(ai, Screen()).executeTask('search');
      expect(ai.calls, 1);
      expect(result.success, false);
    },
  );
  test('confirmed completion propagates success', () async {
    final ai = Model([
      '{"action":"done","reasoning":"Interstellar 2014 detail is visible"}',
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
