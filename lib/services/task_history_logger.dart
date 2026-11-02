import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../storage/small_file_transaction.dart';

class TaskHistoryLogger {
  static Future<File> get _localFile async {
    final directory = await getApplicationDocumentsDirectory();
    return File('${directory.path}/task_history.jsonl');
  }

  static const maxBytes = 128 * 1024;
  static const maxEntries = 50;
  static const maxEntryBytes = 16 * 1024;

  static String _short(String text, int limit) {
    final clean = text.replaceAll(
      RegExp(
        r'\bsk-[\w-]{12,}|\bgh[pousr]_[\w]+|https?://\S+|Bearer\s+\S+',
        caseSensitive: false,
      ),
      '[redacted]',
    );
    return clean.length > limit ? clean.substring(0, limit) : clean;
  }

  static List<Map<String, dynamic>> _readTail(File file) {
    if (!file.existsSync()) return [];
    final handle = file.openSync();
    try {
      final length = handle.lengthSync();
      final start = length > maxBytes ? length - maxBytes : 0;
      handle.setPositionSync(start);
      final lines = utf8
          .decode(handle.readSync(length - start), allowMalformed: true)
          .split('\n');
      if (start > 0 && lines.isNotEmpty) lines.removeAt(0);
      final records = <Map<String, dynamic>>[];
      for (final line in lines) {
        if (line.isEmpty || utf8.encode(line).length > maxEntryBytes) continue;
        try {
          final record = jsonDecode(line);
          if (record is Map<String, dynamic>) records.add(record);
        } catch (_) {
          /* A damaged line does not hide the other tasks. */
        }
      }
      return records.length > maxEntries
          ? records.sublist(records.length - maxEntries)
          : records;
    } finally {
      handle.closeSync();
    }
  }

  /// Keep a bounded recent history; never archive rotated records elsewhere.
  static Future<void> logTask(
    String goal,
    String status,
    int totalTokens,
    int steps,
    List<String> trace,
  ) async {
    try {
      final file = await _localFile;
      await smallFileTransaction(file.parent, 'history', () {
        final trimmedTrace = trace
            .skip(trace.length > 24 ? trace.length - 24 : 0)
            .map((line) => _short(line, 480))
            .toList();
        final data = <String, dynamic>{
          'goal': _short(goal.trim(), 600),
          'status': status,
          'total_tokens': totalTokens,
          'steps_taken': steps,
          'trace': trimmedTrace,
          'timestamp': DateTime.now().toIso8601String(),
        };
        while (utf8.encode(jsonEncode(data)).length > maxEntryBytes &&
            trimmedTrace.isNotEmpty) {
          trimmedTrace.removeAt(0);
        }
        final records = [..._readTail(file), data];
        String encode() => "${records.map(jsonEncode).join('\n')}\n";
        while (records.length > maxEntries ||
            utf8.encode(encode()).length > maxBytes) {
          records.removeAt(0);
        }
        final staging = File('${file.path}.next');
        try {
          staging.writeAsStringSync(encode(), flush: true);
          staging.renameSync(file.path);
        } finally {
          if (staging.existsSync()) staging.deleteSync();
        }
      });
    } catch (_) {
      /* Diagnostic storage must not change the task outcome. */
    }
  }

  /// Read only the bounded tail, including when upgrading an older large file.
  static Future<List<Map<String, dynamic>>> readHistory() async {
    try {
      return _readTail(await _localFile).reversed.toList();
    } catch (_) {
      return [];
    }
  }

  /// Clears the task history file
  static Future<void> clearHistory() async {
    try {
      final file = await _localFile;
      await smallFileTransaction(file.parent, 'history', () {
        if (file.existsSync()) file.deleteSync();
      });
    } catch (e) {
      print('Failed to clear task history: $e');
    }
  }

  /// Calculates analytics from task history
  static Future<Map<String, dynamic>> getAnalytics() async {
    final history = await readHistory();
    if (history.isEmpty) {
      return {
        'totalTasks': 0,
        'successRate': 0.0,
        'successCount': 0,
        'failedCount': 0,
      };
    }

    int successCount = 0;
    int failedCount = 0;

    for (final task in history) {
      if (task['status'] == 'Success') {
        successCount++;
      } else if (task['status'] == 'Failed' || task['status'] == 'Cancelled') {
        failedCount++;
      }
    }

    return {
      'totalTasks': history.length,
      'successRate': successCount / history.length,
      'successCount': successCount,
      'failedCount': failedCount,
    };
  }
}
