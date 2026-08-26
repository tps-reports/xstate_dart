// Derived from forge_ui lib/util/StateMachine.dart (fivex project).
import 'dart:convert';
import 'result.dart';
import 'state_node.dart';
import 'transition_def.dart';

typedef ActionFn = void Function(
    Map<String, dynamic> context, Map<String, dynamic> event);
typedef GuardFn = bool Function(Map<String, dynamic> context,
    Map<String, dynamic> event, bool Function(String path) isActive);

class StateMachine {
  final StateNode root;
  final Map<String, ActionFn> _actions;
  final Map<String, GuardFn> _guards;
  final Map<String, dynamic> _context;
  final Set<String> _configuration = {}; // active leaf paths

  StateMachine._(this.root, this._actions, this._guards, this._context) {
    _enterInitial();
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

  void _enterInitial() {
    final init = root.initial;
    if (init == null) return;
    final node = root.children[init]!;
    _configuration.add(node.path);
    _runActions(node.entryActions, const {});
  }

  StateTransitionResult send(String event, [Map<String, dynamic>? payload]) {
    final eventData = {'type': event, ...?payload};
    final before = Set<String>.from(_configuration);
    var changed = false;

    for (final leafPath in before) {
      final node = _nodeAt(leafPath);
      final defs = node.on[event] ?? const [];
      final chosen = _firstEnabled(defs, eventData);
      if (chosen == null) continue;
      if (chosen.target == null) {
        _runActions(chosen.actions, eventData);
        continue;
      }
      final target = root.children[chosen.target]!;
      _runActions(node.exitActions, eventData);
      _runActions(chosen.actions, eventData);
      _configuration
        ..remove(leafPath)
        ..add(target.path);
      _runActions(target.entryActions, eventData);
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
}
