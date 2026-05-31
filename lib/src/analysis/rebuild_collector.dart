import 'dart:async';
import 'package:vm_service/vm_service.dart';

class _WidgetLocation {
  final String name;
  final String file; // short filename
  final int line;
  _WidgetLocation(this.name, this.file, this.line);

  String get key => '$name ($file:$line)';
}

class RebuildCollector {
  final Map<int, _WidgetLocation> _idToLocation = {};
  final Map<String, int> _counts = {};
  // Track animation-like widgets for idle-animation detection
  final Map<String, int> _animationWidgets = {};
  StreamSubscription<Event>? _sub;

  /// Pre-populate id→name from ext.flutter.inspector.widgetLocationIdMap
  /// Must call before start() so reconnect sessions have names from first event.
  void preloadLocationMap(dynamic locationMap) {
    _parseLocations(locationMap);
  }

  void start(VmService service) {
    service.streamListen(EventStreams.kExtension).catchError((_) => Success());

    _sub = service.onExtensionEvent.listen((event) {
      if (event.extensionKind != 'Flutter.RebuiltWidgets' &&
          event.extensionKind != 'Flutter.RepaintWidgets') return;

      final data = event.extensionData?.data ?? event.json;
      if (data == null) return;

      _parseLocations(data['locations']);
      _parseLocationsLegacy(data['newLocations']);

      // events = flat [id, count, id, count, ...]
      final events = data['events'];
      if (events is List && events.length >= 2) {
        for (int i = 0; i + 1 < events.length; i += 2) {
          final id = (events[i] as num?)?.toInt();
          final count = (events[i + 1] as num?)?.toInt() ?? 1;
          if (id == null) continue;
          final loc = _idToLocation[id];
          final key = loc?.key ?? 'Widget#$id';
          _counts[key] = (_counts[key] ?? 0) + count;
          if (loc != null && _isAnimationWidget(loc.name)) {
            _animationWidgets[key] = (_animationWidgets[key] ?? 0) + count;
          }
        }
        return;
      }

      // Fallback: older {widgets:[{widget,count}]} or {counts:{name:n}}
      final widgets = data['widgets'] as List<dynamic>?;
      if (widgets != null) {
        for (final w in widgets) {
          if (w is! Map) continue;
          final name = w['widget']?.toString() ?? w['name']?.toString() ?? 'Unknown';
          final count = (w['count'] as num?)?.toInt() ?? 1;
          _counts[name] = (_counts[name] ?? 0) + count;
        }
      }
      final fallbackCounts = data['counts'] as Map<String, dynamic>?;
      if (fallbackCounts != null) {
        fallbackCounts.forEach((k, v) {
          _counts[k] = (_counts[k] ?? 0) + ((v as num?)?.toInt() ?? 1);
        });
      }
    });
  }

  bool _isAnimationWidget(String name) =>
      name.contains('Transition') ||
      name.contains('Animation') ||
      name.contains('Animated') ||
      name.contains('Fade') ||
      name.contains('Slide') ||
      name.contains('Scale');

  // v2.4+ format: {file: {ids:[...], names:[...], lines:[...], columns:[...]}}
  void _parseLocations(dynamic locations) {
    if (locations is! Map) return;
    locations.forEach((file, fileData) {
      if (fileData is! Map) return;
      final ids = fileData['ids'] as List<dynamic>?;
      final names = fileData['names'] as List<dynamic>?;
      final lines = fileData['lines'] as List<dynamic>?;
      if (ids == null || names == null) return;
      final shortFile = _shortFile(file as String);
      for (int i = 0; i < ids.length && i < names.length; i++) {
        final id = (ids[i] as num?)?.toInt();
        final name = names[i] as String?;
        final line = (lines != null && i < lines.length)
            ? (lines[i] as num?)?.toInt() ?? 0
            : 0;
        if (id != null && name != null && name.isNotEmpty) {
          _idToLocation[id] = _WidgetLocation(name, shortFile, line);
        }
      }
    });
  }

