/// Centralized constants for token optimization, query limits, and payload ceilings across MCP tools.
abstract final class McpLimits {
  /// Default limits for collections and queries
  static const int defaultListLimit = 20;

  /// Default limit for console logs.
  static const int defaultConsoleLogsLimit = 50;

  /// Default limit for memory instance tracking.
  static const int defaultMemoryInstancesLimit = 100;

  /// Default limit for retaining path elements.
  static const int defaultRetainingPathLimit = 15;

  /// Default limit for performance profiling events.
  static const int defaultProfilingLimit = 15;

  /// Default limit for network requests tracking.
  static const int defaultNetworkRequestsLimit = 30;

  /// Default limit for bundle size listings.
  static const int defaultBundleSizeLimit = 25;

  /// Default limit for top classes output.
  static const int defaultTopNClasses = 10;

  /// High / uncapped ceilings when `full: true` is passed for VM Service RPCs that require a concrete integer
  static const int fullInstancesLimit = 10000;

  /// Full limit for retaining paths.
  static const int fullRetainingPathLimit = 1000;

  /// Full limit for standard list queries.
  static const int fullListMax = 50000;

  /// Maximum clamp ceilings for standard queries
  static const int maxConsoleLogsLimit = 500;

  /// Maximum clamp limit for memory instances.
  static const int maxMemoryInstancesLimit = 500;

  /// Maximum clamp limit for retaining paths.
  static const int maxRetainingPathLimit = 100;

  /// Maximum clamp limit for standard profiling lists.
  static const int maxProfilingLimit = 100;

  /// Maximum clamp limit for standard network captures.
  static const int maxNetworkRequestsLimit = 200;

  /// Payload text length limits
  static const int defaultMaxTextLength = 5000;

  /// Payload max body length limits.
  static const int defaultMaxBodyLength = 5000;

  /// Payload ultimate ceiling.
  static const int maxBodyLengthCeiling = 50000;

  /// Payload max length when full.
  static const int fullMaxTextLength = 50000;
}
