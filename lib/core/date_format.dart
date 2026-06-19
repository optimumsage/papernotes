/// Lightweight, dependency-free date formatting for note timestamps. We avoid
/// the `intl` package here to keep the build slim (matches the manual approach
/// already used in settings_screen.dart).
library;

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// Absolute date, e.g. "19 Jun 2026".
String fullDate(int epochMs) {
  final d = DateTime.fromMillisecondsSinceEpoch(epochMs);
  return '${d.day} ${_months[d.month - 1]} ${d.year}';
}

/// Relative time suitable for "Edited …" labels:
/// "just now" / "5m ago" / "3h ago" / "2 days ago" / "19 Jun 2026".
String relativeTime(int epochMs, {DateTime? now}) {
  final then = DateTime.fromMillisecondsSinceEpoch(epochMs);
  final diff = (now ?? DateTime.now()).difference(then);
  if (diff.isNegative) return 'just now';
  if (diff.inMinutes < 1) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  if (diff.inDays < 7) {
    return diff.inDays == 1 ? 'yesterday' : '${diff.inDays} days ago';
  }
  return fullDate(epochMs);
}
