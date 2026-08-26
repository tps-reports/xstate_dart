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
/// target if the target itself is compound) — *unless* the LCA is a
/// `parallel` state, in which case the source and target are in different
/// regions and a narrower rule applies; see [_transitionDomains] for the
/// exact (deliberately non-SCXML) semantics.
class StateMachine {
  final StateNode root;
  final Map<String, ActionFn> _actions;
  final Map<String, GuardFn> _guards;
  final Map<String, dynamic> _context;
  final Set<String> _configuration = {}; // active leaf paths
  final Map<String, String> _history = {}; // parent path -> last active child key

  StateMachine._(this.root, this._actions, this._guards, this._context) {
    _enterNode(root, const {});
    _settle(const {});
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

      var target = _resolveTarget(source, chosen.target!);
      if (target.isHistory) {
        target = _resolveHistoryTarget(target);
      }
      final lca = _lca(source, target);
      final domains = _transitionDomains(leaf, target, lca);

      _exitNode(domains.exitDomain, eventData);
      _runActions(chosen.actions, eventData);
      _enterChain(_chainDownTo(target, domains.domain), eventData);
    }

    _settle(const {});

    return StateTransitionResult(
      activeStates: activeStates,
      changed: !_sameConfiguration(_configuration, before),
      previousStates: before,
    );
  }

  bool _sameConfiguration(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);

  // --- Eventless (`always`) transitions ------------------------------------

  static const _maxMicrosteps = 32;

  /// Run the microstep loop to a fixed point.
  ///
  /// Repeatedly scans the active configuration (each active leaf, then its
  /// ancestors) for the first enabled *targeted* `always` transition; takes
  /// it with full exit/enter semantics and restarts the scan. Once no
  /// targeted `always` transition is enabled anywhere, every active state's
  /// enabled *target-less* `always` entries run their actions once
  /// (do-activity semantics) and `_settle` returns.
  ///
  /// Throws [StateError] if 32 targeted microsteps fire without reaching a
  /// fixed point (an eventless transition cycle).
  ///
  /// [eventData] is always `const {}` at every current call site: `always`
  /// transitions are eventless by definition (the SCXML/XState convention),
  /// so their guards and actions never see the event that happened to
  /// precede this settle pass. The parameter exists so guards/actions have
  /// a well-formed (if empty) event map, matching [ActionFn]/[GuardFn]'s
  /// required event argument.
  void _settle(Map<String, dynamic> eventData) {
    for (var step = 0; step <= _maxMicrosteps; step++) {
      final found = _findEnabledTargetedAlways(eventData);
      if (found == null) break;
      if (step == _maxMicrosteps) {
        throw StateError(
            'Eventless "always" transition loop detected in state '
            '"${found.source.path}" (exceeded $_maxMicrosteps microsteps)');
      }
      _takeAlwaysTransition(found.source, found.leaf, found.def, eventData);
    }
    _runAlwaysDoActivities(eventData);
  }

  /// Scan the active configuration (each active leaf, then its ancestors,
  /// deduplicated within one scan since guard evaluation is order-stable) for
  /// the first enabled `always` entry that has a target. Returns the state
  /// whose `always` list matched, the active leaf that led to it (needed to
  /// compute the transition's exit domain the same way `send` does), and the
  /// matched [TransitionDef].
  ({StateNode source, StateNode leaf, TransitionDef def})?
      _findEnabledTargetedAlways(Map<String, dynamic> eventData) {
    final visited = <StateNode>{};
    for (final leafPath in List<String>.from(_configuration)) {
      final leaf = _nodeAt(leafPath);
      var node = leaf;
      while (true) {
        if (visited.add(node)) {
          for (final def in node.always) {
            if (def.target == null) continue;
            if (_guardPasses(def, eventData)) {
              return (source: node, leaf: leaf, def: def);
            }
          }
        }
        final parent = node.parent;
        if (parent == null) break;
        node = parent;
      }
    }
    return null;
  }

  /// Take a targeted `always` transition exactly like a targeted `on`
  /// transition (see `send`): resolve the target, exit up to the LCA (or the
  /// target's region, if the LCA is parallel), run the transition's actions,
  /// then enter back down to the target.
  void _takeAlwaysTransition(StateNode source, StateNode leaf,
      TransitionDef def, Map<String, dynamic> eventData) {
    var target = _resolveTarget(source, def.target!);
    if (target.isHistory) {
      target = _resolveHistoryTarget(target);
    }
    final lca = _lca(source, target);
    final domains = _transitionDomains(leaf, target, lca);

    _exitNode(domains.exitDomain, eventData);
    _runActions(def.actions, eventData);
    _enterChain(_chainDownTo(target, domains.domain), eventData);
  }

  /// After the targeted `always` fixed point, run the actions of every
  /// enabled target-less `always` entry on every active state, once each
  /// (do-activity semantics) — deduplicated the same way as
  /// [_findEnabledTargetedAlways].
  void _runAlwaysDoActivities(Map<String, dynamic> eventData) {
    final visited = <StateNode>{};
    for (final leafPath in List<String>.from(_configuration)) {
      var node = _nodeAt(leafPath);
      while (true) {
        if (visited.add(node)) {
          for (final def in node.always) {
            if (def.target != null) continue;
            if (_guardPasses(def, eventData)) {
              _runActions(def.actions, eventData);
            }
          }
        }
        final parent = node.parent;
        if (parent == null) break;
        node = parent;
      }
    }
  }

  TransitionDef? _firstEnabled(
      List<TransitionDef> defs, Map<String, dynamic> eventData) {
    for (final def in defs) {
      if (_guardPasses(def, eventData)) return def;
    }
    return null;
  }

  /// Whether `def`'s guard (if any) passes; a def with no guard always
  /// passes. Throws if the guard name isn't registered.
  bool _guardPasses(TransitionDef def, Map<String, dynamic> eventData) {
    final guardName = def.guard;
    if (guardName == null) return true;
    final guard = _guards[guardName];
    if (guard == null) {
      throw StateError('Unknown guard: $guardName');
    }
    return guard(_context, eventData, _isActive);
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
  ///
  /// While unwinding, for each compound ancestor passed through (other than
  /// `node` itself) record which child was active, keyed by the ancestor's
  /// path — this is the shallow history a later `isHistory` target restores.
  void _exitNode(StateNode node, Map<String, dynamic> eventData) {
    final activeLeaves = _configuration
        .where((p) => p == node.path || p.startsWith('${node.path}.'))
        .toList();
    for (final leafPath in activeLeaves) {
      var n = _nodeAt(leafPath);
      while (true) {
        _runActions(n.exitActions, eventData);
        if (identical(n, node)) break;
        final parent = n.parent!;
        if (!parent.isParallel) {
          _history[parent.path] = n.key;
        }
        n = parent;
      }
      _configuration.remove(leafPath);
    }
  }

  /// Resolve a history pseudo-state to the real node it should enter:
  /// the parent's last recorded active child, or the parent's `initial`
  /// child if the parent has never been exited before.
  StateNode _resolveHistoryTarget(StateNode historyNode) {
    final parent = historyNode.parent!;
    final childKey = _history[parent.path] ?? parent.initial;
    if (childKey == null) {
      throw StateError('Compound state ${parent.path} has no initial');
    }
    return parent.children[childKey]!;
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

  /// Compute the exit domain and the entry-chain anchor ("domain") for a
  /// transition from `leaf` (the active leaf that owns `source`'s matched
  /// handler) to `target`, given their [_lca].
  ///
  /// **Divergence from SCXML**: SCXML defines the transition domain as the
  /// LCA itself, even when the LCA is a `parallel` state — which means a
  /// transition whose source and target sit in *different regions* of the
  /// same parallel ancestor exits/re-enters the *entire* parallel state (all
  /// regions, including ones untouched by the transition). This interpreter
  /// does not do that, by design: `send` promises that "one event may
  /// transition multiple regions" and that "regions resolve independently",
  /// so a single transition reaching across regions must not disturb a
  /// region it didn't target.
  ///
  /// Concretely: when [lca] is *not* parallel, behavior matches SCXML — the
  /// domain is the LCA, and the exit domain is the LCA's child on `leaf`'s
  /// side (the branch actually being replaced).
  ///
  /// When [lca] *is* parallel, `leaf` and `target` are in different regions.
  /// The source region is left completely untouched (no exit actions run
  /// there, its active leaf is unchanged) — instead, both the domain and the
  /// exit domain become the LCA's child on `target`'s side (the target's
  /// region root): only that region's currently-active subtree is exited,
  /// and entry descends from that same region root down to `target`.
  ({StateNode domain, StateNode exitDomain}) _transitionDomains(
      StateNode leaf, StateNode target, StateNode lca) {
    if (lca.isParallel) {
      final targetRegion = _childTowards(target, lca);
      return (domain: targetRegion, exitDomain: targetRegion);
    }
    return (domain: lca, exitDomain: _childTowards(leaf, lca));
  }

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
