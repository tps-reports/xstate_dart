// Derived from forge_ui lib/util/StateMachine.dart (fivex project).
import 'dart:convert';
import 'result.dart';
import 'state_node.dart';
import 'transition_def.dart';

typedef ActionFn = void Function(
    Map<String, dynamic> context, Map<String, dynamic> event);
typedef GuardFn = bool Function(Map<String, dynamic> context,
    Map<String, dynamic> event, bool Function(String path) isActive);

/// Hierarchical statechart interpreter.
///
/// ## Target resolution
///
/// When a transition's `on` entry names a string target (e.g. `".a2"`,
/// `"a2"`, `"b.b1.b1x"`), it is resolved relative to the *source node* — the
/// node whose `on` map actually matched the event, which may be an ancestor
/// of the currently active leaf (inner handlers win; lookup walks from the
/// active leaf upward). Resolution tries, in order, and takes the first hit:
///
/// 1. **Leading dot** (`.Child`): resolve the remainder as a child path of
///    the source node itself.
/// 2. **Sibling**: resolve the (dot-stripped) path as a child path of the
///    source node's *parent* — this is how a bare `Name` reaches a sibling
///    state, and also how a leading-dot target falls back to a sibling when
///    the source node has no matching child (e.g. an atomic leaf using
///    `.Sibling` to mean "my parent's other child").
/// 3. **Absolute**: resolve the path from the machine root (`A.B.C`).
/// 4. **Ancestor walk**: walking up each remaining ancestor of the source,
///    try resolving the path as that ancestor's child path.
///
/// If none of the four resolve to an existing node, a `StateError` is
/// thrown.
///
/// ## Entry / exit
///
/// Entering a compound state runs its entry action(s) then descends through
/// `initial` children (recursively) until an atomic leaf is reached; a
/// compound state with no `initial` throws `StateError`. Entering a
/// parallel state enters every non-history child. History children are
/// never auto-entered.
///
/// A transition exits every active descendant from the current leaf(s) up
/// to (but not including) the least common ancestor (LCA) of the
/// transition's source node and its resolved target, running exit actions
/// bottom-up, then runs the transition's own actions, then enters back down
/// from the LCA to the target (running entry actions top-down along the
/// explicit path to the target, then descending through `initial` below the
/// target if the target itself is compound).
class StateMachine {
  final StateNode root;
  final Map<String, ActionFn> _actions;
  final Map<String, GuardFn> _guards;
  final Map<String, dynamic> _context;
  final Set<String> _configuration = {}; // active leaf paths

  StateMachine._(this.root, this._actions, this._guards, this._context) {
    _enterNode(root, const {});
  }

  factory StateMachine.fromJson(String json,
      {Map<String, ActionFn> actions = const {},
      Map<String, GuardFn> guards = const {}}) {
    final cfg = jsonDecode(json) as Map<String, dynamic>;
    // Parse the root with an empty key so child paths have no root prefix
    // (children of "toggle" are addressed as "off", "on", not
    // "toggle.off").
    final root = StateNode.parse('', cfg);
    final context =
        Map<String, dynamic>.from(cfg['context'] as Map? ?? const {});
    return StateMachine._(root, actions, guards, context);
  }

  Map<String, dynamic> get context => Map.unmodifiable(_context);

  Set<String> get activeStates {
    final all = <String>{};
    for (final leaf in _configuration) {
      final parts = leaf.split('.');
      for (var i = 1; i <= parts.length; i++) {
        all.add(parts.sublist(0, i).join('.'));
      }
    }
    return all;
  }

  bool matches(String path) => activeStates.contains(path);

  bool _isActive(String path) => matches(path);

  StateTransitionResult send(String event, [Map<String, dynamic>? payload]) {
    final eventData = {'type': event, ...?payload};
    final before = Set<String>.from(_configuration);
    var changed = false;

    for (final leafPath in before) {
      // A prior iteration in this same send() may already have exited this
      // leaf (e.g. it was a descendant of an already-transitioned domain).
      if (!_configuration.contains(leafPath)) continue;

      final leaf = _nodeAt(leafPath);

      // Event lookup walks from the leaf upward through ancestors (inner
      // handlers win) until a node handles the event.
      StateNode? source = leaf;
      TransitionDef? chosen;
      while (source != null) {
        final defs = source.on[event] ?? const [];
        chosen = _firstEnabled(defs, eventData);
        if (chosen != null) break;
        source = source.parent;
      }
      if (source == null || chosen == null) continue;

      if (chosen.target == null) {
        // Internal transition: run actions only, no state change.
        _runActions(chosen.actions, eventData);
        continue;
      }

      final target = _resolveTarget(source, chosen.target!);
      final lca = _lca(source, target);
      final exitDomain = _childTowards(leaf, lca);

      _exitNode(exitDomain, eventData);
      _runActions(chosen.actions, eventData);
      _enterChain(_chainDownTo(target, lca), eventData);
      changed = true;
    }

    return StateTransitionResult(
      activeStates: activeStates,
      changed: changed,
      previousStates: before,
    );
  }

  TransitionDef? _firstEnabled(
      List<TransitionDef> defs, Map<String, dynamic> eventData) {
    for (final def in defs) {
      final guardName = def.guard;
      if (guardName == null) return def;
      final guard = _guards[guardName];
      if (guard == null) {
        throw StateError('Unknown guard: $guardName');
      }
      if (guard(_context, eventData, _isActive)) return def;
    }
    return null;
  }

