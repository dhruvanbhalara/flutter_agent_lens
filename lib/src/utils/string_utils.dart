/// Truncates the given [value] to [maxLength], appending a truncation notice if needed.
String truncateString(String value, {int maxLength = 10000}) {
  if (value.length <= maxLength) return value;
  return '${value.substring(0, maxLength)}\n... [TRUNCATED - ${value.length - maxLength} characters omitted]';
}

/// Formats [bytes] as a human-readable string (e.g. `1.23 MB`).
///
/// Handles negative values and zero. Precision is fixed at two decimal places.
String formatBytes(int bytes) {
  if (bytes == 0) return '0 B';
  final sign = bytes < 0 ? '-' : '';
  var absVal = bytes.abs().toDouble();
  final units = ['B', 'KB', 'MB', 'GB'];
  var i = 0;
  while (absVal >= 1024.0 && i < units.length - 1) {
    absVal /= 1024.0;
    i++;
  }
  return '$sign${absVal.toStringAsFixed(2)} ${units[i]}';
}
