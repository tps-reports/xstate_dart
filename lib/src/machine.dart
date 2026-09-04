// Derived from forge_ui lib/util/StateMachine.dart (fivex project).
import 'dart:convert';
import 'result.dart';
import 'state_node.dart';
import 'transition_def.dart';

typedef ActionFn =
    void Function(Map<String, dynamic> context, Map<String, dynamic> event);
typedef GuardFn =
    bool Function(
      Map<String, dynamic> context,
      Map<String, dynamic> event,
      bool Function(String path) isActive,
    );

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
/// `initial` children (recursively) until an atomic leaf is reached. A
/// compound state may omit `initial` only if it declares at least one
/// targeted `always`: that array is resolved once, synchronously, at entry
/// to pick the child (see `_resolveMissingInitial`) — it is not left for a
/// later settle pass, since the state remains its own descendant's ancestor
/// indefinitely and would otherwise be re-evaluated forever. A compound
/// state with neither `initial` nor a resolving targeted `always` throws
/// `StateError`. Entering a parallel state enters every non-history child.
/// History children are never auto-entered.
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
/// exact (deliberately non-SCXML) semantics. If the resolved target *is*
/// that transition domain (a leaf self-transition, a target that is its own
/// ancestor, or a parallel region's own root), there is nothing "below the
/// domain" to enter back down to, so `target` is instead fully exited and
/// fully re-entered as a unit (see [_takeTransition]'s external-re-entry
/// branch).
class StateMachine {
  final StateNode root;
  final Map<String, ActionFn> _actions;
  final Map<String, GuardFn> _guards;
  final Map<String, dynamic> _context;
  final Set<String> _configuration = {}; // active leaf paths
  final Map<String, String> _history =
      {}; // parent path -> last active child key
  // State path -> accumulated active MICROseconds (states with `after`
  // only). Microsecond precision keeps sub-millisecond tick() durations
  // exact (Duration.inMicroseconds never truncates a real Duration);
  // `after` thresholds stay declared in milliseconds and snapshots keep
  // serializing whole milliseconds under "timersMs" (see toSnapshotJson).
  final Map<String, int> _timersUs = {};

  StateMachine._(this.root, this._actions, this._guards, this._context) {
    _enterNode(root, const {});
    _settle(const {});
  }

  factory StateMachine.fromJson(
    String json, {
    Map<String, ActionFn> actions = const {},
    Map<String, GuardFn> guards = const {},
  }) {
    final cfg = jsonDecode(json) as Map<String, dynamic>;
    // Parse the root with an empty key so child paths have no root prefix
    // (children of "toggle" are addressed as "off", "on", not
    // "toggle.off").
    final root = StateNode.parse('', cfg);
    final context = Map<String, dynamic>.from(
      cfg['context'] as Map? ?? const {},
    );
    return StateMachine._(root, actions, guards, context);
  }

  /// The machine's context (arbitrary user data threaded through actions and
  /// guards). Shallowly unmodifiable: the top-level [Map] returned cannot be
  /// mutated (assigning `context['x'] = ...` throws), but nested
  /// maps/lists stored as values are returned as-is and remain mutable —
  /// this is by design, since actions are handed the *same* live `_context`
  /// map (not this wrapped copy) and routinely mutate nested structures
  /// in place (e.g. `(c['CD'] as Map)['colliding'] = ...`).
  Map<String, dynamic> get context => Map.unmodifiable(_context);

  /// The full active configuration: every active leaf plus all of its
  /// ancestors (the "ancestor closure"), so e.g. an active leaf `"a.b.c"`
  /// also contributes `"a"` and `"a.b"`. [matches] and [StateTransitionResult
  /// .activeStates]/[StateTransitionResult.previousStates] all use this same
  /// closure, so an ancestor path matches consistently everywhere.
  Set<String> get activeStates => _expandToAncestorClosure(_configuration);

