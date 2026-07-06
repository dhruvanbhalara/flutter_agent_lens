import 'package:dart_mcp/server.dart';

/// Extension on [CallToolRequest] to retrieve arguments defensively.
extension CallToolRequestX on CallToolRequest {
  /// Safely extracts an argument value of type [T] by [key].
  ///
  /// Returns `null` if the arguments map is missing, the key does not exist,
  /// or the value is not of type [T].
  T? arg<T>(String key) {
    final args = arguments;
    if (args == null) return null;
    final val = args[key];
    if (val is T) return val;
    return null;
  }

  /// Safely extracts an argument value of type [T] by [key].
  ///
  /// Throws an [ArgumentError] if the arguments map is missing, the key does
  /// not exist, or the value is not of type [T].
  T requireArg<T>(String key) {
    final args = arguments;
    if (args == null) {
      throw ArgumentError('Missing required arguments map.');
    }
    if (!args.containsKey(key)) {
      throw ArgumentError('Missing required argument: $key');
    }
    final val = args[key];
    if (val is! T) {
      throw ArgumentError(
          'Argument "$key" is not of type $T (got: ${val.runtimeType})');
    }
    return val;
  }
}
