/// Truncates the given [value] to [maxLength], appending a truncation notice if needed.
String truncateString(String value, {int maxLength = 10000}) {
  if (value.length <= maxLength) return value;
  return '${value.substring(0, maxLength)}\n... [TRUNCATED - ${value.length - maxLength} characters omitted]';
}
