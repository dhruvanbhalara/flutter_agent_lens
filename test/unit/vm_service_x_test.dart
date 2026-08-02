import 'package:flutter_agent_lens/src/extensions/vm_service_x.dart';
import 'package:test/fake.dart';
import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart';

class _FakeVmServiceForTest extends Fake implements VmService {
  String? lastExtensionCalled;
  Map<String, dynamic>? lastArgs;
  bool shouldThrowSentinel = false;
  bool shouldThrowRPCError = false;

  @override
  Future<Response> callServiceExtension(
    String method, {
    String? isolateId,
    Map<String, dynamic>? args,
  }) async {
    if (shouldThrowRPCError) {
      throw RPCError('callServiceExtension', -32601, 'Method not found');
    }
    lastExtensionCalled = method;
    lastArgs = args;
    return Response.parse({'type': 'Success'})!;
  }

  @override
  Future<Response> evaluate(
    String isolateId,
    String targetId,
    String expression, {
    bool? disableBreakpoints,
    String? idZoneId,
    Map<String, String>? scope,
  }) async {
    if (shouldThrowSentinel) {
      throw RPCError('evaluate', 106, 'Object collected');
    }
    return InstanceRef(
      id: 'ref1',
      kind: InstanceKind.kString,
      valueAsString: 'success',
    );
  }
}

void main() {
  group('VmServiceX', () {
    late _FakeVmServiceForTest fakeVmService;

    setUp(() {
      fakeVmService = _FakeVmServiceForTest();
    });

    test('toggleFlutterExtension sends correct args', () async {
      await fakeVmService.toggleFlutterExtension('debugPaint', enabled: true);
      expect(
        fakeVmService.lastExtensionCalled,
        equals('ext.flutter.debugPaint'),
      );
      expect(fakeVmService.lastArgs, equals({'enabled': 'true'}));

      await fakeVmService.toggleFlutterExtension('debugPaint', enabled: false);
      expect(fakeVmService.lastArgs, equals({'enabled': 'false'}));
    });

    test('safeToggleFlutterExtension handles success and RPC errors', () async {
      final success = await fakeVmService.safeToggleFlutterExtension(
        'debugPaint',
        enabled: true,
      );
      expect(success, isTrue);

      fakeVmService.shouldThrowRPCError = true;
      final failure = await fakeVmService.safeToggleFlutterExtension(
        'debugPaint',
        enabled: false,
      );
      expect(failure, isFalse);
    });

    test('evalSafe returns result on success and null on error', () async {
      final res = await fakeVmService.evalSafe('iso1', 'lib1', '1 + 1');
      expect(res, isNotNull);

      fakeVmService.shouldThrowSentinel = true;
      final nullRes = await fakeVmService.evalSafe('iso1', 'lib1', '1 + 1');
      expect(nullRes, isNull);
    });
  });
}
