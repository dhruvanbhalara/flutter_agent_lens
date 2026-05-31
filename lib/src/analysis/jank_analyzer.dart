import 'package:vm_service/vm_service.dart';

class FrameData {
  final int frameNumber;
  final int uiStartMicros;
  final int uiDurationMicros;      // build time (Dart work)
  final int rasterDurationMicros;  // raster time (GPU work)
  final int totalDurationMicros;   // elapsed wall time (includes vsync wait)

  const FrameData({
    required this.frameNumber,
    required this.uiStartMicros,
    required this.uiDurationMicros,
    required this.rasterDurationMicros,
    required this.totalDurationMicros,
  });

  // Actual CPU/GPU work — excludes vsync overhead idle time
  int get workDurationMicros => uiDurationMicros + rasterDurationMicros;

  // Jank = actual work exceeds budget, not wall time (vsync idle inflates elapsed)
  bool isJanky({int targetFps = 60}) =>
      workDurationMicros > (1000000 ~/ targetFps);
}

class JankAnalyzer {
  /// Primary method: collect FrameTiming events from flutter.frame extension stream.
  /// Flutter emits pre-computed build+raster+vsync breakdown per frame.
  /// Much more accurate than parsing raw timeline events.
  Future<List<FrameData>> collectFromFrameTimings(
    VmService service,
    String isolateId,
    Duration window,
  ) async {
    final frames = <FrameData>[];

    await service.streamListen(EventStreams.kExtension).catchError((_) => Success());

    // Kick engine to produce frames — needed on Android/emulator when app is idle
    await service.callServiceExtension(
      'ext.ui.window.scheduleFrame',
      isolateId: isolateId,
    ).catchError((_) => Response());

    final sub = service.onExtensionEvent.listen((event) {
      if (event.extensionKind != 'Flutter.Frame') return;
      final data = event.extensionData?.data ?? event.json;
      if (data == null) return;

      // Flutter.Frame payload:
      // { number, startTime, elapsed, build, raster, vsyncOverhead }
      // All times in microseconds
      final build = (data['build'] as num?)?.toInt() ?? 0;
      final raster = (data['raster'] as num?)?.toInt() ?? 0;
      final elapsed = (data['elapsed'] as num?)?.toInt() ??
          (build + raster); // elapsed = build + raster + vsyncOverhead
      final startTime = (data['startTime'] as num?)?.toInt() ?? 0;

      if (elapsed <= 0 && build <= 0) return;

      final total = elapsed > 0 ? elapsed : (build + raster);
      frames.add(FrameData(
        frameNumber: frames.length + 1,
        uiStartMicros: startTime,
        uiDurationMicros: build,
        rasterDurationMicros: raster,
        totalDurationMicros: total,
      ));
    });

    await Future.delayed(window);
    await sub.cancel();
    return frames;
  }

