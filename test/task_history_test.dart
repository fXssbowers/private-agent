import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_agent/services/task_history_logger.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('bounded-history-');
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
    'history rotates by count and encoded bytes while preserving latest result',
    () async {
      for (var i = 0; i < 65; i++) {
        await TaskHistoryLogger.logTask(
          'goal $i',
          'Failed',
          i,
          15,
          List.filled(24, List.filled(480, '界').join()),
        );
        expect(
          File('${directory.path}/task_history.jsonl').lengthSync(),
          lessThanOrEqualTo(TaskHistoryLogger.maxBytes),
        );
      }
      final records = await TaskHistoryLogger.readHistory();
      expect(records.length, lessThanOrEqualTo(50));
      expect(records.first['goal'], 'goal 64');
      expect(records.first['status'], 'Failed');
      expect(records.first['total_tokens'], 64);
      expect(
        utf8.encode(jsonEncode(records.first)).length,
        lessThanOrEqualTo(TaskHistoryLogger.maxEntryBytes),
      );
    },
  );
  test(
    'large legacy and damaged lines do not erase readable recent results',
    () async {
      final file = File('${directory.path}/task_history.jsonl');
      file.writeAsStringSync(
        '${List.filled(140000, 'x').join()}\n{broken\n${jsonEncode({'goal': 'previous', 'status': 'Failed'})}\n',
      );
      expect(
        (await TaskHistoryLogger.readHistory()).single['goal'],
        'previous',
      );
      await TaskHistoryLogger.logTask('latest', 'Success', 1, 1, []);
      expect(file.lengthSync(), lessThanOrEqualTo(TaskHistoryLogger.maxBytes));
      expect((await TaskHistoryLogger.readHistory()).map((r) => r['goal']), [
        'latest',
        'previous',
      ]);
    },
  );
  test(
    'history redacts credential patterns and clear removes current history',
    () async {
      await TaskHistoryLogger.logTask('Bearer secret', 'Failed', 1, 1, [
        'sk-testsecret123456789',
        'https://server.example/private',
      ]);
      final file = File('${directory.path}/task_history.jsonl');
      expect(file.readAsStringSync(), isNot(contains('secret')));
      expect(file.readAsStringSync(), isNot(contains('server.example')));
      await TaskHistoryLogger.clearHistory();
      expect(await TaskHistoryLogger.readHistory(), isEmpty);
    },
  );
}
