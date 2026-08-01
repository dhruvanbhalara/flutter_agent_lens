import 'package:flutter_agent_lens/src/services/log_stream_broadcaster.dart';
import 'package:test/test.dart';

void main() {
  group('LogStreamBroadcaster Unit Tests', () {
    late LogStreamBroadcaster broadcaster;

    setUp(() {
      broadcaster = LogStreamBroadcaster();
    });

    test('supports multi-listener dispatch without listener collisions', () {
      final listener1Logs = <String>[];
      final listener2Logs = <String>[];

      final unsub1 = broadcaster.addListener(listener1Logs.add);
      final unsub2 = broadcaster.addListener(listener2Logs.add);

      expect(broadcaster.hasListeners, isTrue);

      broadcaster.dispatch('[STDOUT] line 1');
      broadcaster.dispatch('[STDERR] error 1');

      expect(listener1Logs, equals(['[STDOUT] line 1', '[STDERR] error 1']));
      expect(listener2Logs, equals(['[STDOUT] line 1', '[STDERR] error 1']));

      unsub1();
      broadcaster.dispatch('[STDOUT] line 2');

      expect(listener1Logs.length, equals(2));
      expect(
          listener2Logs,
          equals([
            '[STDOUT] line 1',
            '[STDERR] error 1',
            '[STDOUT] line 2',
          ]));

      unsub2();
      expect(broadcaster.hasListeners, isFalse);
    });

    test('handles listener exceptions gracefully without stopping dispatch',
        () {
      final validLogs = <String>[];

      broadcaster.addListener((line) {
        throw Exception('Boom in listener');
      });
      broadcaster.addListener(validLogs.add);

      expect(
        () => broadcaster.dispatch('[STDOUT] resilient line'),
        returnsNormally,
      );

      expect(validLogs, equals(['[STDOUT] resilient line']));
    });
  });
}
