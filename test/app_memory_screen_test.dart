import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:installed_apps/app_info.dart';
import 'package:private_agent/screens/app_memory_screen.dart';
import 'package:private_agent/services/app_memory_service.dart';
import 'package:private_agent/services/app_launcher_service.dart';
import 'package:private_agent/services/screen_automation_service.dart';

class Apps extends AppLauncherService {
  @override
  Future<List<AppInfo>> getInstalledApps() async => [
    AppInfo.create({'name': 'App A', 'package_name': 'test.a'}),
    AppInfo.create({'name': 'App B', 'package_name': 'test.b'}),
  ];
}

class Versions extends ScreenAutomationService {
  @override
  Future<String?> getAppVersion(String packageName) async => '2';
}

// File persistence is covered by app_memory_test. These controlled resource
// responses isolate app-switch/error UI behavior from the widget fake clock.
class MemoryStore extends AppMemoryService {
  final documents = <String, Map<String, dynamic>>{};
  bool failSecond = false;
  @override
  Future<Map<String, dynamic>?> inspectApp(String package) async {
    if (failSecond && package == 'test.b') throw StateError('fixture');
    return documents[package];
  }

  @override
  Future<int> storageBytes() async => 128;
  @override
  Future<void> clearApp(String package) async {
    documents.remove(package);
  }
}

Future<void> chooseApp(WidgetTester tester, String label) async {
  await tester.tap(find.byType(DropdownButtonFormField<String>).first);
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

Map<String, dynamic> noteFor(String version) => {
  'version': version,
  'lessons': [
    {
      'source': 'user',
      'context': 'Player',
      'advice': 'Back',
      'expected': 'Menu',
    },
  ],
};
void main() {
  testWidgets('old-version notes stay inspectable and can be cleared', (
    tester,
  ) async {
    final store = MemoryStore()..documents['test.a'] = noteFor('1');
    await tester.pumpWidget(
      MaterialApp(
        home: AppMemoryScreen(
          store: store,
          appLauncher: Apps(),
          screenService: Versions(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await chooseApp(tester, 'App A');
    await tester.scrollUntilVisible(
      find.textContaining('previous app version'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('previous app version'), findsOneWidget);
    expect(await store.readApp('test.a', '2'), isNull);
    final clear = find.text('Clear this app’s memory');
    await tester.scrollUntilVisible(
      clear,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(clear);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear').last);
    await tester.pumpAndSettle();
    expect(await store.inspectApp('test.a'), isNull);
  });
  testWidgets(
    'a failed app switch cannot reuse the prior app version or form',
    (tester) async {
      final store = MemoryStore()
        ..documents['test.a'] = noteFor('2')
        ..failSecond = true;
      await tester.pumpWidget(
        MaterialApp(
          home: AppMemoryScreen(
            store: store,
            appLauncher: Apps(),
            screenService: Versions(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await chooseApp(tester, 'App A');
      expect(find.text('Save navigation note'), findsOneWidget);
      await chooseApp(tester, 'App B');
      expect(find.text('Could not read app memory.'), findsOneWidget);
      expect(find.text('Save navigation note'), findsNothing);
      expect(find.textContaining('Your advice · Player'), findsNothing);
      expect(store.documents.containsKey('test.b'), false);
    },
  );
}