  /// Fallback: parse raw timeline — use async phase ('b'/'e') for [Dart] Frame
  /// and sync phase ('B'/'E') for [Embedder] raster events.
  List<FrameData> parseFrames(Timeline timeline) {
    final events = timeline.traceEvents ?? [];

    final uiFrames = <_RawFrame>[];
    final rasterFrames = <_RawFrame>[];
    final Map<String, int> asyncBegin = {}; // async frames: key = 'name|id'
    final Map<String, int> syncBegin = {};  // sync frames: key = 'name|tid'

    for (final event in events) {
      final raw = event.json;
      if (raw == null) continue;
      final name = raw['name'] as String? ?? '';
      final ph = raw['ph'] as String? ?? '';
      final ts = (raw['ts'] as num?)?.toInt() ?? 0;
      final tid = raw['tid'].toString();
      final cat = raw['cat'] as String? ?? '';
      // Async events use 'id' for correlation, not tid
      final id = raw['id']?.toString() ?? raw['id2']?.toString() ?? tid;

      // ── UI frames ────────────────────────────────────────────────────────
      // [Dart] Frame is async (ph='b'/'e') — TimelineTask in scheduler/binding.dart
      if (name == 'Frame' && cat == 'Dart') {
        if (ph == 'b') {
          asyncBegin['frame|$id'] = ts;
        } else if (ph == 'e') {
          final begin = asyncBegin.remove('frame|$id');
          if (begin != null && ts > begin) {
            uiFrames.add(_RawFrame(begin, ts - begin));
          }
        }
      }

      // [Embedder] Animator::BeginFrame is sync — fallback if async Frame absent
      if (name == 'Animator::BeginFrame' && cat == 'Embedder') {
        if (ph == 'B') {
          syncBegin['animbegin|$tid'] = ts;
        } else if (ph == 'E') {
          final begin = syncBegin.remove('animbegin|$tid');
          if (begin != null && ts > begin) {
            uiFrames.add(_RawFrame(begin, ts - begin));
          }
        }
      }

      // ── Raster frames ─────────────────────────────────────────────────────
      // [Embedder] GPURasterizer::Draw — sync duration event on raster thread
      if ((name == 'GPURasterizer::Draw' ||
              name == 'CompositorContext::ScopedFrame::Raster') &&
          cat == 'Embedder') {
        if (ph == 'B') {
          syncBegin['raster|$tid'] = ts;
        } else if (ph == 'E') {
          final begin = syncBegin.remove('raster|$tid');
          if (begin != null && ts > begin) {
            rasterFrames.add(_RawFrame(begin, ts - begin));
          }
        } else if (ph == 'X') {
          final dur = (raw['dur'] as num?)?.toInt() ?? 0;
          if (dur > 0) rasterFrames.add(_RawFrame(ts, dur));
        }
      }
    }

    if (uiFrames.isEmpty) return [];

    uiFrames.sort((a, b) => a.start.compareTo(b.start));
    rasterFrames.sort((a, b) => a.start.compareTo(b.start));

    // Timestamp-based pairing: match each UI frame to nearest raster frame
    final frames = <FrameData>[];
    int rIdx = 0;

    for (int i = 0; i < uiFrames.length; i++) {
      final ui = uiFrames[i];
      while (rIdx < rasterFrames.length &&
          rasterFrames[rIdx].start < ui.start) {
        rIdx++;
      }
      int rasterDur = 0;
      if (rIdx < rasterFrames.length) {
        final r = rasterFrames[rIdx];
        if (r.start - ui.start < 33000) {
          rasterDur = r.duration;
          rIdx++;
        }
      }
      final total = ui.duration > rasterDur ? ui.duration : rasterDur;
      frames.add(FrameData(
        frameNumber: i + 1,
        uiStartMicros: ui.start,
        uiDurationMicros: ui.duration,
        rasterDurationMicros: rasterDur,
        totalDurationMicros: total,
      ));
    }

    return frames;
  }

  List<String> debugEventNames(Timeline timeline) {
    final names = <String>{};
    for (final e in timeline.traceEvents ?? []) {
      final name = e.json?['name'] as String?;
      final cat = e.json?['cat'] as String?;
      final ph = e.json?['ph'] as String?;
      if (name != null) names.add('[$cat] (ph=$ph) $name');
    }
    return names.toList()..sort();
  }

  Map<String, int> debugFrameCounts(Timeline timeline) {
    int uiAsync = 0, uiSync = 0, rasterCount = 0;
    final total = timeline.traceEvents?.length ?? 0;

    for (final e in timeline.traceEvents ?? []) {
      final raw = e.json;
      if (raw == null) continue;
      final name = raw['name'] as String? ?? '';
      final cat = raw['cat'] as String? ?? '';
      final ph = raw['ph'] as String? ?? '';

      if (name == 'Frame' && cat == 'Dart' && ph == 'b') uiAsync++;
      if (name == 'Animator::BeginFrame' && cat == 'Embedder' && ph == 'B') uiSync++;
      if ((name == 'GPURasterizer::Draw' ||
              name == 'CompositorContext::ScopedFrame::Raster') &&
          cat == 'Embedder' &&
          (ph == 'B' || ph == 'X')) rasterCount++;
    }
    return {
      'total_events': total,
      'ui_async_frames': uiAsync,   // [Dart] Frame async — primary
      'ui_sync_frames': uiSync,     // Animator::BeginFrame sync — fallback
      'raster_frames': rasterCount,
    };
  }

