import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_agent/models/app_memory_context.dart';
import 'package:private_agent/services/app_memory_service.dart';
import 'package:private_agent/storage/small_file_transaction.dart';

const searchScreen =
    'APP: test.tv\n[0] view "" [tap] center:(960,540)\n[1] btn "Cerca" [tap] center:(100,100)';
const resultScreen =
    'APP: test.tv\n[0] view "" [tap] center:(960,540)\n[1] btn "Guida TV" [tap] center:(100,100)\n[2] view "" [tap] center:(200,200)';
AppMemoryContext frame(
  String screen, {
  String app = 'test.tv',
  String version = '1',
}) => AppMemoryContext.fromScreen(app, version, screen)!;

Future<void> observationsInIsolate(String path) async {
  final store = AppMemoryService(directory: Directory(path));
  for (var i = 0; i < 10; i++) {
    await store.recordObservation(
      frame(searchScreen),
      {'action': 'press_back'},
      frame(searchScreen),
      true,
    );
  }
}

void main() {
  late Directory directory;
  late AppMemoryService store;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('app-memory-');
    store = AppMemoryService(directory: directory);
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test(
    'a lesson survives a fresh service and is scoped to app, version and context',
    () async {
      await store.recordObservation(
        frame(searchScreen),
        {'action': 'press_back'},
        frame(searchScreen),
        true,
      );
      final restarted = AppMemoryService(directory: directory);
      expect(
        await restarted.promptFor(frame(searchScreen)),
        contains('unchanged'),
      );
      expect(await restarted.promptFor(frame(resultScreen)), isEmpty);
      expect(
        await restarted.promptFor(frame(searchScreen, app: 'other.tv')),
        isEmpty,
      );
      expect(
        await restarted.promptFor(frame(searchScreen, version: '2')),
        isEmpty,
      );
    },
  );
  test(
    'the next observation provides evidence, accepted click alone does not',
    () async {
      final session = TaskMemorySession(store);
      session.record(frame(searchScreen), 'press_back', {}, true);
      expect(await store.readApp('test.tv', '1'), isNull);
      await session.observe(frame(resultScreen));
      final notes = (await store.readApp('test.tv', '1'))!['lessons'] as List;
      expect(notes.single['last_outcome'], 'changed');
      expect(notes.single['expected'], contains('guida tv'));
      expect(
        await store.promptFor(frame(searchScreen)),
        contains('not task success'),
      );
    },
  );
  test(
    'a later working transition updates a former failure rather than banning Back',
    () async {
      for (var i = 0; i < 2; i++) {
        await store.recordObservation(
          frame(searchScreen),
          {'action': 'press_back'},
          frame(searchScreen),
          false,
        );
      }
      await store.recordObservation(
        frame(searchScreen),
        {'action': 'press_back'},
        frame(resultScreen),
        true,
      );
      final notes = (await store.readApp('test.tv', '1'))!['lessons'] as List;
      expect(notes, hasLength(1));
      expect(notes.single['last_outcome'], 'changed');
      expect(notes.single['changed'], 1);
      expect(notes.single['rejected'], 2);
    },
  );
  test(
    'typed content, titles, raw screen and text target stay out of files',
    () async {
      const privateScreen =
          '$searchScreen\n[2] input "sk-testsecret123456789" [edit] center:(500,500)\n[3] text "Private Film Title"';
      final current = frame(privateScreen);
      final session = TaskMemorySession(store);
      session.record(current, 'type_text', {
        'text': 'private search query',
      }, true);
      await session.observe(current);
      expect(await store.readApp('test.tv', '1'), isNull);
      expect(
        memoryAction('click_text', {'text': 'Private Film Title'}),
        isNull,
      );
      session.record(current, 'click_text', {'text': 'Cerca'}, false);
      await session.observe(current);
      final content = File('${directory.path}/test.tv.json').readAsStringSync();
      expect(content, isNot(contains('sk-testsecret')));
      expect(content, isNot(contains('private search query')));
      expect(content, isNot(contains('Private Film Title')));
      expect(content, isNot(contains('APP:')));
      expect(await store.promptFor(current), contains('cerca'));
    },
  );
  test('unreadable and cross-app observations cannot invent lessons', () async {
    final session = TaskMemorySession(store);
    session.record(frame(searchScreen), 'press_back', {}, true);
    await session.observe(null);
    expect(await store.readApp('test.tv', '1'), isNull);
    session.record(frame(searchScreen), 'press_back', {}, true);
    await session.observe(frame(resultScreen, app: 'other.tv'));
    expect(await store.readApp('test.tv', '1'), isNull);
    expect(AppMemoryContext.fromScreen('test.tv', null, searchScreen), isNull);
    expect(
      AppMemoryContext.fromScreen('test.tv', '1', 'Could not read screen'),
      isNull,
    );
  });
  test('user advice is conditional, prioritized and deduplicated', () async {
    await store.saveUserLesson(
      'test.tv',
      '1',
      when: 'Player, keyboard closed',
      advice: 'Use Back',
      expected: 'Channel menu',
    );
    await store.saveUserLesson(
      'test.tv',
      '1',
      when: 'Player, keyboard closed',
      advice: 'Use Back once and inspect',
      expected: 'Channel menu',
    );
    final notes = (await store.readApp('test.tv', '1'))!['lessons'] as List;
    expect(notes, hasLength(1));
    expect(notes.single['source'], 'user');
    expect(
      await store.promptFor(frame(searchScreen)),
      contains('Use Back once and inspect'),
    );
    expect(
      await store.promptFor(frame(searchScreen)),
      contains('only when its context matches'),
    );
    await store.clearApp('test.tv');
    expect(await store.readApp('test.tv', '1'), isNull);
  });
  test(
    'per-app and total limits use UTF8 bytes and retain at most five prompt notes',
    () async {
      for (var app = 0; app < 25; app++) {
        for (var note = 0; note < 8; note++) {
          await store.saveUserLesson(
            'test.app$app',
            '1',
            when: 'Condition $note',
            advice: List.filled(200, '界').join(),
            expected: List.filled(200, 'è').join(),
          );
          expect(
            await store.storageBytes(),
            lessThanOrEqualTo(AppMemoryService.maxTotalBytes),
          );
          for (final file in directory.listSync().whereType<File>().where(
            (f) => f.path.endsWith('.json'),
          )) {
            expect(
              file.lengthSync(),
              lessThanOrEqualTo(AppMemoryService.maxAppBytes),
            );
          }
        }
      }
      final prompt = await store.promptFor(
        frame(searchScreen, app: 'test.app24'),
      );
      final payload = prompt.split('\n')[1];
      expect(jsonDecode(payload) as List, hasLength(5));
    },
  );
  test(
    'multiple Flutter isolates merge observations without losing counters',
    () async {
      final path = directory.path;
      await Future.wait([
        Isolate.run(() => observationsInIsolate(path)),
        Isolate.run(() => observationsInIsolate(path)),
      ]);
      final notes = (await store.readApp('test.tv', '1'))!['lessons'] as List;
      expect(notes.single['unchanged'], 20);
    },
  );
  test(
    'corruption, abandoned staging and old process locks recover safely',
    () async {
      File('${directory.path}/test.tv.json').writeAsStringSync('{broken');
      File('${directory.path}/.next').writeAsStringSync('partial');
      File('${directory.path}/.memory.99999999.lock').writeAsStringSync('');
      await store.recordObservation(
        frame(searchScreen),
        {'action': 'press_back'},
        frame(resultScreen),
        true,
      );
      expect(await store.readApp('test.tv', '1'), isNotNull);
      expect(File('${directory.path}/.next').existsSync(), false);
      expect(
        File('${directory.path}/.memory.99999999.lock').existsSync(),
        false,
      );
    },
  );
  test('active lock is never stolen and errors release ownership', () async {
    final lock = File('${directory.path}/.memory.$pid.lock')
      ..writeAsStringSync('');
    await expectLater(
      store.clearApp('test.tv'),
      throwsA(isA<FileSystemException>()),
    );
    expect(lock.existsSync(), true);
    lock.deleteSync();
    await expectLater(
      smallFileTransaction(
        directory,
        'memory',
        () => throw StateError('fixture'),
      ),
      throwsStateError,
    );
    expect(lock.existsSync(), false);
  });
  test('invalid app IDs and sensitive user notes cannot be stored', () async {
    await expectLater(
      store.saveUserLesson(
        '../escape',
        '1',
        when: 'Player',
        advice: 'Back',
        expected: 'Menu',
      ),
      throwsFormatException,
    );
    await expectLater(
      store.saveUserLesson(
        'test.tv',
        '1',
        when: 'Player',
        advice: 'Bearer secretvalue',
        expected: 'Menu',
      ),
      throwsFormatException,
    );
    expect(await store.storageBytes(), 0);
  });
  test('unrelated user contexts cannot hide a matching observation', () async {
    await store.recordObservation(
      frame(searchScreen),
      {'action': 'press_back'},
      frame(searchScreen),
      false,
    );
    for (var i = 0; i < 5; i++) {
      await store.saveUserLesson(
        'test.tv',
        '1',
        when: 'Text input $i',
        advice: 'Inspect input',
        expected: 'Results',
        scope: 'input',
      );
    }
    final prompt = await store.promptFor(frame(searchScreen));
    expect(prompt, contains('"source":"observed"'));
    expect(prompt, isNot(contains('Text input')));
    for (var i = 0; i < 5; i++) {
      await store.saveUserLesson(
        'test.tv',
        '1',
        when: 'General advice $i',
        advice: 'Inspect screen',
        expected: 'Navigation',
      );
    }
    final notes =
        jsonDecode((await store.promptFor(frame(searchScreen))).split('\n')[1])
            as List;
    expect(notes.length, lessThanOrEqualTo(5));
    expect(notes.any((n) => n['source'] == 'observed'), true);
  });
}
