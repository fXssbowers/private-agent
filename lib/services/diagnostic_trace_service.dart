import 'dart:math';
import 'package:flutter/services.dart';

/// Native code owns one bounded writer shared by all Flutter engines.
class DiagnosticTraceService {
  static const channel = MethodChannel('com.privateagent/accessibility');
  Future<Map<dynamic, dynamic>> state() async =>
      await channel
          .invokeMethod<Map>('diagnosticState')
          .timeout(const Duration(seconds: 3)) ??
      {};
  Future<void> enable(bool value) =>
      channel.invokeMethod('setDiagnosticEnabled', {'enabled': value});
  Future<void> clear() => channel.invokeMethod('clearDiagnosticTrace');
  Future<String?> export() =>
      channel.invokeMethod<String>('exportDiagnosticTrace');
  Future<void> event(
    String task,
    String event,
    Map<String, Object?> fields,
  ) async {
    try {
      await channel
          .invokeMethod('diagnosticEvent', {
            'task': task,
            'event': event,
            'fields': fields,
          })
          .timeout(const Duration(seconds: 1));
    } catch (_) {
      /* Logging cannot change a control outcome. */
    }
  }
}

class DiagnosticSession {
  final service = DiagnosticTraceService();
  final id =
      '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';
  bool _enabled = false;
  Future<void> start() async {
    try {
      _enabled = (await service.state())['enabled'] == true;
    } catch (_) {}
    await event('task_start', {'status': 'started'});
  }

  Future<void> event(String kind, Map<String, Object?> fields) async {
    if (_enabled) {
      await service.event(id, kind, fields);
    }
  }
}

/// The model's rewritten execute_task goal is not authorization to use a mic.
/// Only a caller-supplied original user request can opt into app voice controls.
class AppVoicePolicy {
  static bool allows(String? originalRequest) {
    if (originalRequest == null) return false;
    final text = originalRequest.trim().toLowerCase();
    if (RegExp(
      r"\b(non|senza|evita|not|never|without|don't)\b",
    ).hasMatch(text)) {
      return false;
    }
    return RegExp(
      r'^(avvia|attiva|apri|usa|start|enable|open|use)\s+(la\s+|il\s+|the\s+)?(ricerca vocale|voice search|microfono|microphone)\b',
    ).hasMatch(text);
  }
}
