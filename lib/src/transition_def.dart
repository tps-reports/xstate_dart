/// One transition option: optional target path, optional guard name,
/// zero or more action names. Parsed from a string, map, or list form.
class TransitionDef {
  final String? target;
  final String? guard;
  final List<String> actions;

  const TransitionDef({this.target, this.guard, this.actions = const []});

  /// Parse a "names" field: a JSON value that is absent (`null`), a single
  /// action/entry/exit name (`String`), or a list of names (`List`). Used
  /// for transition `actions` here and, identically, for state `entry`/
  /// `exit` in [StateNode] — one shared parser so both fail the same way.
  /// Throws [FormatException] for any other shape (e.g. a bare number):
  /// malformed input must fail loudly at parse time, not silently resolve
  /// to an empty action list that then quietly does nothing at runtime.
  static List<String> parseNames(dynamic raw) => switch (raw) {
        null => const [],
        String s => [s],
        List l => l.cast<String>(),
        _ => throw FormatException('Bad name list: $raw'),
      };

  /// A transition value may be "target", {target, guard, actions}, or a
  /// list of those (guarded alternatives, first match wins).
  static List<TransitionDef> parseList(dynamic raw) {
    if (raw == null) return const [];
    if (raw is List) {
      return raw.expand(parseList).toList();
    }
    if (raw is String) return [TransitionDef(target: raw)];
    if (raw is Map) {
      return [
        TransitionDef(
          target: raw['target'] as String?,
          guard: raw['guard'] as String?,
          actions: parseNames(raw['actions']),
        )
      ];
    }
    throw FormatException('Bad transition: $raw');
  }
}
