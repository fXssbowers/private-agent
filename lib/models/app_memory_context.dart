import 'dart:convert';
import 'package:crypto/crypto.dart';

String memoryDigest(String value) =>
    sha256.convert(utf8.encode(value)).toString();

const memoryNavigationLabels = {
  'search',
  'cerca',
  'ricerca',
  'guida tv',
  'tv guide',
  'cronologia',
  'history',
  'indietro',
  'back',
  'preferiti',
  'favorites',
  'tutti i canali',
  'all channels',
};

/// Structural context, never a stored copy of screen text or search queries.
class AppMemoryContext {
  final String packageName;
  final String version;
  final String key;
  final String description;
  final String scope;

  AppMemoryContext._(
    this.packageName,
    this.version,
    this.key,
    this.description,
    this.scope,
  );

  static AppMemoryContext? fromScreen(
    String? packageName,
    String? version,
    String screen,
  ) {
    if (packageName == null ||
        version == null ||
        version.isEmpty ||
        !RegExp(
          r'^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z0-9_]+)+$',
        ).hasMatch(packageName) ||
        packageName == 'com.orailnoor.privateagent') {
      return null;
    }
    final anchors = <String>{};
    final controls = <String>[];
    var editable = false;
    var keyboard = false;
    for (final line in screen.split('\n')) {
      for (final label in RegExp(r'"([^"\n]*)"').allMatches(line)) {
        final text = label[1]!.trim().toLowerCase();
        if (memoryNavigationLabels.contains(text)) anchors.add(text);
      }
      if (line.contains('KeyboardStatus') || line.contains('keyboardstatus')) {
        keyboard = true;
      }
      if (RegExp(r'\b(edit|editable)\b').hasMatch(line)) editable = true;
      if (!RegExp(
        r'\b(tap|clickable|edit|editable|scroll|scrollable)\b',
      ).hasMatch(line)) {
        continue;
      }
      controls.add(
        line
            .replaceAll(RegExp(r'"[^"\n]*"'), '"<content>"')
            .replaceAll(RegExp(r'^\s*\[\d+\]\*?'), '')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim(),
      );
    }
    if (controls.isEmpty) return null; // An unreadable dump teaches nothing.
    final labels = anchors.toList()..sort();
    final shape = jsonEncode([controls, labels, editable, keyboard]);
    final description =
        '${controls.length} interactive controls; '
        '${editable ? "text input visible" : "no text input"}; '
        '${keyboard ? "keyboard visible" : "keyboard not reported"}; '
        'navigation: ${labels.isEmpty ? "unlabelled" : labels.join(", ")}';
    return AppMemoryContext._(
      packageName,
      version,
      memoryDigest(shape),
      description,
      editable || keyboard
          ? 'input'
          : anchors.isNotEmpty
          ? 'navigation'
          : 'other',
    );
  }
}

/// Only navigation actions are learned. Typed content, goals and app launches
/// are intentionally absent. Text targets must be known navigation labels; content titles are not learned.
Map<String, dynamic>? memoryAction(String action, Map<String, dynamic> params) {
  switch (action) {
    case 'click_text':
      final text = params['text'];
      if (text is! String || text.trim().isEmpty) return null;
      final target = text.trim().toLowerCase();
      if (!memoryNavigationLabels.contains(target)) return null;
      return {'action': action, 'target': target};
    case 'click_at':
    case 'tap_at':
    case 'swipe':
      final keys = action != 'swipe'
          ? ['x', 'y']
          : ['startX', 'startY', 'endX', 'endY'];
      final target = <String, double>{};
      for (final key in keys) {
        final value = params[key];
        if (value is! num || !value.isFinite || value < 0 || value > 10000) {
          return null;
        }
        target[key] = value.toDouble();
      }
      return {'action': action, 'coordinates': target};
    case 'scroll':
      final direction = params['direction'];
      if (!const {'up', 'down', 'left', 'right'}.contains(direction)) {
        return null;
      }
      return {'action': action, 'direction': direction};
    case 'press_back':
    case 'press_home':
    case 'press_enter':
      return {'action': action};
    default:
      return null;
  }
}
