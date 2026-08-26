import 'transition_def.dart';

/// Immutable node in the statechart tree, identified by its dot path.
class StateNode {
  final String key; // local name
  final String path; // dot-joined from root ('' for root)
  final String? initial;
  final bool isParallel;
  final bool isHistory;
  final List<String> entryActions;
  final List<String> exitActions;
  final Map<String, List<TransitionDef>> on;
  final List<TransitionDef> always;
  final Map<int, List<TransitionDef>> after; // ms -> transitions
  final Map<String, StateNode> children;
  final StateNode? parent;

  StateNode._({
    required this.key,
    required this.path,
    required this.initial,
    required this.isParallel,
    required this.isHistory,
    required this.entryActions,
    required this.exitActions,
    required this.on,
    required this.always,
    required this.after,
    required this.children,
    required this.parent,
  });

  factory StateNode.parse(String key, Map<String, dynamic> cfg,
      {StateNode? parent}) {
    final path = parent == null || parent.path.isEmpty
        ? key
        : '${parent.path}.$key';
    final on = <String, List<TransitionDef>>{};
    (cfg['on'] as Map<String, dynamic>? ?? const {}).forEach(
        (event, raw) => on[event] = TransitionDef.parseList(raw));
    final after = <int, List<TransitionDef>>{};
    (cfg['after'] as Map<String, dynamic>? ?? const {}).forEach((ms, raw) {
      final parsedMs = int.tryParse(ms);
      if (parsedMs == null) {
        throw FormatException(
            'State "$path" has a non-numeric "after" key: "$ms" '
            '(after keys must be millisecond durations, e.g. "50")');
      }
      after[parsedMs] = TransitionDef.parseList(raw);
    });
    final node = StateNode._(
      key: key,
      path: path,
      initial: cfg['initial'] as String?,
      isParallel: cfg['type'] == 'parallel',
      isHistory: cfg['history'] == true,
      entryActions: _plainNames(cfg['entry']),
      exitActions: _plainNames(cfg['exit']),
      on: on,
      always: TransitionDef.parseList(cfg['always']),
      after: after,
      children: {},
      parent: parent,
    );
    (cfg['states'] as Map<String, dynamic>? ?? const {}).forEach((k, v) {
      node.children[k] =
          StateNode.parse(k, v as Map<String, dynamic>, parent: node);
    });
    return node;
  }

  static List<String> _plainNames(dynamic raw) => switch (raw) {
        null => const [],
        String s => [s],
        List l => l.cast<String>(),
        _ => const [],
      };

  bool get isLeaf => children.isEmpty;
}
