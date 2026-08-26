class StateTransitionResult {
  final Set<String> activeStates;
  final bool changed;
  final Set<String>? previousStates;
  const StateTransitionResult({
    required this.activeStates,
    required this.changed,
    this.previousStates,
  });
  @override
  String toString() =>
      'StateTransitionResult(active: $activeStates, changed: $changed)';
}
