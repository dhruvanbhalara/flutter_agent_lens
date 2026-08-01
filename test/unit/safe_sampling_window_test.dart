import 'dart:async';

import 'package:flutter_agent_lens/src/utils/safe_sampling_window.dart';
import 'package:test/fake.dart';
import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart';

class _FakeVmServiceForWindow extends Fake implements VmService {
  final Completer<void> _onDoneCompleter = Completer<void>();

  @override
  Future<void> get onDone => _onDoneCompleter.future;

  void triggerDisconnect() {
    if (!_onDoneCompleter.isCompleted) {
      _onDoneCompleter.complete();
    }
  }
}

void main() {
  group('safeSamplingWindow', () {
    late _FakeVmServiceForWindow fakeVmService;

    setUp(() {
      fakeVmService = _FakeVmServiceForWindow();
    });

    test('completes normally when no disconnect occurs', () async {
      final result = await safeSamplingWindow(
        vmService: fakeVmService,
        duration: const Duration(milliseconds: 50),
      );

      expect(result.completed, isTrue);
      expect(result.interruptReason, isNull);
      expect(result.elapsed.inMilliseconds, greaterThanOrEqualTo(40));
    });

    test('terminates early when VM service disconnects mid-sampling', () async {
      final future = safeSamplingWindow(
        vmService: fakeVmService,
        duration: const Duration(seconds: 5),
      );

      // Trigger early disconnect after 20ms
      await Future<void>.delayed(const Duration(milliseconds: 20));
      fakeVmService.triggerDisconnect();

      final result = await future;

      expect(result.completed, isFalse);
      expect(result.interruptReason, equals('vm_service_disconnected'));
      expect(result.elapsed.inSeconds, lessThan(5));
    });
  });
}
