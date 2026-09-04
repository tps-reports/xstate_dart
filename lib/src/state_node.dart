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
  final StateNode? parent;

  /// Mutable only during [StateNode.parse]'s own construction of this node's
  /// children (see there); never written to afterward.
  final Map<String, StateNode> _childrenMutable = {};

  /// This node's children, keyed by local name. Unmodifiable: by the time
  /// [StateNode.parse] returns for this node (and, transitively, every node
  /// in the tree — parsing is bottom-up, so a node's children are always
  /// fully parsed and attached before its own `parse` call returns), no
  /// further writes happen, and this lazily-computed view is cached forever
  /// on first read — so no caller can accidentally mutate the parsed tree.
  late final Map<String, StateNode> children = Map.unmodifiable(
    _childrenMutable,
  );

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
    required this.parent,
  });

  factory StateNode.parse(
    String key,
    Map<String, dynamic> cfg, {
    StateNode? parent,
  }) {
    final path = parent == null || parent.path.isEmpty
        ? key
        : '${parent.path}.$key';
    if (parent == null && cfg['after'] != null) {
      // The root is never a member of its own `activeStates` (that set is
      // built from active *leaves* and their ancestor prefixes, and the
      // root's own path is the empty string, never added — see
      // `StateMachine._expandToAncestorClosure`), so `tick` never visits it
      // and a root-level `after` timer would never advance or fire. Rather
      // than silently accepting a chart clause that can never do anything,
      // reject it at parse time.
      throw FormatException('after on the root is not supported');
    }
    final on = <String, List<TransitionDef>>{};
    (cfg['on'] as Map<String, dynamic>? ?? const {}).forEach(
      (event, raw) => on[event] = TransitionDef.parseList(raw),
    );
    final after = <int, List<TransitionDef>>{};
    (cfg['after'] as Map<String, dynamic>? ?? const {}).forEach((ms, raw) {
      final parsedMs = int.tryParse(ms);
      if (parsedMs == null) {
        throw FormatException(
          'State "$path" has a non-numeric "after" key: "$ms" '
          '(after keys must be millisecond durations, e.g. "50")',
        );
      }
      after[parsedMs] = TransitionDef.parseList(raw);
    });
    final node = StateNode._(
      key: key,
      path: path,
      initial: cfg['initial'] as String?,
      isParallel: cfg['type'] == 'parallel',
      isHistory: cfg['history'] == true,
      entryActions: TransitionDef.parseNames(cfg['entry']),
      exitActions: TransitionDef.parseNames(cfg['exit']),
      on: on,
      always: TransitionDef.parseList(cfg['always']),
      after: after,
      parent: parent,
    );
    (cfg['states'] as Map<String, dynamic>? ?? const {}).forEach((k, v) {
      node._childrenMutable[k] = StateNode.parse(
        k,
        v as Map<String, dynamic>,
        parent: node,
      );
    });
    return node;
  }

  bool get isLeaf => children.isEmpty;
}
