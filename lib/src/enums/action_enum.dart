/// Contract for action enums that map to wire-format string values.
abstract interface class ActionEnum {
  /// The raw string identifier sent over the wire.
  String get value;
}