  // Legacy format: {file: [id, line, col, ...]} — no widget names
  void _parseLocationsLegacy(dynamic newLocations) {
    if (newLocations is! Map) return;
    newLocations.forEach((file, entries) {
      if (entries is! List) return;
      final shortFile = _shortFile(file as String);
      for (int i = 0; i + 2 < entries.length; i += 3) {
        final id = (entries[i] as num?)?.toInt();
        final line = (entries[i + 1] as num?)?.toInt() ?? 0;
        if (id != null && !_idToLocation.containsKey(id)) {
          _idToLocation[id] = _WidgetLocation(shortFile, shortFile, line);
        }
      }
    });
  }

  String _shortFile(String path) =>
      path.split('/').last; // keep .dart extension for clarity

  Future<String> stopAndReport() async {
    await _sub?.cancel();
    _sub = null;

    if (_counts.isEmpty) {
      return 'No rebuild events captured.\n'
          'Requires debug mode + Flutter Inspector active.\n'
          'Try: flutter run (not --profile/--release)';
    }

    final sorted = _counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final sb = StringBuffer();
    sb.writeln('Widget Rebuild Counts:');
    sb.writeln('━' * 55);

    for (final e in sorted.take(20)) {
      final flag = e.value > 50
          ? '  ← EXCESSIVE'
          : e.value > 20
              ? '  ← HIGH'
              : '';
      sb.writeln(
          '  ${e.key.padRight(42)} ${e.value.toString().padLeft(5)} rebuilds$flag');
    }

    // Shared-parent detection: widgets with identical counts likely share a parent
    final countGroups = <int, List<String>>{};
    for (final e in sorted.take(20)) {
      countGroups.putIfAbsent(e.value, () => []).add(e.key);
    }
    final sharedParents = countGroups.entries
        .where((e) => e.value.length >= 3 && e.key >= 5)
        .toList()
      ..sort((a, b) => b.key.compareTo(a.key));
    if (sharedParents.isNotEmpty) {
      sb.writeln('');
      sb.writeln('Shared parent rebuilds (multiple widgets same count = parent triggering all):');
      for (final group in sharedParents) {
        // Extract file from first widget key
        final firstKey = group.value.first;
        final fileMatch = RegExp(r'\(([^:]+\.dart)').firstMatch(firstKey);
        final file = fileMatch?.group(1) ?? 'unknown';
        sb.writeln('  ${group.key}× rebuilds — ${group.value.length} widgets in $file share a parent');
        sb.writeln('    → Wrap parent with BlocSelector/const or move state lower in tree');
        // Show line cluster
        final lines = group.value
            .map((k) => RegExp(r':(\d+)\)').firstMatch(k)?.group(1))
            .whereType<String>()
            .toList()
          ..sort();
        if (lines.isNotEmpty) {
          sb.writeln('    Lines: ${lines.join(', ')}');
        }
      }
    }

    // Animation widgets rebuilding = likely running when idle
    if (_animationWidgets.isNotEmpty) {
      sb.writeln('');
      sb.writeln('Animation widgets rebuilding (possible idle animation leak):');
      for (final e in _animationWidgets.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value))) {
        sb.writeln('  ${e.key}: ${e.value} rebuilds — ensure AnimationController.dispose() called');
      }
    }

    final excessive = sorted.where((e) => e.value > 50).toList();
    if (excessive.isNotEmpty) {
      sb.writeln('');
      sb.writeln('Fixes for excessive rebuilds:');
      sb.writeln('  • Wrap stable subtrees with const constructors');
      sb.writeln('  • Add RepaintBoundary around independently-updating widgets');
      sb.writeln('  • Use BlocSelector / select() to narrow rebuild scope');
      sb.writeln('  • Move state lower in tree to avoid rebuilding parents');
    }

    return sb.toString();
  }
}
