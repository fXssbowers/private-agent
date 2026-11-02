import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_agent/services/diagnostic_trace_service.dart';
import 'package:private_agent/services/screen_automation_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(
    () => messenger.setMockMethodCallHandler(
      DiagnosticTraceService.channel,
      null,
    ),
  );
  test('logging failure never changes the control caller outcome', () async {
    messenger.setMockMethodCallHandler(
      DiagnosticTraceService.channel,
      (_) async => throw PlatformException(code: 'disk_full'),
    );
    final session = DiagnosticSession();
    await session.start();
    await session.event('observation', {'step': 1});
    await session.event('task_end', {'status': 'failed'});
  });
  test(
    'interaction bridge carries original intent policy separately from action params',
    () async {
      MethodCall? captured;
      messenger.setMockMethodCallHandler(DiagnosticTraceService.channel, (
        call,
      ) async {
        captured = call;
        return {
          'accepted': false,
          'reason': 'voice_control_blocked',
          'role': 'voice_search',
        };
      });
      final result = await ScreenAutomationService().performInteraction(
        'click_text',
        {'text': 'Voice search', 'voice_allowed': true},
        taskId: 'test_1',
        step: 2,
      );
      expect(captured!.method, 'performUiAction');
      expect(captured!.arguments['voice_allowed'], false);
      expect(result.accepted, false);
      expect(result.reason, 'voice_control_blocked');
    },
  );
  test(
    'only an explicit original user request opts into app voice controls',
    () {
      for (final request in [
        null,
        'Metti il canale',
        'Cerca il film Voice Search',
        'Non usare il microfono',
        'Usa il microfono senza registrare',
        'Open the search page',
      ]) {
        expect(AppVoicePolicy.allows(request), false, reason: '$request');
      }
      for (final request in [
        'Avvia la ricerca vocale su TV',
        'Usa il microfono',
        'Start voice search in the app',
      ]) {
        expect(AppVoicePolicy.allows(request), true, reason: request);
      }
    },
  );
}
