import 'dart:convert';
import 'dart:typed_data';

import 'package:ai_image_generator/core/api_client.dart';
import 'package:ai_image_generator/core/api_exception.dart';
import 'package:ai_image_generator/core/generation_options.dart';
import 'package:ai_image_generator/core/remote_generation.dart';
import 'package:ai_image_generator/core/subscription_status.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const String _userId = '6f1c0c3e-3c2a-4f0a-9d4b-1a2b3c4d5e6f';

void main() {
  test('reads the subscription and sends X-User-Id', () async {
    final _Recorder recorder = _Recorder((http.Request request) async {
      return http.Response('{"status":"free"}', 200);
    });
    final ApiClient client = _client(recorder);
    expect(await client.getSubscription(), SubscriptionStatus.free);
    expect(recorder.requests.single.headers['x-user-id'], _userId);
    expect(recorder.requests.single.url.path, '/api/subscription');
    client.close();
  });

  test('purchase returns premium', () async {
    final _Recorder recorder = _Recorder((http.Request request) async {
      return http.Response('{"status":"premium"}', 200);
    });
    final ApiClient client = _client(recorder);
    expect(await client.purchasePremium(), SubscriptionStatus.premium);
    expect(recorder.requests.single.method, 'POST');
    expect(recorder.requests.single.body, isEmpty);
    client.close();
  });

  test('creates a generation from the prompt and options', () async {
    final _Recorder recorder = _Recorder((http.Request request) async {
      return http.Response(
        '{"id":"6f1c0c3e-3c2a-4f0a-9d4b-1a2b3c4d5e6f","status":"pending"}',
        201,
      );
    });
    final ApiClient client = _client(recorder);
    final String id = await client.createGeneration(
      prompt: 'trigger-error',
      options: freeGenerationOptions,
    );
    final Object? body = jsonDecode(recorder.requests.single.body);
    expect(id, '6f1c0c3e-3c2a-4f0a-9d4b-1a2b3c4d5e6f');
    expect(recorder.requests.single.headers['x-user-id'], _userId);
    expect(body, <String, Object?>{
      'prompt': 'trigger-error',
      'options': <String, Object?>{
        'style': 'photorealistic',
        'aspectRatio': '1:1',
        'quality': 'standard',
      },
    });
    client.close();
  });

  test('parses processing, completed and failed generations', () async {
    final List<String> bodies = <String>[
      '{"id":"gen","status":"processing"}',
      '{"id":"gen","status":"completed","imageUrl":"/static/generated/gen.png"}',
      '{"id":"gen","status":"failed","error":{"code":"GENERATION_FAILED","message":"Image generation failed"}}',
    ];
    final _Recorder recorder = _Recorder((http.Request request) async {
      return http.Response(bodies.removeAt(0), 200);
    });
    final ApiClient client = _client(recorder);
    final RemoteGeneration processing = await client.getGeneration('gen');
    final RemoteGeneration completed = await client.getGeneration('gen');
    final RemoteGeneration failed = await client.getGeneration('gen');
    expect(processing.isProcessing, isTrue);
    expect(completed.imageUrl, '/static/generated/gen.png');
    expect(failed.errorCode, 'GENERATION_FAILED');
    expect(failed.errorMessage, 'Image generation failed');
    client.close();
  });

  test('throws PREMIUM_REQUIRED for a premium rejection', () async {
    final ApiClient client = _client(
      _Recorder((http.Request request) async {
        return http.Response(
          '{"error":{"code":"PREMIUM_REQUIRED","message":"This option requires a Premium subscription"}}',
          403,
        );
      }),
    );
    await expectLater(
      client.createGeneration(prompt: 'city', options: _premiumOptions),
      throwsA(
        isA<ApiResponseException>()
            .having((ApiResponseException error) => error.statusCode, 'statusCode', 403)
            .having((ApiResponseException error) => error.code, 'code', 'PREMIUM_REQUIRED')
            .having(
              (ApiResponseException error) => error.message,
              'message',
              'This option requires a Premium subscription',
            ),
      ),
    );
    client.close();
  });

  test('rejects a non-JSON response', () async {
    final ApiClient client = _client(
      _Recorder((http.Request request) async {
        return http.Response('<html>', 200);
      }),
    );
    await expectLater(
      client.getSubscription(),
      throwsA(isA<ApiUnexpectedResponseException>()),
    );
    client.close();
  });

  test('downloads a relative image from the API base URL', () async {
    final Uint8List bytes = Uint8List.fromList(<int>[9, 8, 7]);
    final _Recorder recorder = _Recorder((http.Request request) async {
      return http.Response.bytes(bytes, 200);
    });
    final ApiClient client = _client(recorder);
    expect(
      await client.downloadImage('/static/generated/gen.png'),
      bytes,
    );
    expect(
      recorder.requests.single.url.toString(),
      'http://127.0.0.1:8000/static/generated/gen.png',
    );
    expect(recorder.requests.single.headers['x-user-id'], _userId);
    client.close();
  });

  test('ignores a host embedded in the image URL', () async {
    final _Recorder recorder = _Recorder((http.Request request) async {
      return http.Response.bytes(<int>[1], 200);
    });
    final ApiClient client = _client(recorder);
    await client.downloadImage('https://evil.example/static/generated/gen.png');
    expect(recorder.requests.single.url.host, '127.0.0.1');
    expect(recorder.requests.single.url.path, '/static/generated/gen.png');
    client.close();
  });
}

const GenerationOptions _premiumOptions = GenerationOptions(
  style: animeStyle,
  aspectRatio: wideAspectRatio,
  quality: hdQuality,
);

ApiClient _client(_Recorder recorder) {
  return ApiClient(
    baseUrl: apiBaseUrl,
    userId: _userId,
    client: recorder.client,
  );
}

class _Recorder {
  _Recorder(this._handle);

  final Future<http.Response> Function(http.Request request) _handle;
  final List<http.Request> requests = <http.Request>[];
  late final http.Client client = MockClient((http.Request request) {
    requests.add(request);
    return _handle(request);
  });
}
