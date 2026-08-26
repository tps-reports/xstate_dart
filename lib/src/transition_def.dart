/// One transition option: optional target path, optional guard name,
/// zero or more action names. Parsed from a string, map, or list form.
class TransitionDef {
  final String? target;
  final String? guard;
  final List<String> actions;

  const TransitionDef({this.target, this.guard, this.actions = const []});

  static List<String> _names(dynamic raw) => switch (raw) {
        null => const [],
        String s => [s],
        List l => l.cast<String>(),
        _ => throw FormatException('Bad action list: $raw'),
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
          actions: _names(raw['actions']),
        )
      ];
    }
    throw FormatException('Bad transition: $raw');
  }
}
