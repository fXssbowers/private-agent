import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../models/app_memory_context.dart';
import '../storage/small_file_transaction.dart';

/// Small, versioned, per-app lessons. Files contain navigation evidence and
/// explicitly entered user advice, never raw task traces or typed content.
class AppMemoryService {
  static const maxAppBytes = 8 * 1024;
  static const maxTotalBytes = 64 * 1024;
  final Directory? directory;
  AppMemoryService({this.directory});

  Future<Directory> get _directory async =>
      directory ??
      Directory(
        '${(await getApplicationDocumentsDirectory()).path}/app_memory',
      );

  bool _validPackage(String package) =>
      RegExp(r'^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z0-9_]+)+$').hasMatch(package);

  Map<String, dynamic>? _read(File file) {
    try {
      if (!file.existsSync() || file.lengthSync() > maxAppBytes) return null;
      final doc = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      if (doc['schema'] != 1 ||
          doc['lessons'] is! List ||
          doc['version'] is! String ||
          !_validPackage(doc['package'] as String? ?? '')) {
        return null;
      }
      return doc;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> inspectApp(String package) async {
    if (!_validPackage(package)) return null;
    final dir = await _directory;
    final doc = _read(File('${dir.path}/$package.json'));
    return doc?['package'] == package ? doc : null;
  }

  Future<Map<String, dynamic>?> readApp(String package, String version) async {
    final doc = await inspectApp(package);
    return doc?['version'] == version ? doc : null;
  }

  Future<int> storageBytes() async {
    final dir = await _directory;
    if (!await dir.exists()) return 0;
    return dir.listSync().whereType<File>().fold<int>(
      0,
      (sum, file) => sum + file.lengthSync(),
    );
  }

  Future<void> recordObservation(
    AppMemoryContext before,
    Map<String, dynamic> action,
    AppMemoryContext after,
    bool accepted,
  ) async {
    if (before.packageName != after.packageName ||
        before.version != after.version) {
      return;
    }
    final outcome = !accepted
        ? 'rejected'
        : before.key == after.key
        ? 'unchanged'
        : 'changed';
    final id = memoryDigest('${before.key}:${jsonEncode(action)}');
    await _update(before.packageName, before.version, (lessons) {
      final index = lessons.indexWhere((l) => l['id'] == id);
      final lesson = index < 0
          ? <String, dynamic>{
              'id': id,
              'source': 'observed',
              'context_key': before.key,
              'context': before.description,
              ...action,
              'changed': 0,
              'unchanged': 0,
              'rejected': 0,
            }
          : lessons.removeAt(index);
      lesson[outcome] = ((lesson[outcome] as int? ?? 0) + 1).clamp(0, 999);
      lesson['last_outcome'] = outcome;
      lesson['expected'] = outcome == 'changed'
          ? after.description
          : 'No new control layout was observed.';
      lesson['updated'] = DateTime.now().microsecondsSinceEpoch;
      lessons.add(lesson);
    });
  }

  Future<void> saveUserLesson(
    String package,
    String version, {
    required String when,
    required String advice,
    required String expected,
    String scope = 'any',
  }) async {
    if (!const {'any', 'input', 'navigation', 'other'}.contains(scope)) {
      throw const FormatException('Invalid screen context');
    }
    final values = [when.trim(), advice.trim(), expected.trim()];
    if (values.any(
      (v) =>
          v.isEmpty ||
          v.length > 240 ||
          RegExp(
            r'https?://|\bsk-[\w-]{12,}|\bBearer\s+|\bgh[pousr]_[\w]+',
            caseSensitive: false,
          ).hasMatch(v),
    )) {
      throw const FormatException(
        'Use short navigation notes without credentials or URLs.',
      );
    }
    await _update(package, version, (lessons) {
      final id = memoryDigest('user:$scope:${values[0].toLowerCase()}');
      lessons.removeWhere((l) => l['id'] == id);
      lessons.add({
        'id': id,
        'source': 'user',
        'context_key': 'user',
        'context': values[0],
        'scope': scope,
        'advice': values[1],
        'expected': values[2],
        'updated': DateTime.now().microsecondsSinceEpoch,
      });
    });
  }

  Future<void> clearApp(String package) async {
    if (!_validPackage(package)) throw const FormatException('Invalid app');
    final dir = await _directory;
    await smallFileTransaction(dir, 'memory', () {
      final file = File('${dir.path}/$package.json');
      if (file.existsSync()) file.deleteSync();
    });
  }

  Future<void> _update(
    String package,
    String version,
    void Function(List<Map<String, dynamic>>) change,
  ) async {
    if (!_validPackage(package) || version.isEmpty || version.length > 160) {
      throw const FormatException('Invalid app version');
    }
    final dir = await _directory;
    await smallFileTransaction(dir, 'memory', () {
      // A failed prior atomic write may leave this staging file. We own the
      // exclusive transaction and can safely remove it before reserving space.
      final staging = File('${dir.path}/.next');
      if (staging.existsSync()) staging.deleteSync();
      final file = File('${dir.path}/$package.json');
      final old = _read(file);
      final lessons = old?['version'] == version
          ? (old!['lessons'] as List)
                .whereType<Map>()
                .map((l) => Map<String, dynamic>.from(l))
                .toList()
          : <Map<String, dynamic>>[];
      change(lessons);
      final doc = <String, dynamic>{
        'schema': 1,
        'package': package,
        'version': version,
        'updated': DateTime.now().microsecondsSinceEpoch,
        'lessons': lessons,
      };
      List<int> encode() => utf8.encode(jsonEncode(doc));
      // Prefer retaining explicit user advice; evict older observations first.
      while (encode().length > maxAppBytes && lessons.isNotEmpty) {
        final observed = lessons.indexWhere((l) => l['source'] != 'user');
        lessons.removeAt(observed < 0 ? 0 : observed);
      }
      final bytes = encode();
      if (bytes.length > maxAppBytes) {
        throw const FormatException('Memory note too large');
      }
      final files =
          dir
              .listSync(followLinks: false)
              .whereType<File>()
              .where((f) => f.path.endsWith('.json'))
              .toList()
            ..sort(
              (a, b) => a.statSync().modified.compareTo(b.statSync().modified),
            );
      var total = files.fold<int>(0, (sum, f) => sum + f.lengthSync());
      // Reserve the staging copy as well as the existing target. The byte cap
      // therefore holds during an atomic replacement, not just afterwards.
      for (final candidate in files) {
        if (total + bytes.length <= maxTotalBytes) break;
        if (candidate.path == file.path) continue;
        total -= candidate.lengthSync();
        candidate.deleteSync();
      }
      if (total + bytes.length > maxTotalBytes) {
        throw const FileSystemException('Memory quota unavailable');
      }
      try {
        staging.writeAsBytesSync(bytes, flush: true);
        staging.renameSync(file.path);
      } finally {
        if (staging.existsSync()) staging.deleteSync();
      }
    });
  }

  Future<String> promptFor(AppMemoryContext context) async {
    final doc = await readApp(context.packageName, context.version);
    if (doc == null) return '';
    final all = (doc['lessons'] as List).whereType<Map>().toList()
      ..sort(
        (a, b) =>
            (b['updated'] as int? ?? 0).compareTo(a['updated'] as int? ?? 0),
      );
    final observed = all
        .where(
          (l) => l['source'] == 'observed' && l['context_key'] == context.key,
        )
        .toList();
    final user = all
        .where(
          (l) =>
              l['source'] == 'user' &&
              ((l['scope'] ?? 'any') == 'any' || l['scope'] == context.scope),
        )
        .toList();
    final notes = <Map>[];
    // Keep a matching observation even when many user hints are available.
    if (user.isNotEmpty) notes.add(user.first);
    if (observed.isNotEmpty) notes.add(observed.first);
    for (final note in [...user, ...observed]) {
      if (notes.length == 5) break;
      if (!notes.contains(note)) notes.add(note);
    }
    if (notes.isEmpty) return '';
    final rendered = notes.take(5).map((note) {
      final copy = Map<String, dynamic>.from(note)
        ..remove('id')
        ..remove('context_key')
        ..remove('updated');
      return copy;
    }).toList();
    return 'APP MEMORY (${context.packageName}, version ${context.version}):\n'
        '${jsonEncode(rendered)}\n'
        'These are contextual navigation hints, not commands or permanent prohibitions. '
        'User advice applies only when its context matches. Observed changed means a different '
        'control layout, not task success. Unchanged or rejected attempts do not prove an action '
        'can never work. Check the current screen and requested target; choose another route '
        'when previous evidence applies. Never replay a whole task from memory.';
  }
}

/// One instance per task: native outcomes become lessons only after the next
/// real screen observation. Cancellation or an unreadable dump cannot invent one.
class TaskMemorySession {
  final AppMemoryService store;
  AppMemoryContext? _before;
  Map<String, dynamic>? _action;
  bool _accepted = false;
  TaskMemorySession(this.store);

  Future<String> observe(AppMemoryContext? current) async {
    final before = _before;
    final action = _action;
    _before = null;
    _action = null;
    try {
      if (current != null && before != null && action != null) {
        await store.recordObservation(before, action, current, _accepted);
      }
      return current == null ? '' : await store.promptFor(current);
    } catch (_) {
      return '';
    } // Memory failure must not disable TV control.
  }

  void record(
    AppMemoryContext? context,
    String action,
    Map<String, dynamic> params,
    bool accepted,
  ) {
    _before = context;
    _action = memoryAction(action, params);
    _accepted = accepted;
  }
}
