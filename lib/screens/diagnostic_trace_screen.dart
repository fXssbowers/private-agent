import 'package:flutter/material.dart';
import '../services/diagnostic_trace_service.dart';

class DiagnosticTraceScreen extends StatefulWidget {
  const DiagnosticTraceScreen({super.key});
  @override
  State<DiagnosticTraceScreen> createState() => _DiagnosticTraceScreenState();
}

class _DiagnosticTraceScreenState extends State<DiagnosticTraceScreen> {
  final _service = DiagnosticTraceService();
  bool _enabled = false;
  bool _busy = true;
  int _bytes = 0;
  String? _message;
  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final state = await _service.state();
      if (mounted) {
        setState(() {
          _enabled = state['enabled'] == true;
          _bytes = state['bytes'] as int? ?? 0;
          _busy = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _message = 'Diagnostics unavailable.';
        });
      }
    }
  }

  Future<void> _run(Future<void> Function() operation) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await operation();
    } catch (_) {
      if (mounted) {
        setState(() {
          _message = 'Operation failed; retry.';
        });
      }
    }
    if (mounted) await _refresh();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('UI diagnostics')),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Text(
          'Records screen states, resolved controls, native outcomes and plan changes. It excludes API keys, typed values, voice transcripts and model reasoning. Enable before starting a new task.',
        ),
        SwitchListTile(
          title: const Text('Record diagnostic trace'),
          value: _enabled,
          onChanged: _busy
              ? null
              : (value) => _run(() => _service.enable(value)),
        ),
        Text(
          '${(_bytes / 1024).toStringAsFixed(1)} KiB / 128 KiB rotating trace. One explicit export up to 128 KiB; combined limit 256 KiB.',
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _busy
              ? null
              : () => _run(() async {
                  final uri = await _service.export();
                  if (mounted) {
                    setState(() {
                      _message = uri == null
                          ? 'Export failed.'
                          : 'Exported local copy: $uri. The next export replaces this copy.';
                    });
                  }
                }),
          child: const Text('Export / replace local copy'),
        ),
        TextButton(
          onPressed: _busy ? null : () => _run(_service.clear),
          child: const Text('Clear trace and exported copy'),
        ),
        if (_busy) const LinearProgressIndicator(),
        if (_message != null) Text(_message!),
      ],
    ),
  );
}