  String generateReport(List<FrameData> frames,
      {int targetFps = 60, bool fromFrameTimings = false}) {
    if (frames.isEmpty) {
      return 'No frame data captured. Interact with the app during recording window.';
    }

    final budgetMicros = 1000000 ~/ targetFps;
    final janky = frames.where((f) => f.isJanky(targetFps: targetFps)).toList();
    final jankyPct = (janky.length / frames.length * 100).toStringAsFixed(1);

    final uiJank =
        janky.where((f) => f.uiDurationMicros > budgetMicros).length;
    final rasterJank = janky
        .where((f) =>
            f.rasterDurationMicros > budgetMicros &&
            f.uiDurationMicros <= budgetMicros)
        .length;

    final sorted = [...frames]
      ..sort((a, b) => b.workDurationMicros.compareTo(a.workDurationMicros));

    String fpsNote = '';
    if (frames.length >= 2) {
      final windowMicros =
          frames.last.uiStartMicros - frames.first.uiStartMicros;
      if (windowMicros > 0) {
        final rawFps = (frames.length - 1) / (windowMicros / 1e6);
        // Cap at targetFps+10 — higher values indicate stale timeline events
        final displayFps = rawFps > targetFps + 10
            ? targetFps.toDouble()
            : rawFps;
        fpsNote = ' (~${displayFps.toStringAsFixed(1)} fps)';
      }
    }

    final source = fromFrameTimings ? 'Flutter.Frame events' : 'timeline parse';
    final hasRaster = frames.any((f) => f.rasterDurationMicros > 0);

    final sb = StringBuffer();
    sb.writeln(
        'Frame Analysis — ${frames.length} frames$fpsNote via $source');
    sb.writeln('Budget: ${budgetMicros ~/ 1000}ms at ${targetFps}fps');
    sb.writeln('━' * 60);
    sb.writeln(
        'Janky: ${janky.length}/${frames.length} ($jankyPct%) — ${_severity(janky.length, frames.length)}');

    if (!hasRaster) {
      sb.writeln(
          'Raster timing: unavailable in debug mode (run --profile for raster data)');
    }

    if (uiJank > 0) {
      sb.writeln('');
      sb.writeln('UI jank: $uiJank frames over budget');
      sb.writeln('  → Dart code slow. Check build(), layout, heavy compute.');
    }
    if (rasterJank > 0) {
      sb.writeln('');
      sb.writeln('Raster jank: $rasterJank frames');
      sb.writeln('  → GPU slow. Check: large images, clips, opacity, shadows.');
    }

    sb.writeln('');
    sb.writeln('Worst 5 frames:');
    for (final f in sorted.take(5)) {
      final r = hasRaster
          ? ', Raster: ${(f.rasterDurationMicros / 1000).toStringAsFixed(2)}ms'
          : '';
      sb.writeln(
          '  Frame ${f.frameNumber}: ${(f.workDurationMicros / 1000).toStringAsFixed(2)}ms work'
          ' (Build: ${(f.uiDurationMicros / 1000).toStringAsFixed(2)}ms$r)');
    }

    return sb.toString();
  }

  String _severity(int janky, int total) {
    final pct = janky / total;
    if (pct < 0.05) return 'GOOD';
    if (pct < 0.15) return 'MINOR';
    if (pct < 0.30) return 'MODERATE';
    return 'SEVERE';
  }
}

class _RawFrame {
  final int start;
  final int duration;
  _RawFrame(this.start, this.duration);
}
