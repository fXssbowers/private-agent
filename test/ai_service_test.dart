import 'package:flutter_test/flutter_test.dart';
import 'package:private_agent/services/ai_service.dart';

void main() {
  group('Terra request compatibility', () {
    const messages = <Map<String, dynamic>>[
      {'role': 'user', 'content': 'Apri Stremio'},
    ];

    Map<String, dynamic> request({
      String url = 'https://api.openai.com/v1',
      String model = 'gpt-6.1-terra',
      bool stream = false,
    }) => AiService.buildChatRequest(
      baseUrl: url,
      model: model,
      messages: messages,
      temperature: 0.7,
      maxTokens: 4096,
      stream: stream,
    );

    test('uses reasoning-compatible parameters for OpenAI Terra', () {
      final body = request();
      expect(body['model'], 'gpt-6.1-terra');
      expect(body['messages'], messages);
      expect(body['max_completion_tokens'], 4096);
      expect(body['reasoning_effort'], 'medium');
      expect(body.containsKey('max_tokens'), isFalse);
      expect(body.containsKey('temperature'), isFalse);
      expect(body.containsKey('stream'), isFalse);
    });

    test('streaming changes only the stream flag', () {
      final streaming = request(stream: true);
      expect(streaming.remove('stream'), isTrue);
      expect(streaming, request());
    });

    test(
      'preserves legacy parameters outside the exact OpenAI Terra route',
      () {
        for (final url in [
          'https://api.deepseek.com',
          'https://api.openai.com.example.test/v1',
          'http://api.openai.com/v1',
          'not a URL',
        ]) {
          final body = request(url: url);
          expect(body['temperature'], 0.7, reason: url);
          expect(body['max_tokens'], 4096, reason: url);
          expect(body.containsKey('reasoning_effort'), isFalse, reason: url);
          expect(
            body.containsKey('max_completion_tokens'),
            isFalse,
            reason: url,
          );
        }
        final otherModel = request(model: 'another-model');
        expect(otherModel['temperature'], 0.7);
        expect(otherModel['max_tokens'], 4096);
        expect(otherModel.containsKey('reasoning_effort'), isFalse);
      },
    );
  });

  test('recognizes only the NVIDIA hosted API URL', () {
    expect(
      AiService.isNvidiaBaseUrl('https://integrate.api.nvidia.com/v1'),
      isTrue,
    );
    expect(AiService.isNvidiaBaseUrl('https://api.deepseek.com'), isFalse);
  });

  test('NVIDIA model picker keeps only verified free chat models', () {
    final models = AiService.filterNvidiaFreeModels([
      'paid/partner-model',
      'nvidia/nemotron-3-super-120b-a12b',
      'nvidia/embed-qa-4',
      'openai/gpt-oss-20b',
    ]);

    expect(models, ['nvidia/nemotron-3-super-120b-a12b', 'openai/gpt-oss-20b']);
  });

  test('GLM is the default NVIDIA model', () {
    expect(AiService.nvidiaDefaultModel, 'z-ai/glm-5.2');
    expect(AiService.nvidiaFreeChatModels.first, 'z-ai/glm-5.2');
  });
}