  /// Expand a set of active *leaf* paths into the same ancestor-closure
  /// shape as [activeStates] — every leaf plus all of its ancestor prefixes.
  Set<String> _expandToAncestorClosure(Set<String> leaves) {
    final all = <String>{};
    for (final leaf in leaves) {
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

    // A handler declared on an ancestor shared by multiple active regions
    // (e.g. directly on a `parallel` state) is discovered once per region
    // leaf that bubbles up to it — the same (source, transition) pair would
    // otherwise fire once per leaf instead of once for the whole macrostep.
    // Track which (source node, matched def) pairs have already been taken
    // this `send()` call and skip repeats; identity equality on both fields
    // is exactly right here, since two textually-identical but separately
    // declared `on` entries (e.g. the same event name handled locally by
    // two different leaves) are different [TransitionDef] instances and
    // must still each fire independently.
    final taken = <({StateNode source, TransitionDef def})>{};

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
      if (!taken.add((source: source, def: chosen))) continue;

      if (chosen.target == null) {
        // Internal transition: run actions only, no state change.
        _runActions(chosen.actions, eventData);
        continue;
      }

      _takeTransition(source, leaf, chosen, eventData);
    }

    _settle(const {});

    return StateTransitionResult(
      activeStates: activeStates,
      changed: !_sameConfiguration(_configuration, before),
      previousStates: _expandToAncestorClosure(before),
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
          '"${found.source.path}" (exceeded $_maxMicrosteps microsteps)',
        );
      }
      _takeTransition(found.source, found.leaf, found.def, eventData);
    }
    _runAlwaysDoActivities(eventData);
  }

  /// Whether `node`'s `always` array is (solely) a missing-`initial`
  /// selector: a compound state with children but no `initial`. Per
  /// `_resolveMissingInitial`, that array is resolved exactly once,
  /// synchronously, at entry — it must never be reconsidered by the
  /// standing settle scans below. Unlike an atomic state's `always` (which
  /// naturally drops out of the active configuration once its transition is
  /// taken), a compound state remains its resolved child's ancestor for as
  /// long as it stays active, so its `always` would otherwise stay
  /// perpetually "eligible" — and a guarded-with-unconditional-fallback
  /// array (the very shape this pattern needs, to guarantee resolution)
  /// would ping-pong forever once its own entry actions flip the guard's
  /// inputs.
  bool _isInitialSelector(StateNode node) =>
      node.children.isNotEmpty && node.initial == null;

  /// Scan the active configuration (each active leaf, then its ancestors,
  /// deduplicated within one scan since guard evaluation is order-stable) for
  /// the first enabled `always` entry that has a target. Returns the state
  /// whose `always` list matched, the active leaf that led to it (needed to
  /// compute the transition's exit domain the same way `send` does), and the
  /// matched [TransitionDef]. Skips any node whose `always` is a
  /// missing-`initial` selector (see [_isInitialSelector]).
  ({StateNode source, StateNode leaf, TransitionDef def})?
  _findEnabledTargetedAlways(Map<String, dynamic> eventData) {
    final visited = <StateNode>{};
    for (final leafPath in List<String>.from(_configuration)) {
      final leaf = _nodeAt(leafPath);
      var node = leaf;
      while (true) {
        if (visited.add(node) && !_isInitialSelector(node)) {
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

  /// Take a targeted transition (an `on`, `always`, or due `after`
  /// transition — `send` calls this directly for its own `on` handling too)
  /// exactly the same way: resolve the target, exit up to the LCA (or the
  /// target's region, if the LCA is parallel), run the transition's
  /// actions, then enter back down to the target.
  ///
  /// **External re-entry**: if the resolved target *is* the transition
  /// domain itself — a leaf self-transition (`a` --SELF--> `a`), a child
  /// targeting its own ancestor (`c1` --> parent `p`), or a target that is a
  /// parallel region's root — then `_chainDownTo(target, domain)` would
  /// return an *empty* chain (a node is excluded from its own down-chain by
  /// definition), so entering "down to" `target` would enter nothing at
  /// all: `target` would be exited and never re-entered, silently dropping
  /// it (and everything under it) from the configuration. That shape is
  /// handled separately here: `target` is fully exited (its own exit
  /// actions run) and then fully re-entered (its own entry actions run,
  /// followed by normal descent through `initial`/parallel children), i.e.
  /// treated as an external self-transition on `target`, not an internal
  /// no-op.
  void _takeTransition(
    StateNode source,
    StateNode leaf,
    TransitionDef def,
    Map<String, dynamic> eventData,
  ) {
    var target = _resolveTarget(source, def.target!);
    if (target.isHistory) {
      target = _resolveHistoryTarget(target);
    }
    final lca = _lca(source, target);
    final domains = _transitionDomains(leaf, target, lca);

    if (identical(target, domains.domain)) {
      _exitNode(target, eventData);
      _runActions(def.actions, eventData);
      _enterNode(target, eventData);
      return;
    }

    _exitNode(domains.exitDomain, eventData);
    _runActions(def.actions, eventData);
    _enterChain(_chainDownTo(target, domains.domain), eventData);
  }

  /// After the targeted `always` fixed point, run the actions of every
  /// enabled target-less `always` entry on every active state, once each
  /// (do-activity semantics) — deduplicated the same way as
  /// [_findEnabledTargetedAlways]. Skips any node whose `always` is a
  /// missing-`initial` selector (see [_isInitialSelector]) — such a node's
  /// `always` array never has target-less entries in practice, but the
  /// guard is applied for the same reason as in the targeted scan.
  void _runAlwaysDoActivities(Map<String, dynamic> eventData) {
    final visited = <StateNode>{};
    for (final leafPath in List<String>.from(_configuration)) {
      var node = _nodeAt(leafPath);
      while (true) {
        if (visited.add(node) && !_isInitialSelector(node)) {
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

  // --- Timed (`after`) transitions -----------------------------------------

  /// Advance every active state's `after` timer by [elapsed], then attempt
  /// any transitions whose accumulated time has crossed a threshold.
  ///
  /// There is no wall clock anywhere in this interpreter: `after` timers
  /// only advance when the caller explicitly calls `tick` (e.g. once per
  /// game frame). `send` never advances them.
  ///
  /// For every currently active state (leaves and their ancestors) that
  /// declares `after`, [elapsed] is added to that state's accumulated active
  /// time. Then, repeatedly: scan the active configuration for the first
  /// active state with a due `after` key (lowest threshold first) whose
  /// transition is enabled (guards respected), and take it with full
  /// exit/enter semantics — exactly like a targeted `always` transition.
  /// Taking a transition may change the active configuration (entering a
  /// state resets its timer, exiting one removes it), so the scan restarts
  /// after each transition. Once no due `after` transition is enabled
  /// anywhere, `_settle` runs (so any `always` transitions unblocked by the
  /// timed transition also settle) and `tick` returns.
  ///
  /// Throws [StateError] if 32 timed transitions fire without reaching a
  /// fixed point (an `after` transition cycle).
  ///
  /// A single `tick` call fires at most one `after`-hop per chain: entering
  /// a state resets its timer to `0` (see `_resetTimer`), so any of
  /// `elapsed`'s duration "left over" after an earlier hop in the same call
  /// is not carried into the newly-entered state's timer — that overshoot is
  /// simply dropped, and the newly-entered state's own `after` (if any)
  /// only starts accumulating from the *next* `tick` call. Fixed-timestep
  /// callers (ticking with the same small `elapsed` every frame) are
  /// unaffected in practice, since the dropped remainder is bounded by one
  /// frame's worth of time.
  void tick(Duration elapsed) {
    const eventData = <String, dynamic>{};
    final us = elapsed.inMicroseconds;
    if (us > 0) {
      for (final path in activeStates) {
        final node = _nodeAt(path);
        if (node.after.isNotEmpty) {
          _timersUs[path] = (_timersUs[path] ?? 0) + us;
        }
      }
    }

    for (var step = 0; step <= _maxMicrosteps; step++) {
      final found = _findDueAfter(eventData);
      if (found == null) break;
      if (step == _maxMicrosteps) {
        throw StateError(
          'Timed "after" transition loop detected in state '
          '"${found.source.path}" (exceeded $_maxMicrosteps microsteps)',
        );
      }
      _takeTransition(found.source, found.leaf, found.def, eventData);
    }

    _settle(eventData);
  }

  /// Scan the active configuration (each active leaf, then its ancestors,
  /// deduplicated within one scan) for the first active state whose `after`
  /// timer has crossed a threshold with an enabled transition. Thresholds on
  /// a single state are attempted lowest-first; a key whose threshold hasn't
  /// been reached yet stops the scan for that state (higher keys can't be due
  /// either, since keys are sorted ascending). Only targeted `after` entries
  /// are considered — an `after` clause with no target is an unresolvable
  /// configuration, not a repeating do-activity, so it is skipped.
  ({StateNode source, StateNode leaf, TransitionDef def})? _findDueAfter(
    Map<String, dynamic> eventData,
  ) {
    final visited = <StateNode>{};
    for (final leafPath in List<String>.from(_configuration)) {
      final leaf = _nodeAt(leafPath);
      var node = leaf;
      while (true) {
        if (visited.add(node) && node.after.isNotEmpty) {
          final accumulated = _timersUs[node.path] ?? 0;
          final keys = node.after.keys.toList()..sort();
          for (final key in keys) {
            if (accumulated < key * 1000) break; // keys are milliseconds
            final defs = node.after[key]!;
            for (final def in defs) {
              if (def.target == null) continue;
              if (_guardPasses(def, eventData)) {
                return (source: node, leaf: leaf, def: def);
              }
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

  // --- Snapshotting ---------------------------------------------------------

  /// Serialize the machine's full runtime state — active configuration,
  /// context, history, and accumulated `after` timers — to a JSON string.
  ///
  /// The result is opaque to the caller except for its four top-level keys
  /// (`configuration`, `context`, `history`, `timersMs`); pass it back to
  /// [restoreSnapshot] on a freshly-constructed machine built from the same
  /// chart to resume exactly where this machine left off.
  ///
  /// `timersMs` serializes whole milliseconds even though timers accumulate
  /// in microseconds internally: any sub-millisecond remainder is dropped at
  /// save time (a bounded, at-most-1ms-per-state loss on a save/load
  /// round-trip), keeping the snapshot format identical to pre-0.1.2
  /// releases.
  String toSnapshotJson() {
    return jsonEncode({
      'configuration': _configuration.toList(),
      'context': _context,
      'history': _history,
      'timersMs': _timersUs.map((path, us) => MapEntry(path, us ~/ 1000)),
    });
  }

  /// Replace this machine's active configuration, context, history, and
  /// `after` timers with the ones recorded in [json] (produced by an earlier
  /// call to [toSnapshotJson] against a machine built from the same chart).
  ///
  /// This is a restore, not a transition: no entry/exit actions run and
  /// [_settle] is not invoked — the snapshot is trusted to already describe
  /// a settled configuration. Snapshots may be hand-edited (this machine
  /// backs game save files), so every input shape is checked before any
  /// state is mutated — a rejected snapshot leaves this machine untouched:
  ///
  /// - `configuration` must be present and a JSON array, and must not be
  ///   empty — an empty configuration cannot describe any real machine (even
  ///   `_enterNode(root)` always produces at least one active leaf), so it
  ///   is rejected rather than silently producing a machine with no active
  ///   states at all.
  /// - Each `configuration` entry must name an existing node in this
  ///   machine's chart, and that node must be a leaf (atomic) state — a
  ///   compound path (e.g. `"m"` when only `"m.a"`/`"m.b"` are real states)
  ///   is rejected, since the interpreter's invariant is that
  ///   `_configuration` holds only atomic-state paths. A history
  ///   pseudo-state path (`history: true`) is rejected too, even though it
  ///   is technically childless (so `isLeaf` alone wouldn't catch it) — a
  ///   history pseudo-state is never itself a real active state.
  /// - Every pair of `configuration` entries must be orthogonal: two active
  ///   leaves can only coexist if their nearest common ancestor is a
  ///   `parallel` state (i.e. they live in different regions) — two leaves
  ///   that are siblings/cousins under a plain compound ancestor (e.g.
  ///   `["m.a", "m.b"]` when `m` is not `parallel`) describe two states
  ///   "active" under a parent that can only ever have one active child at
  ///   a time, which is not a reachable configuration.
  /// - `history` entries must each name an existing parent-state path whose
  ///   value is the key of one of that parent's *non-history* children —
  ///   a value naming a nonexistent or `history: true` child is rejected,
  ///   since it would otherwise surface later as a crash inside
  ///   `_resolveHistoryTarget` during gameplay rather than at load time.
  /// - `timersMs` keys must each name an existing state path.
  ///
  /// Any violation throws a [StateError] naming the offending path/value. A
  /// missing or non-list `configuration` throws a [FormatException] instead
  /// (there is no path to name), so malformed top-level shape and semantic
  /// violations are both reported as an intentional, typed failure — never
  /// an unguarded cast/null-check crash.
  void restoreSnapshot(String json) {
    final decoded = jsonDecode(json) as Map<String, dynamic>;

    final rawConfiguration = decoded['configuration'];
    if (rawConfiguration is! List) {
      throw FormatException(
        'restoreSnapshot: snapshot is missing a "configuration" list',
      );
    }
    final configuration = rawConfiguration.map((e) => e as String).toList();
    if (configuration.isEmpty) {
      throw StateError('restoreSnapshot: "configuration" must not be empty');
    }
    for (final path in configuration) {
      if (path.isEmpty || !_pathExists(path)) {
        throw StateError('restoreSnapshot: unknown state path "$path"');
      }
      final node = _nodeAt(path);
      if (node.isHistory) {
        throw StateError(
          'restoreSnapshot: configuration path "$path" is a '
          'history pseudo-state, not a real active state',
        );
      }
      if (!node.isLeaf) {
        throw StateError(
          'restoreSnapshot: configuration path "$path" is '
          'not an atomic (leaf) state',
        );
      }
    }
    for (var i = 0; i < configuration.length; i++) {
      for (var j = i + 1; j < configuration.length; j++) {
        final a = _nodeAt(configuration[i]);
        final b = _nodeAt(configuration[j]);
        if (identical(a, b)) continue; // duplicate path, not a violation
        if (!_lca(a, b).isParallel) {
          throw StateError(
            'restoreSnapshot: configuration paths '
            '"${configuration[i]}" and "${configuration[j]}" are not '
            'orthogonal (only leaves in different parallel regions may '
            'both be active)',
          );
        }
      }
    }

    final context = Map<String, dynamic>.from(
      decoded['context'] as Map? ?? const {},
    );
    final history = Map<String, String>.from(
      (decoded['history'] as Map? ?? const {}).map(
        (k, v) => MapEntry(k as String, v as String),
      ),
    );
    for (final entry in history.entries) {
      final parentPath = entry.key;
      if (!_pathExists(parentPath)) {
        throw StateError('restoreSnapshot: unknown state path "$parentPath"');
      }
      final childKey = entry.value;
      final child = _nodeAt(parentPath).children[childKey];
      if (child == null || child.isHistory) {
        throw StateError(
          'restoreSnapshot: history entry for '
          '"$parentPath" names unknown or invalid child "$childKey"',
        );
      }
    }
    final timersMs = Map<String, int>.from(
      (decoded['timersMs'] as Map? ?? const {}).map(
        (k, v) => MapEntry(k as String, v as int),
      ),
    );
    for (final path in timersMs.keys) {
      if (!_pathExists(path)) {
        throw StateError('restoreSnapshot: unknown state path "$path"');
      }
    }

    _configuration
      ..clear()
      ..addAll(configuration);
    _context
      ..clear()
      ..addAll(context);
    _history
      ..clear()
      ..addAll(history);
    _timersUs
      ..clear()
      ..addAll(timersMs.map((path, ms) => MapEntry(path, ms * 1000)));
  }

  /// Whether `path` names an existing node in this machine's chart (root
  /// included, via the empty path).
  bool _pathExists(String path) {
    if (path.isEmpty) return true;
    var node = root;
    for (final part in path.split('.')) {
      final next = node.children[part];
      if (next == null) return false;
      node = next;
    }
    return true;
  }

  TransitionDef? _firstEnabled(
    List<TransitionDef> defs,
    Map<String, dynamic> eventData,
  ) {
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
    _resetTimer(node);
    _descendAfterEntry(node, eventData);
  }

  /// Clear `node`'s accumulated `after` timer on (re-)entry. No-op for
  /// states that don't declare `after` — [_timersUs] only tracks those.
  void _resetTimer(StateNode node) {
    if (node.after.isNotEmpty) _timersUs[node.path] = 0;
  }

  void _descendAfterEntry(StateNode node, Map<String, dynamic> eventData) {
    if (node.isParallel) {
      for (final child in node.children.values) {
        if (!child.isHistory) _enterNode(child, eventData);
      }
    } else if (node.children.isNotEmpty) {
      final init = node.initial;
      if (init != null) {
        _enterNode(node.children[init]!, eventData);
      } else {
        _resolveMissingInitial(node, eventData);
      }
    } else {
      _configuration.add(node.path);
    }
  }

  /// Resolve a compound state entered with no `initial`: it must declare at
  /// least one targeted `always` that picks a child on its own behalf — the
  /// only legal way to omit `initial`. That `always` array is resolved
  /// exactly once, synchronously, right here at entry — it is deliberately
  /// *not* left for a later settle pass to find via the normal
  /// [_findEnabledTargetedAlways] scan. `node` remains an active ancestor of
  /// whichever leaf ends up entered for as long as `node` stays active, so
  /// if this `always` were instead registered as an ordinary ongoing
  /// eligible transition (e.g. by holding `node.path` as a placeholder in
  /// `_configuration` for the settle loop to pick up), it would be
  /// re-evaluated on every subsequent microstep too. A guarded-with-
  /// unconditional-fallback array — the very pattern that makes omitting
  /// `initial` useful — would then ping-pong forever once its own entry
  /// actions flip the guard's inputs (as `Move`'s does here), which is
  /// exactly the loop `_maxMicrosteps` exists to catch, not something to
  /// paper over. Resolving once at entry avoids that class of bug entirely:
  /// the array is a one-time initial-child selector, not a standing
  /// eventless transition.
  ///
  /// Throws [StateError] if neither `initial` nor a resolving targeted
  /// `always` exists, and if the chosen target lies outside `node`'s own
  /// subtree (the only shape this pattern is meant to support).
  void _resolveMissingInitial(StateNode node, Map<String, dynamic> eventData) {
    final targeted = node.always.where((def) => def.target != null).toList();
    final chosen = _firstEnabled(targeted, eventData);
    if (chosen == null) {
      throw StateError('Compound state ${node.path} has no initial');
    }
    var target = _resolveTarget(node, chosen.target!);
    if (target.isHistory) {
      target = _resolveHistoryTarget(target);
    }
    if (!identical(_lca(node, target), node)) {
      throw StateError(
        'Compound state ${node.path} has no initial, and its '
        'resolving always target "${chosen.target}" escapes its own '
        'subtree (resolved to "${target.path}")',
      );
    }
    _runActions(chosen.actions, eventData);
    _enterChain(_chainDownTo(target, node), eventData);
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
        _timersUs.remove(n.path);
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
      _resetTimer(node);
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
    StateNode leaf,
    StateNode target,
    StateNode lca,
  ) {
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
    final strippedSegments =
        (targetStr.startsWith('.') ? targetStr.substring(1) : targetStr).split(
          '.',
        );

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
      'Unresolvable target "$targetStr" from source "${source.path}"',
    );
  }
}
