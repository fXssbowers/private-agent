import 'package:flutter/material.dart';
import '../services/app_launcher_service.dart';
import '../services/app_memory_service.dart';
import '../services/screen_automation_service.dart';

/// User advice is explicit and editable; an AI response cannot invoke this form.
class AppMemoryScreen extends StatefulWidget {
  final AppMemoryService? store;
  final AppLauncherService? appLauncher;
  final ScreenAutomationService? screenService;
  const AppMemoryScreen({
    super.key,
    this.store,
    this.appLauncher,
    this.screenService,
  });
  @override
  State<AppMemoryScreen> createState() => _AppMemoryScreenState();
}

class _AppMemoryScreenState extends State<AppMemoryScreen> {
  AppMemoryService get _store => widget.store ?? AppMemoryService.forTasks();
  late final _screen = widget.screenService ?? ScreenAutomationService();
  final _when = TextEditingController();
  final _advice = TextEditingController();
  final _expected = TextEditingController();
  final _apps = <String, String>{};
  String? _package;
  String? _version;
  String? _storedVersion;
  String _scope = 'any';
  List<dynamic> _lessons = [];
  String? _error;
  int _bytes = 0;
  bool _busy = true;

  @override
  void initState() {
    super.initState();
    _loadApps();
  }

  Future<void> _loadApps() async {
    try {
      final apps = await (widget.appLauncher ?? AppLauncherService())
          .getInstalledApps();
      apps.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      if (!mounted) return;
      setState(() {
        for (final app in apps) {
          _apps[app.packageName] = app.name;
        }
        _busy = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'Could not load applications.';
          _busy = false;
        });
      }
    }
  }

  Future<void> _select(String package) async {
    if (package != _package) {
      _when.clear();
      _advice.clear();
      _expected.clear();
    }
    setState(() {
      _package = package;
      _version = null;
      _storedVersion = null;
      _lessons = [];
      _busy = true;
      _error = null;
    });
    try {
      final version = await _screen.getAppVersion(package);
      final doc = await _store.inspectApp(package);
      final bytes = await _store.storageBytes();
      if (!mounted) return;
      setState(() {
        _version = version;
        _storedVersion = doc?['version'] as String?;
        _lessons = doc?['lessons'] as List? ?? [];
        _bytes = bytes;
        _busy = false;
        if (version == null) {
          _error =
              'App version unavailable. Notes are not reused across unknown versions.';
        }
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'Could not read app memory.';
          _busy = false;
        });
      }
    }
  }

  Future<void> _save() async {
    final package = _package;
    final version = _version;
    if (package == null || version == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _store.saveUserLesson(
        package,
        version,
        when: _when.text,
        advice: _advice.text,
        expected: _expected.text,
        scope: _scope,
      );
      _when.clear();
      _advice.clear();
      _expected.clear();
      if (mounted) await _select(package);
    } catch (_) {
      if (mounted) {
        setState(() {
          _error =
              'Could not save. Use short navigation notes without credentials or URLs; retry if storage is busy.';
          _busy = false;
        });
      }
    }
  }

  Future<void> _clear() async {
    final package = _package;
    if (package == null) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Clear ${_apps[package]} memory?'),
        content: const Text(
          'Remove this app’s learned observations and your navigation notes.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    setState(() {
      _busy = true;
    });
    try {
      await _store.clearApp(package);
      if (mounted) await _select(package);
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'Could not clear memory; retry.';
          _busy = false;
        });
      }
    }
  }

  Future<void> _toggleTemporary() async {
    if (AppMemoryService.temporarySessionActive) {
      AppMemoryService.endTemporarySession();
    } else {
      AppMemoryService.beginTemporarySession();
    }
    _when.clear();
    _advice.clear();
    _expected.clear();
    if (_package != null) {
      await _select(_package!);
    } else {
      setState(() {
        _lessons = [];
        _bytes = 0;
      });
    }
  }

  @override
  void dispose() {
    _when.dispose();
    _advice.dispose();
    _expected.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('App memory')),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Text(
          'Navigation lessons stay on this device. Relevant notes are included when the agent uses the selected app. Each step still needs screen verification.',
        ),
        if (widget.store == null) ...[
          const SizedBox(height: 12),
          Text(
            AppMemoryService.temporarySessionActive
                ? 'Temporary learning session: main-app tasks ignore saved notes. Learning lasts until you end this session or restart the app. Original notes are preserved. Start a new chat before testing.'
                : 'You can test learning from an empty memory in the main app. The floating assistant uses normal saved memory.',
          ),
          TextButton(
            onPressed: _busy ? null : _toggleTemporary,
            child: Text(
              AppMemoryService.temporarySessionActive
                  ? 'End temporary session and discard its learning'
                  : 'Start empty temporary learning session',
            ),
          ),
        ],
        const SizedBox(height: 16),
        DropdownButtonFormField<String>(
          initialValue: _package,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Application'),
          items: _apps.entries
              .map(
                (app) =>
                    DropdownMenuItem(value: app.key, child: Text(app.value)),
              )
              .toList(),
          onChanged: _busy
              ? null
              : (value) {
                  if (value != null) _select(value);
                },
        ),
        const SizedBox(height: 12),
        Text(
          '${(_bytes / 1024).toStringAsFixed(1)} KB / 64 KB total · 8 KB per app',
        ),
        if (_busy) const LinearProgressIndicator(),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(_error!),
          ),
        if (_package != null && _version != null) ...[
          const SizedBox(height: 16),
          const Text(
            'Your navigation note',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          DropdownButtonFormField<String>(
            initialValue: _scope,
            decoration: const InputDecoration(labelText: 'Screen context'),
            items: const [
              DropdownMenuItem(
                value: 'any',
                child: Text('Any screen (check the condition below)'),
              ),
              DropdownMenuItem(
                value: 'input',
                child: Text('Search or text entry'),
              ),
              DropdownMenuItem(
                value: 'navigation',
                child: Text('Navigation menu'),
              ),
              DropdownMenuItem(
                value: 'other',
                child: Text('Playback or other screens'),
              ),
            ],
            onChanged: _busy
                ? null
                : (value) {
                    if (value != null) setState(() => _scope = value);
                  },
          ),
          TextField(
            controller: _when,
            maxLength: 240,
            decoration: const InputDecoration(
              labelText: 'When does this apply?',
              hintText: 'Playing a channel, with the keyboard closed',
            ),
          ),
          TextField(
            controller: _advice,
            maxLength: 240,
            decoration: const InputDecoration(
              labelText: 'What should the agent do?',
              hintText: 'Use Back to open the channel menu',
            ),
          ),
          TextField(
            controller: _expected,
            maxLength: 240,
            decoration: const InputDecoration(
              labelText: 'What should appear next?',
              hintText: 'The channel menu is visible',
            ),
          ),
          FilledButton(
            onPressed: _busy ? null : _save,
            child: const Text('Save navigation note'),
          ),
          const SizedBox(height: 24),
        ],
        if (_package != null) ...[
          if (_storedVersion != null && _storedVersion != _version)
            const Text(
              'Stored notes are from a previous app version and are not used by the agent.',
            ),
          Text(
            '${_lessons.length} notes for ${_apps[_package]}',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          for (final note in _lessons.reversed)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  note['source'] == 'user'
                      ? 'Your advice · ${note["context"]}\n${note["advice"]}\nExpected: ${note["expected"]}'
                      : note['source'] == 'observed_route'
                      ? 'Observed navigation prefix · ${note["context"]}\n${note["steps"]}\n${note["provenance"]}'
                      : 'Observed · ${note["context"]}\n${note["action"]} ${note["target"] ?? note["coordinates"] ?? note["direction"] ?? ""}\nLast: ${note["last_outcome"]}. Changed: ${note["changed"]}, unchanged: ${note["unchanged"]}, rejected: ${note["rejected"]}.\n${note["expected"]}',
                ),
              ),
            ),
          if (_lessons.isEmpty) const Text('No stored notes for this app yet.'),
          TextButton(
            onPressed: _busy ? null : _clear,
            child: const Text('Clear this app’s memory'),
          ),
        ],
      ],
    ),
  );
}
