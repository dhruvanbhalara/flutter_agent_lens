/// Utility function to format byte counts into human-readable strings.
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
