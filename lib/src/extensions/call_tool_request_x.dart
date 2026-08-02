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

  /// Safely extracts a numeric argument by [key] and converts it to an [int].
  ///
  /// Returns [defaultValue] if the argument is missing or not a [num].
  int? intArg(String key, {int? defaultValue}) {
    final value = arg<num>(key);
    return value?.toInt() ?? defaultValue;
  }

  /// Safely extracts a numeric argument by [key] and converts it to a [double].
  ///
  /// Returns [defaultValue] if the argument is missing or not a [num].
  double? doubleArg(String key, {double? defaultValue}) {
    final value = arg<num>(key);
    return value?.toDouble() ?? defaultValue;
  }

  /// Safely extracts a [String] argument by [key].
  ///
  /// Returns `null` if the argument is missing or not a [String].
  String? strArg(String key) => arg<String>(key);

  /// Extracts a required [String] argument by [key].
  ///
  /// Throws an [ArgumentError] if the key is missing or the value is not a [String].
  String requireStrArg(String key) => requireArg<String>(key);
}
