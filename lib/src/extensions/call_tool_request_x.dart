import 'package:dart_mcp/server.dart';
import 'package:flutter_agent_lens/src/constants/mcp_limits.dart';

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

  /// Returns whether the caller requested complete untruncated output.
  bool get isFull => arg<bool>('full') ?? false;

  /// Returns the requested limit clamped to [1, max], or null if [isFull] is true.
  int? limitArg({int defaultValue = 20, int max = 200}) {
    if (isFull) return null;
    final val = intArg('limit') ?? defaultValue;
    return val.clamp(1, max);
  }

  /// Returns the effective limit as a non-nullable integer for VM Service calls
  /// that require a concrete limit parameter.
  ///
  /// If [isFull] is true, returns [fullLimit].
  /// Otherwise returns the requested limit clamped to [1, max], defaulting to [defaultValue].
  int effectiveLimitArg({
    int defaultValue = McpLimits.defaultListLimit,
    int max = 200,
    int fullLimit = McpLimits.fullInstancesLimit,
  }) {
    if (isFull) return fullLimit;
    final val = intArg('limit') ?? defaultValue;
    return val.clamp(1, max);
  }

  /// Takes up to [limitArg()] items from [iterable] unless [isFull] is true.
  Iterable<T> applyLimit<T>(
    Iterable<T> iterable, {
    int defaultValue = McpLimits.defaultListLimit,
    int max = 200,
  }) {
    if (isFull) return iterable;
    final limit = limitArg(defaultValue: defaultValue, max: max);
    return limit != null ? iterable.take(limit) : iterable;
  }

  /// Returns the requested body length clamped to [500, max], or null if [isFull] is true.
  int? maxBodyLengthArg({int defaultValue = 5000, int max = 50000}) {
    if (isFull) return null;
    final val = intArg('max_body_length') ?? defaultValue;
    return val.clamp(500, max);
  }
}
