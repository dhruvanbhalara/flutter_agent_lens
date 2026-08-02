import 'package:flutter_agent_lens/src/services/service_extension_registry.dart';
import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart';

import '../helpers/test_mocks.dart';

void main() {
  group('ServiceExtensionRegistry Tests', () {
    late ServiceExtensionRegistry registry;
    late FakeVmService fakeVmService;

    setUp(() {
      registry = ServiceExtensionRegistry();
      fakeVmService = FakeVmService();
    });

    tearDown(() async {
      await registry.dispose();
    });

    test('initializes extensions from isolate', () async {
      final mockIsolate = Isolate(
        id: 'isolate-1',
        number: '1',
        name: 'main',
        startTime: 0,
        runnable: true,
        livePorts: 1,
        pauseOnExit: false,
        extensionRPCs: [
          'ext.flutter.getDisplayRefreshRate',
          'ext.flutter.debugPaint',
        ],
      );

      await registry.initialize(mockIsolate, fakeVmService);

      expect(registry.isSupported('ext.flutter.getDisplayRefreshRate'), isTrue);
      expect(registry.isSupported('ext.flutter.debugPaint'), isTrue);
      expect(
          registry
              .isSupported('ext.ui.window.getSkiaEstimateRasterCacheMemory'),
          isFalse);
    });

    test('returns default FPS when extension is unsupported', () async {
      final fps = await registry.getDisplayRefreshRate(
        vmService: fakeVmService,
        isolateId: 'isolate-1',
      );

      expect(fps, equals(60.0));
    });

    test('returns null for raster cache memory when unsupported (Impeller)',
        () async {
      final rasterBytes = await registry.getRasterCacheMemory(
        vmService: fakeVmService,
        isolateId: 'isolate-1',
      );

      expect(rasterBytes, isNull);
    });
  });
}
