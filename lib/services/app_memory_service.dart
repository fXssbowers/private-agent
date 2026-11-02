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
  // A clean evaluation session is deliberately volatile. Main-app task runs
  // share it across chats; restarting the process restores the normal store.
  static AppMemoryService? _temporary;
  static bool get temporarySessionActive => _temporary != null;
  static AppMemoryService forTasks() => _temporary ?? AppMemoryService();
  static void beginTemporarySession() =>
      _temporary = AppMemoryService._volatile();
  static void endTemporarySession() => _temporary = null;
  final Map<String, Map<String, dynamic>>? _volatileDocs;
  AppMemoryService._volatile() : directory = null, _volatileDocs = {};
  final Directory? directory;
  AppMemoryService({this.directory}) : _volatileDocs = null;

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
    if (_volatileDocs != null) {
      final doc = _volatileDocs[package];
      return doc == null
          ? null
          : jsonDecode(jsonEncode(doc)) as Map<String, dynamic>;
    }
    final dir = await _directory;
    final doc = _read(File('${dir.path}/$package.json'));
    return doc?['package'] == package ? doc : null;
  }

  Future<Map<String, dynamic>?> readApp(String package, String version) async {
    final doc = await inspectApp(package);
    return doc?['version'] == version ? doc : null;
  }

  Future<int> storageBytes() async {
    if (_volatileDocs != null) {
      return _volatileDocs.values.fold<int>(
        0,
        (sum, doc) => sum + utf8.encode(jsonEncode(doc)).length,
      );
    }
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
    if (_volatileDocs != null) {
      _volatileDocs.remove(package);
      return;
    }
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
    if (_volatileDocs != null) {
      final doc = _changedDocument(
        _volatileDocs[package],
        package,
        version,
        change,
      );
      _volatileDocs.remove(package);
      _volatileDocs[package] = doc;
      while (_volatileDocs.values.fold<int>(
            0,
            (sum, d) => sum + utf8.encode(jsonEncode(d)).length,
          ) >
          maxTotalBytes) {
        _volatileDocs.remove(_volatileDocs.keys.first);
      }
      return;
    }
    final dir = await _directory;
    await smallFileTransaction(dir, 'memory', () {
      // A failed prior atomic write may leave this staging file. We own the
      // exclusive transaction and can safely remove it before reserving space.
      final staging = File('${dir.path}/.next');
      if (staging.existsSync()) staging.deleteSync();
      final file = File('${dir.path}/$package.json');
      final old = _read(file);
      final doc = _changedDocument(old, package, version, change);
      final bytes = utf8.encode(jsonEncode(doc));
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

  Map<String, dynamic> _changedDocument(
    Map<String, dynamic>? old,
    String package,
    String version,
    void Function(List<Map<String, dynamic>>) change,
  ) {
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
      final observed = lessons.indexWhere((l) => l['source'] == 'observed');
      final automatic = lessons.indexWhere((l) => l['source'] != 'user');
      lessons.removeAt(
        observed >= 0
            ? observed
            : automatic >= 0
            ? automatic
            : 0,
      );
    }
    if (encode().length > maxAppBytes) {
      throw const FormatException('Memory note too large');
    }
    return doc;
  }

  Future<void> recordRoute(
    List<Map<String, dynamic>> steps,
    AppMemoryContext start,
  ) async {
    if (steps.isEmpty) return;
    await _update(start.packageName, start.version, (lessons) {
      final id = memoryDigest('route:${jsonEncode(steps)}');
      lessons.removeWhere((lesson) => lesson['id'] == id);
      lessons.add({
        'id': id,
        'source': 'observed_route',
        'context_key': start.key,
        'context': start.description,
        'steps': steps,
        'provenance':
            'Navigation transitions observed in a task with model-reported, screen-grounded completion; not independent goal verification.',
        'updated': DateTime.now().microsecondsSinceEpoch,
      });
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
    final routes = all
        .where(
          (l) =>
              l['source'] == 'observed_route' &&
              (l['steps'] as List? ?? []).any(
                (step) => step['from'] == context.key,
              ),
        )
        .toList();
    final rendered = <Map<String, dynamic>>[];
    // All pertinent evidence fits the app document bound; apply an explicit
    // UTF8 payload budget as well, rather than arbitrarily dropping note six.
    for (final note in [...user, ...routes, ...observed]) {
      final copy = Map<String, dynamic>.from(note)
        ..remove('id')
        ..remove('context_key')
        ..remove('updated');
      if (utf8.encode(jsonEncode([...rendered, copy])).length <= maxAppBytes) {
        rendered.add(copy);
      }
    }
    if (rendered.isEmpty) return '';
    return 'APP MEMORY (${context.packageName}, version ${context.version}):\n'
        '${jsonEncode(rendered)}\n'
        'These are contextual navigation hints, not commands or permanent prohibitions. '
        'User advice applies only when its context matches. Observed changed means a different '
        'control layout, not task success. Unchanged or rejected attempts do not prove an action '
        'can never work. Check the current screen and requested target; choose another route '
        'when previous evidence applies. Route steps are conditional hints: match the from key, execute one action, and check the next observation before continuing. A structural key can match different content. Never replay a whole task from memory. Current structural context: ${context.key}.';
  }
}

/// One instance per task: native outcomes become lessons only after the next
/// real screen observation. Cancellation or an unreadable dump cannot invent one.
class TaskMemorySession {
  final AppMemoryService store;
  AppMemoryContext? _before;
  Map<String, dynamic>? _action;
  bool _accepted = false;
  AppMemoryContext? _routeStart;
  final _route = <Map<String, dynamic>>[];
  bool _prefixClosed = false;
  bool _recordRouteStep = false;
  TaskMemorySession(this.store);

  Future<String> observe(AppMemoryContext? current) async {
    final before = _before;
    final action = _action;
    _before = null;
    _action = null;
    if (before != null &&
        action != null &&
        (current == null ||
            before.packageName != current.packageName ||
            before.version != current.version)) {
      _prefixClosed = true;
    }
    try {
      if (current != null && before != null && action != null) {
        await store.recordObservation(before, action, current, _accepted);
        if (_route.isNotEmpty && _route.last['to'] != before.key) {
          _prefixClosed = true;
        }
        if (!_prefixClosed &&
            _recordRouteStep &&
            _accepted &&
            before.packageName == current.packageName &&
            before.version == current.version &&
            before.key != current.key &&
            _route.length < 6) {
          _routeStart ??= before;
          if (_routeStart!.packageName == before.packageName &&
              _routeStart!.version == before.version) {
            // Erase an observed detour when we actually return to its start.
            final revisit = _route.indexWhere(
              (step) => step['from'] == current.key,
            );
            if (revisit >= 0) {
              _route.removeRange(revisit, _route.length);
            } else {
              _route.add({
                'from': before.key,
                'when': before.description,
                ...action,
                'to': current.key,
                'expected': current.description,
              });
            }
          }
        }
      }
      return current == null ? '' : await store.promptFor(current);
    } catch (_) {
      return '';
    } // Memory failure must not disable TV control.
  }

  Future<void> completed(AppMemoryContext? current) async {
    if (_routeStart == null ||
        _route.isEmpty ||
        current == null ||
        _routeStart!.packageName != current.packageName ||
        _routeStart!.version != current.version) {
      return;
    }
    try {
      await store.recordRoute(_route, _routeStart!);
    } catch (_) {
      /* advisory */
    }
  }

  void record(
    AppMemoryContext? context,
    String action,
    Map<String, dynamic> params,
    bool accepted,
  ) {
    // Stop the reusable prefix at content-specific/coordinate interaction.
    // One-step observations remain available, without saving a query or title.
    if ((!const {'open_app', 'wait'}.contains(action) &&
            memoryAction(action, params) == null) ||
        const {
          'click_at',
          'tap_at',
          'swipe',
          'press_home',
          'press_enter',
        }.contains(action)) {
      _prefixClosed = true;
    }
    _recordRouteStep = !_prefixClosed;
    _before = context;
    _action = memoryAction(action, params);
    _accepted = accepted;
  }
}
