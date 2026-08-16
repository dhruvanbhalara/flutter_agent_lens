import 'package:flutter_agent_lens/src/enums/action_enum.dart';

/// Actions supported by the connection tool.
enum ConnectionAction implements ActionEnum {
  /// Connect to VM Service or DTD.
  connect('connect'),

  /// Connect to Dart Tooling Daemon specifically.
  connectDtd('connectDtd'),

  /// Disconnect active VM Service and DTD connections.
  disconnect('disconnect');

  const ConnectionAction(this.value);

  @override
  final String value;

  static final Map<String, ConnectionAction> _lookup = {
    for (final e in ConnectionAction.values) e.value.toLowerCase(): e,
  };

  /// Resolves the action from a raw string.
  /// Returns `null` if the action is null or unsupported.
  static ConnectionAction? fromString(String? val) {
    if (val == null) return null;
    return _lookup[val.toLowerCase()];
  }
}
