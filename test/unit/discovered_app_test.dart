import 'package:flutter_agent_lens/src/port_discovery.dart';
import 'package:test/test.dart';

void main() {
  group('DiscoveredApp Tests', () {
    test('value equality and hashCode', () {
      const app1 = DiscoveredApp(
        serviceUri: 'ws://127.0.0.1:8181/auth/ws',
        projectName: 'my_project',
        configPath: '/path/to/config',
      );
      const app2 = DiscoveredApp(
        serviceUri: 'ws://127.0.0.1:8181/auth/ws',
        projectName: 'my_project',
        configPath: '/path/to/config',
      );
      const app3 = DiscoveredApp(
        serviceUri: 'ws://127.0.0.1:8181/auth/ws',
        projectName: 'different_project',
        configPath: '/path/to/config',
      );

      expect(app1, equals(app2));
      expect(app1.hashCode, equals(app2.hashCode));
      expect(app1, isNot(equals(app3)));
      expect(app1.hashCode, isNot(equals(app3.hashCode)));
    });

    test('toString representation', () {
      const app = DiscoveredApp(
        serviceUri: 'ws://127.0.0.1:8181/auth/ws',
        projectName: 'my_project',
        configPath: '/path/to/config',
      );
      expect(app.toString(), contains('my_project'));
      expect(app.toString(), contains('ws://127.0.0.1:8181/auth/ws'));
    });
  });
}
