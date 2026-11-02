import 'package:flutter_test/flutter_test.dart';
import 'package:private_agent/services/completion_verification.dart';

void main() {
  const screen = '[1] label "Example One SD"\n[2] label "Live programme"';
  test(
    'separate visible labels are valid evidence without a fabricated joined quote',
    () {
      expect(
        CompletionEvidence.inspect(
          'Example One SD — Live programme',
          screen,
        ).accepted,
        false,
      );
      expect(
        CompletionEvidence.inspect([
          'Example One SD',
          'Live programme',
        ], screen).accepted,
        true,
      );
      expect(
        CompletionEvidence.inspect('Example One SD', screen).accepted,
        true,
      );
    },
  );
  test(
    'missing, malformed, oversized, partially absent and unreadable evidence cannot pass',
    () {
      for (final value in <Object?>[
        null,
        [],
        ['ok'],
        [true],
        {'text': 'Example One SD'},
        ['Example One SD', 'Example One HD'],
        List.filled(5, 'Example One SD'),
        'x' * 513,
      ]) {
        expect(
          CompletionEvidence.inspect(value, screen).accepted,
          false,
          reason: '$value',
        );
      }
      expect(
        CompletionEvidence.inspect(
          'Could not read screen',
          'Could not read screen. Make sure accessibility service is enabled.',
        ).accepted,
        false,
      );
    },
  );
  test(
    'normalization diagnoses formatting without silently relaxing grounding',
    () {
      final evidence = CompletionEvidence.inspect(
        'example one sd\nLive programme',
        'Example One SD  Live programme',
      );
      expect(evidence.accepted, false);
      expect(evidence.normalizedMatch, true);
      expect(evidence.diagnosticFields.values.whereType<String>(), [
        'completion_evidence_mismatch',
      ]);
      expect(evidence.diagnosticFields.keys, isNot(contains('text')));
      expect(
        CompletionEvidence.inspect('Example One HD', screen).normalizedMatch,
        false,
      );
    },
  );
}
