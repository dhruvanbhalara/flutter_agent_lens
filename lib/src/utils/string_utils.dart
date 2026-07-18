/// Truncates the given [value] to [maxLength], appending a truncation notice if needed.
String truncateString(String value, {int maxLength = 10000}) {
  if (value.length <= maxLength) return value;
  return '${value.substring(0, maxLength)}\n... [TRUNCATED - ${value.length - maxLength} characters omitted]';
}

/// Formats the map as a structured string up to [maxDepth] to optimize token size.
String formatMapString(Map<dynamic, dynamic> data, {int maxDepth = 3}) {
  final buffer = StringBuffer();
  _formatMapHelper(data, buffer, 0, maxDepth);
  return buffer.toString();
}

void _formatMapHelper(
    Map<dynamic, dynamic> data, StringBuffer buffer, int indent, int maxDepth) {
  if (indent > maxDepth) {
    buffer.write('{...}');
    return;
  }
  final pad = '  ' * indent;
  buffer.writeln('{');
  var isFirst = true;
  data.forEach((key, value) {
    if (!isFirst) {
      buffer.writeln(',');
    }
    isFirst = false;
    buffer.write('$pad  "$key": ');
    if (value is Map) {
      _formatMapHelper(value, buffer, indent + 1, maxDepth);
    } else if (value is List) {
      if (value.length > 10) {
        buffer.write('[${value.first}, ... (${value.length - 1} more items)]');
      } else {
        buffer.write(value.toString());
      }
    } else {
      buffer.write('"$value"');
    }
  });
  buffer.writeln();
  buffer.write('$pad}');
}
