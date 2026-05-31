import 'package:vm_service/vm_service.dart';

class CpuAnalyzer {
  String generateHotspotReport(CpuSamples samples, {int topN = 10}) {
    final total = (samples.sampleCount ?? 0) < 1 ? 1 : samples.sampleCount!;
    final functions = samples.functions ?? [];

    final sorted = [
      ...functions
    ]..sort((a, b) => (b.exclusiveTicks ?? 0).compareTo(a.exclusiveTicks ?? 0));

    // Filter: keep only Dart user code
    // Dart source files have resolvedUrl like "package:foo/bar.dart" or "file:///...dart"
    // Native frames on Android have resolvedUrl like "/data/app/.../libflutter.so+0x..."
    // Native frames on iOS have empty resolvedUrl or native lib paths
    final user = sorted
        .where((f) {
          final url = f.resolvedUrl ?? '';
          final name = _formatName(f);
          // Bracket notation = VM internal/native regardless of URL
          if (name.startsWith('[')) return false;
          // Must have a Dart source URL
          if (url.isEmpty) return false;
          if (!url.endsWith('.dart'))
            return false; // .so, .dylib, empty = not Dart
          // Skip SDK internals
          if (url.startsWith('dart:')) return false;
          if (url.startsWith('org-dartlang-sdk:'))
            return false; // AOT compiled SDK
          if (url.contains('org-dartlang-sdk')) return false;
          // Skip Flutter framework (keep app code)
          if (url.contains('packages/flutter/')) return false;
          if (url.contains('pub.dartlang.org')) return false;
          // Only keep app package code
          if (!url.contains('package:') && !url.startsWith('file:'))
            return false;
          return true;
        })
        .take(topN)
        .toList();

    final windowSec =
        ((samples.timeExtentMicros ?? 0) / 1e6).toStringAsFixed(1);
    final sb = StringBuffer();
    sb.writeln('CPU Hotspots (${windowSec}s window, $total samples)');
    sb.writeln('━' * 60);
    sb.writeln(
        '${'Rank'.padRight(6)}${'Self%'.padRight(8)}${'Total%'.padRight(9)}Function');

    for (int i = 0; i < user.length; i++) {
      final f = user[i];
      final selfPct =
          ((f.exclusiveTicks ?? 0) / total * 100).toStringAsFixed(1).padLeft(5);
      final totalPct =
          ((f.inclusiveTicks ?? 0) / total * 100).toStringAsFixed(1).padLeft(6);
      final name = _formatName(f);
      sb.writeln(
          '  ${(i + 1).toString().padLeft(2)}.  $selfPct%  $totalPct%  $name');
    }

    sb.writeln('');
    sb.writeln(_advice(user, total));
    return sb.toString();
  }

  String _formatName(ProfileFunction f) {
    final fn = f.function;
    if (fn == null) return 'unknown';

    // vm_service returns function as dynamic — may be typed obj or raw Map
    if (fn is Map) {
      final name = fn['name'] as String? ?? 'unknown';
      final owner = fn['owner'];
      final ownerName = owner is Map ? owner['name'] as String? : null;
      if (ownerName != null && ownerName.isNotEmpty) return '$ownerName.$name';
      return name;
    }

    // Typed FuncRef / ObjRef path
    try {
      final ownerName = (fn as dynamic).owner?.name as String?;
      final fnName = (fn as dynamic).name as String? ?? 'unknown';
      if (ownerName != null && ownerName.isNotEmpty)
        return '$ownerName.$fnName';
      return fnName;
    } catch (_) {
      return fn.toString();
    }
  }

  String _advice(List<ProfileFunction> hot, int total) {
    final lines = <String>[];
    for (final f in hot.take(5)) {
      final selfPct = (f.exclusiveTicks ?? 0) / total * 100;
      final totalPct = (f.inclusiveTicks ?? 0) / total * 100;
      final name = _formatName(f);
      final nameLower = name.toLowerCase();

      if (selfPct > 10 && nameLower.contains('build')) {
        lines.add(
            '• $name: ${selfPct.toStringAsFixed(1)}% self in build(). Move expensive work outside or cache results.');
      } else if (selfPct > 10 &&
          (nameLower.contains('decode') || nameLower.contains('image'))) {
        lines.add(
            '• $name: ${selfPct.toStringAsFixed(1)}% — image/decode cost. Use compute() to offload to isolate.');
      } else if (selfPct > 5) {
        lines.add(
            '• $name: ${selfPct.toStringAsFixed(1)}% self-time — algorithmic bottleneck.');
      } else if (totalPct > 10 && selfPct < 2) {
        // High inclusive but low exclusive = expensive call chain passing through this fn
        lines.add(
            '• $name: ${totalPct.toStringAsFixed(1)}% total (${selfPct.toStringAsFixed(1)}% self) — expensive call chain. Check callees.');
      }
    }
    return lines.isEmpty
        ? 'No obvious CPU hotspots. App CPU usage looks healthy.'
        : 'Suggestions:\n${lines.join('\n')}';
  }
}
