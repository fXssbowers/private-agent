/// Checks grounding against this observation only. It does not decide whether
/// the cited text semantically proves the user's goal; that remains the planner's
/// responsibility. No evidence text is persisted by diagnostics.
class CompletionEvidence {
  final bool accepted;
  final String reason;
  final int count;
  final bool casefoldMatch;
  final bool whitespaceMatch;
  final bool normalizedMatch;

  const CompletionEvidence._(
    this.accepted,
    this.reason,
    this.count, {
    this.casefoldMatch = false,
    this.whitespaceMatch = false,
    this.normalizedMatch = false,
  });

  static CompletionEvidence inspect(Object? value, String screen) {
    final values = value is String
        ? [value]
        : value is List
        ? value
        : null;
    if (values == null ||
        values.isEmpty ||
        values.length > 4 ||
        values.any(
          (v) => v is! String || v.trim().length < 3 || v.length > 512,
        )) {
      return const CompletionEvidence._(
        false,
        'completion_evidence_missing',
        0,
      );
    }
    final fragments = values.cast<String>().map((v) => v.trim()).toList();
    if (screen.trim().isEmpty || screen.startsWith('Could not read screen.')) {
      return CompletionEvidence._(false, 'unreadable', fragments.length);
    }
    String spaces(String text) => text.replaceAll(RegExp(r'\s+'), ' ');
    final exact = fragments.every(screen.contains);
    final lower = screen.toLowerCase();
    final compact = spaces(screen);
    return CompletionEvidence._(
      exact,
      exact ? 'accepted' : 'completion_evidence_mismatch',
      fragments.length,
      casefoldMatch: fragments.every((f) => lower.contains(f.toLowerCase())),
      whitespaceMatch: fragments.every((f) => compact.contains(spaces(f))),
      normalizedMatch: fragments.every(
        (f) => compact.toLowerCase().contains(spaces(f).toLowerCase()),
      ),
    );
  }

  Map<String, Object> get diagnosticFields => {
    'reason': reason,
    'evidence_count': count,
    'evidence_exact_match': accepted,
    'evidence_casefold_match': casefoldMatch,
    'evidence_whitespace_match': whitespaceMatch,
    'evidence_normalized_match': normalizedMatch,
  };
}

/// A rejected completion opens a short read-only recovery phase. Each following
/// decision consumes a repair attempt unless it completes or explicitly resumes
/// the task with a missing condition. All decisions also use the task budget.
class CompletionVerification {
  int? _remaining;
  bool get active => _remaining != null;
  bool get exhausted => _remaining == 0;

  void rejectEvidence() {
    if (_remaining == null) {
      _remaining = 2;
    } else {
      rejectAction();
    }
  }

  void rejectAction() {
    if (_remaining != null && _remaining! > 0) _remaining = _remaining! - 1;
  }

  bool resume(Object? missingCondition) {
    if (!active ||
        missingCondition is! String ||
        missingCondition.trim().length < 3 ||
        missingCondition.length > 240) {
      return false;
    }
    _remaining = null;
    return true;
  }

  String get prompt => !active
      ? ''
      : '''
COMPLETION VERIFICATION PENDING — read-only recovery ($_remaining attempts remain).
The previous done was not grounded in the observation. Do not navigate, click,
type, replan or repeat a completed operation to fix the evidence format.
If the FULL original request is satisfied, return done with completion_evidence:
one exact visible string, or an array of 1–4 exact visible strings (3–512 characters
each). Copy separate labels as separate strings; do not join them into a sentence.
Use only the CURRENT dump below. A query, listing or selected result does not prove
an additional requested operation has happened. Never invent extra requirements.
If an actual requirement is still unmet or a specific observation is needed, return
{"action":"continue_task","params":{"missing_condition":"the precise unmet requirement or observation needed"}}.
That decision itself performs no UI action. Otherwise return failed; the executor
will preserve the current screen and report that completion could not be verified.
''';
}
