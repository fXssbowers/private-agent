import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:private_agent/services/screen_automation_service.dart';

class Observation extends ScreenAutomationService {
  @override
  Future<String?> getCurrentPackage() async => 'fixture.app';
  @override
  Future<List<Map<String, dynamic>>> dumpScreen() async => [
    {
      'index': 0,
      'className': 'android.widget.EditText',
      'text': '12:30',
      'isEditable': true,
      'isFocused': true,
      'viewId': 'fixture.app:id/search',
    },
    {
      'index': 1,
      'className': 'android.view.View',
      'isSelected': true,
      'viewId': 'fixture.app:id/selected',
    },
    {'index': 2, 'className': 'android.widget.TextView', 'text': '12:30'},
  ];
}

void main() {
  test(
    'direct touch uses its dedicated native channel and reports rejection honestly',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(
        const MethodChannel('com.privateagent/accessibility'),
        (call) async {
          calls.add(call);
          return false;
        },
      );
      try {
        expect(await ScreenAutomationService().tapAt(50, 60), false);
        expect(calls.single.method, 'tapAt');
        expect(calls.single.arguments, {'x': 50.0, 'y': 60.0});
      } finally {
        messenger.setMockMethodCallHandler(
          const MethodChannel('com.privateagent/accessibility'),
          null,
        );
      }
    },
  );
  test(
    'both screen formats retain actual focus, selection, IDs and time-valued content',
    () async {
      final screen = Observation();
      for (final dump in [
        await screen.getScreenDescription(),
        await screen.getCompressedScreenDescription('search'),
      ]) {
        expect(dump, contains('focused'));
        expect(dump, contains('selected'));
        expect(dump, contains('fixture.app:id/search'));
        expect(dump, contains('fixture.app:id/selected'));
        expect('12:30'.allMatches(dump), hasLength(2));
      }
    },
  );
}