  StateNode _nodeAt(String path) {
    if (path.isEmpty) return root;
    var node = root;
    for (final part in path.split('.')) {
      node = node.children[part]!;
    }
    return node;
  }

  void _runActions(List<String> names, Map<String, dynamic> eventData) {
    for (final name in names) {
      final fn = _actions[name];
      if (fn == null) throw StateError('Unknown action: $name');
      fn(_context, eventData);
    }
  }

  // --- Entry / exit -------------------------------------------------------

  /// Enter `node`: run its entry action(s), then descend — parallel: enter
  /// all non-history children; compound: enter the `initial` child (throw
  /// if missing); atomic: add `node.path` to the active configuration.
  void _enterNode(StateNode node, Map<String, dynamic> eventData) {
    _runActions(node.entryActions, eventData);
    _descendAfterEntry(node, eventData);
  }

  void _descendAfterEntry(StateNode node, Map<String, dynamic> eventData) {
    if (node.isParallel) {
      for (final child in node.children.values) {
        if (!child.isHistory) _enterNode(child, eventData);
      }
    } else if (node.children.isNotEmpty) {
      final init = node.initial;
      if (init == null) {
        throw StateError('Compound state ${node.path} has no initial');
      }
      _enterNode(node.children[init]!, eventData);
    } else {
      _configuration.add(node.path);
    }
  }

  /// Exit every active descendant of `node` (bottom-up), then `node` itself.
  void _exitNode(StateNode node, Map<String, dynamic> eventData) {
    final activeLeaves = _configuration
        .where((p) => p == node.path || p.startsWith('${node.path}.'))
        .toList();
    for (final leafPath in activeLeaves) {
      var n = _nodeAt(leafPath);
      while (true) {
        _runActions(n.exitActions, eventData);
        if (identical(n, node)) break;
        n = n.parent!;
      }
      _configuration.remove(leafPath);
    }
  }

  /// Enter each node in `chain` (root-to-target order) in turn: run its
  /// entry action(s); for the final node (the actual target), continue
  /// descending through `initial` as usual; for intermediate parallel
  /// nodes, also fully enter sibling regions not on the continuing path.
  void _enterChain(List<StateNode> chain, Map<String, dynamic> eventData) {
    for (var i = 0; i < chain.length; i++) {
      final node = chain[i];
      _runActions(node.entryActions, eventData);
      final isLast = i == chain.length - 1;
      if (isLast) {
        _descendAfterEntry(node, eventData);
      } else if (node.isParallel) {
        final nextInChain = chain[i + 1];
        for (final child in node.children.values) {
          if (!identical(child, nextInChain) && !child.isHistory) {
            _enterNode(child, eventData);
          }
        }
      }
    }
  }

  // --- Tree geometry helpers -----------------------------------------------

  /// Least common ancestor of `a` and `b` (always exists; root is an
  /// ancestor of every node).
  StateNode _lca(StateNode a, StateNode b) {
    final ancestorsOfA = <StateNode>{};
    var n = a;
    while (true) {
      ancestorsOfA.add(n);
      if (n.parent == null) break;
      n = n.parent!;
    }
    var m = b;
    while (!ancestorsOfA.contains(m)) {
      m = m.parent!;
    }
    return m;
  }

  /// The node on the path from `ancestor` down to `descendant` that is a
  /// direct child of `ancestor` (i.e. `ancestor`'s child on `descendant`'s
  /// side).
  StateNode _childTowards(StateNode descendant, StateNode ancestor) {
    if (identical(descendant, ancestor)) return descendant;
    var n = descendant;
    while (!identical(n.parent, ancestor)) {
      n = n.parent!;
    }
    return n;
  }

  /// The chain of nodes from (but not including) `ancestorExclusive` down
  /// to (and including) `target`, in root-to-target order.
  List<StateNode> _chainDownTo(StateNode target, StateNode ancestorExclusive) {
    final chain = <StateNode>[];
    var n = target;
    while (!identical(n, ancestorExclusive)) {
      chain.add(n);
      n = n.parent!;
    }
    return chain.reversed.toList();
  }

  // --- Target resolution ----------------------------------------------------

  StateNode? _tryResolvePath(StateNode base, List<String> segments) {
    var n = base;
    for (final seg in segments) {
      final next = n.children[seg];
      if (next == null) return null;
      n = next;
    }
    return n;
  }

  /// Resolve a transition target string against `source` per the 4-step
  /// rule documented on this class.
  StateNode _resolveTarget(StateNode source, String targetStr) {
    final strippedSegments = (targetStr.startsWith('.')
            ? targetStr.substring(1)
            : targetStr)
        .split('.');

    // Step 1: leading dot -> child path of the source node itself.
    if (targetStr.startsWith('.')) {
      final hit = _tryResolvePath(source, strippedSegments);
      if (hit != null) return hit;
    }

    // Step 2: sibling -> child path of the source's parent.
    final parent = source.parent;
    if (parent != null) {
      final hit = _tryResolvePath(parent, strippedSegments);
      if (hit != null) return hit;
    }

    // Step 3: absolute path from root.
    final absoluteHit = _tryResolvePath(root, strippedSegments);
    if (absoluteHit != null) return absoluteHit;

    // Step 4: walk up each remaining ancestor of the source, resolving as
    // that ancestor's child path.
    var ancestor = parent?.parent;
    while (ancestor != null) {
      final hit = _tryResolvePath(ancestor, strippedSegments);
      if (hit != null) return hit;
      ancestor = ancestor.parent;
    }

    throw StateError(
        'Unresolvable target "$targetStr" from source "${source.path}"');
  }
}
