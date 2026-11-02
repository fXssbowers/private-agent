class UiInteractionResult {
  final bool accepted;
  final String reason;
  final String role;
  final String transport;
  final String controlKey;
  const UiInteractionResult({
    required this.accepted,
    this.reason = 'native_rejected',
    this.role = 'unknown',
    this.transport = 'none',
    this.controlKey = '',
  });
  factory UiInteractionResult.fromMap(Map<dynamic, dynamic> value) =>
      UiInteractionResult(
        accepted: value['accepted'] == true,
        reason: value['reason'] as String? ?? 'native_rejected',
        role: value['role'] as String? ?? 'unknown',
        transport: value['transport'] as String? ?? 'none',
        controlKey: value['control_key'] as String? ?? '',
      );
}
