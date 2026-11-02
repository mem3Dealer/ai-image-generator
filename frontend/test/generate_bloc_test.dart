import 'dart:async';
import 'dart:io';

import 'package:ai_image_generator/core/active_generation.dart';
import 'package:ai_image_generator/core/api_client.dart';
import 'package:ai_image_generator/core/generation_options.dart';
import 'package:ai_image_generator/core/history_entry.dart';
import 'package:ai_image_generator/core/local_store.dart';
import 'package:ai_image_generator/core/user_messages.dart';
import 'package:ai_image_generator/features/generate/generate_bloc.dart';
import 'package:ai_image_generator/features/generate/generate_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/temporary_store.dart';

const String _id = '6f1c0c3e-3c2a-4f0a-9d4b-1a2b3c4d5e6f';
const GenerationOptions _options = GenerationOptions(
  style: animeStyle,
  aspectRatio: portraitAspectRatio,
  quality: hdQuality,
);

void main() {
  late TemporaryStore temporary;
  late LocalStore store;

  setUp(() async {
    temporary = await openTemporaryStore();
    store = temporary.store;
  });

  tearDown(() async {
    await temporary.delete();
  });

  test('saves a completed image and clears the active generation', () async {
    final _Clock clock = _Clock();
    int statusReads = 0;
    final _Script script = _Script((http.Request request) async {
      if (request.method == 'POST') {
        return _pending();
      }
      if (request.url.path.startsWith('/static/')) {
        return http.Response.bytes(<int>[4, 5, 6], 200);
      }
      statusReads += 1;
      if (statusReads == 1) {
        return _status('{"id":"$_id","status":"processing"}');
      }
      return _status(
        '{"id":"$_id","status":"completed","imageUrl":"/static/generated/$_id.png"}',
      );
    });
    final GenerateBloc bloc = _bloc(store, script, clock: clock);
    await bloc.generate(prompt: 'A city', options: freeGenerationOptions);
    final GenerateSuccess success = bloc.state as GenerateSuccess;
    expect(success.entry.status, HistoryStatus.completed);
    expect(success.entry.imagePath, startsWith(temporary.imagesPath));
    expect(await File(success.entry.imagePath!).readAsBytes(), <int>[4, 5, 6]);
    expect((await store.readSession()).activeGeneration, isNull);
    expect(clock.waitMillis, <int>[1000]);
    await bloc.close();
  });

  test('retry after GENERATION_FAILED sends a new POST only when asked', () async {
    int posts = 0;
    final _Script script = _Script((http.Request request) async {
      if (request.method == 'POST') {
        posts += 1;
        return _pending();
      }
      return _status(
        '{"id":"$_id","status":"failed","error":{"code":"GENERATION_FAILED","message":"Image generation failed"}}',
      );
    });
    final GenerateBloc bloc = _bloc(store, script);
    await bloc.generate(prompt: 'trigger-error', options: freeGenerationOptions);
    final GenerateFailure failure = bloc.state as GenerateFailure;
    expect(failure.kind, GenerateFailureKind.generationFailed);
    expect(failure.message, 'Image generation failed');
    expect(posts, 1);
    expect((await store.readHistory()).single.status, HistoryStatus.failed);
    expect((await store.readHistory()).single.imagePath, isNull);
    expect((await store.readSession()).activeGeneration, isNull);
    await bloc.generate(prompt: 'trigger-error', options: freeGenerationOptions);
    expect(posts, 2);
    await bloc.close();
  });

  test('stops polling at the deadline without another request', () async {
    final _Clock clock = _Clock();
    final _Script script = _Script((http.Request request) async {
      if (request.method == 'POST') {
        return _pending();
      }
      return _status('{"id":"$_id","status":"processing"}');
    });
    final GenerateBloc bloc = _bloc(
      store,
      script,
      clock: clock,
      pollBudget: const Duration(milliseconds: 2500),
    );
    await bloc.generate(prompt: 'A city', options: freeGenerationOptions);
    expect(_statusReads(script), 3);
    expect(clock.waitMillis, <int>[1000, 1000, 500]);
    final GenerateIdle idle = bloc.state as GenerateIdle;
    expect(idle.isInterrupted, isTrue);
    expect(idle.activeGeneration?.id, _id);
    expect(await store.readHistory(), isEmpty);
    await bloc.close();
  });

  test('a slow status request cannot extend the deadline', () async {
    final Completer<http.Response> hung = Completer<http.Response>();
    final _Script script = _Script((http.Request request) => hung.future);
    final ActiveGeneration active = _savedActive();
    await store.saveActiveGeneration(active);
    final GenerateBloc bloc = _bloc(
      store,
      script,
      activeGeneration: active,
      pollBudget: const Duration(milliseconds: 80),
    );
    final Stopwatch watch = Stopwatch()..start();
    await bloc.continueActive();
    watch.stop();
    expect(watch.elapsedMilliseconds, lessThan(2000));
    expect(script.calls, 1);
    expect((bloc.state as GenerateIdle).isInterrupted, isTrue);
    expect((await store.readSession()).activeGeneration?.id, _id);
    hung.complete(_status('{"id":"$_id","status":"processing"}'));
    await bloc.close();
  });

  test('a slow image download cannot extend the deadline', () async {
    final Completer<http.Response> hung = Completer<http.Response>();
    final _Script script = _Script((http.Request request) async {
      if (request.method == 'POST') {
        return _pending();
      }
      if (request.url.path.startsWith('/api/')) {
        return _status(
          '{"id":"$_id","status":"completed","imageUrl":"/static/generated/$_id.png"}',
        );
      }
      return hung.future;
    });
    final GenerateBloc bloc = _bloc(
      store,
      script,
      pollBudget: const Duration(milliseconds: 80),
    );
    final Stopwatch watch = Stopwatch()..start();
    await bloc.generate(prompt: 'A city', options: freeGenerationOptions);
    watch.stop();
    expect(watch.elapsedMilliseconds, lessThan(2000));
    expect((bloc.state as GenerateIdle).activeGeneration?.id, _id);
    expect(await store.readHistory(), isEmpty);
    hung.complete(http.Response.bytes(<int>[1], 200));
    await bloc.close();
  });

  test('does not poll a saved generation until continue is requested', () async {
    final ActiveGeneration active = _savedActive();
    await store.saveActiveGeneration(active);
    final _Script script = _Script((http.Request request) async {
      return _error(404, 'NOT_FOUND', 'Generation not found');
    });
    final GenerateBloc bloc = _bloc(store, script, activeGeneration: active);
    expect(script.calls, 0);
    final GenerateIdle idle = bloc.state as GenerateIdle;
    expect(idle.isInterrupted, isFalse);
    expect(idle.activeGeneration?.prompt, 'trigger-error');
    await bloc.continueActive();
    expect(script.calls, 1);
    await bloc.close();
  });

  test('keeps the active generation after HTTP 500 or a network error while polling', () async {
    final GenerateBloc serverError = await _pollAfterCreate(
      store,
      (http.Request request) async => _error(500, 'INTERNAL_ERROR', 'Internal server error'),
    );
    expect((serverError.state as GenerateIdle).isInterrupted, isTrue);
    expect((await store.readSession()).activeGeneration?.id, _id);
    await serverError.close();
    await store.clearActiveGeneration();
    final GenerateBloc offline = await _pollAfterCreate(
      store,
      (http.Request request) async => throw http.ClientException('offline', request.url),
    );
    expect((offline.state as GenerateIdle).activeGeneration?.id, _id);
    expect(await store.readHistory(), isEmpty);
    await offline.close();
  });

  test('keeps the active generation when the image download returns HTTP 404', () async {
    int downloads = 0;
    final _Script script = _Script((http.Request request) async {
      if (request.method == 'POST') {
        return _pending();
      }
      if (request.url.path.startsWith('/static/')) {
        downloads += 1;
        if (downloads == 1) {
          return _error(404, 'NOT_FOUND', 'Generation not found');
        }
        return http.Response.bytes(<int>[4, 5, 6], 200);
      }
      return _status(
        '{"id":"$_id","status":"completed","imageUrl":"/static/generated/$_id.png"}',
      );
    });
    final GenerateBloc bloc = _bloc(store, script);
    await bloc.generate(prompt: 'A city', options: freeGenerationOptions);
    final GenerateIdle interrupted = bloc.state as GenerateIdle;
    expect(interrupted.isInterrupted, isTrue);
    expect(interrupted.activeGeneration?.id, _id);
    expect((await store.readSession()).activeGeneration?.id, _id);
    expect(await store.readHistory(), isEmpty);
    expect(_posts(script), 1);
    await bloc.continueActive();
    final GenerateSuccess success = bloc.state as GenerateSuccess;
    expect(success.entry.id, _id);
    expect(_posts(script), 1);
    expect((await store.readSession()).activeGeneration, isNull);
    await bloc.close();
  });

  test('clears the active generation when it no longer exists', () async {
    final GenerateBloc bloc = await _pollAfterCreate(
      store,
      (http.Request request) async => _error(404, 'NOT_FOUND', 'Generation not found'),
    );
    final GenerateFailure failure = bloc.state as GenerateFailure;
    expect(failure.kind, GenerateFailureKind.unavailable);
    expect(failure.message, 'Generation not found');
    expect((await store.readSession()).activeGeneration, isNull);
    await bloc.close();
  });

  test('premium rejection keeps the submitted options and creates no generation', () async {
    final _Script script = _Script((http.Request request) async {
      return _error(403, 'PREMIUM_REQUIRED', 'This option requires a Premium subscription');
    });
    final GenerateBloc bloc = _bloc(store, script);
    await bloc.generate(prompt: 'A city', options: _options);
    final GenerateFailure failure = bloc.state as GenerateFailure;
    expect(failure.kind, GenerateFailureKind.premiumRequired);
    expect(failure.rejectedOptions?.style, animeStyle);
    expect(failure.rejectedOptions?.aspectRatio, portraitAspectRatio);
    expect(failure.rejectedOptions?.quality, hdQuality);
    expect((await store.readSession()).activeGeneration, isNull);
    expect(script.calls, 1);
    await bloc.close();
  });

  test('shows the server message for an invalid request', () async {
    final GenerateBloc bloc = _bloc(
      store,
      _Script((http.Request request) async => _error(400, 'INVALID_REQUEST', 'Unknown style')),
    );
    await bloc.generate(prompt: 'A city', options: freeGenerationOptions);
    final GenerateFailure failure = bloc.state as GenerateFailure;
    expect(failure.kind, GenerateFailureKind.invalidRequest);
    expect(failure.message, 'Unknown style');
    expect((await store.readSession()).activeGeneration, isNull);
    await bloc.close();
  });

  test('a failed POST stays recoverable until the user tries again', () async {
    final Completer<http.Response> hung = Completer<http.Response>();
    int calls = 0;
    final _Script script = _Script((http.Request request) {
      calls += 1;
      return hung.future;
    });
    final GenerateBloc bloc = _bloc(
      store,
      script,
      postTimeout: const Duration(milliseconds: 80),
    );
    final Future<void> first = bloc.generate(prompt: 'A city', options: freeGenerationOptions);
    await Future<void>.delayed(Duration.zero);
    await bloc.generate(prompt: 'Other', options: freeGenerationOptions);
    final Stopwatch watch = Stopwatch()..start();
    await first;
    watch.stop();
    final GenerateFailure failure = bloc.state as GenerateFailure;
    expect(failure.kind, GenerateFailureKind.requestFailed);
    expect(failure.message, couldNotReachServerMessage);
    expect(calls, 1);
    expect(watch.elapsedMilliseconds, lessThan(2000));
    expect((await store.readSession()).activeGeneration, isNull);
    hung.complete(_error(500, 'INTERNAL_ERROR', 'Internal server error'));
    await bloc.close();
  });

  test('shows the server message for HTTP 500 on POST', () async {
    final GenerateBloc bloc = _bloc(
      store,
      _Script(
        (http.Request request) async => _error(500, 'INTERNAL_ERROR', 'Internal server error'),
      ),
    );
    await bloc.generate(prompt: 'A city', options: freeGenerationOptions);
    final GenerateFailure failure = bloc.state as GenerateFailure;
    expect(failure.kind, GenerateFailureKind.requestFailed);
    expect(failure.message, 'Internal server error');
    await bloc.close();
  });

  test('does not send a blank prompt', () async {
    final _Script script = _Script((http.Request request) async => _pending());
    final GenerateBloc bloc = _bloc(store, script);
    await bloc.generate(prompt: '   ', options: freeGenerationOptions);
    final GenerateFailure failure = bloc.state as GenerateFailure;
    expect(failure.kind, GenerateFailureKind.invalidRequest);
    expect(failure.message, promptRequiredMessage);
    expect(script.calls, 0);
    await bloc.close();
  });

  test('keeps the active generation when the completed response has no image', () async {
    final GenerateBloc bloc = await _pollAfterCreate(
      store,
      (http.Request request) async => _status('{"id":"$_id","status":"completed"}'),
    );
    expect((bloc.state as GenerateIdle).activeGeneration?.id, _id);
    expect(await store.readHistory(), isEmpty);
    await bloc.close();
  });
}

Future<GenerateBloc> _pollAfterCreate(
  LocalStore store,
  Future<http.Response> Function(http.Request request) onStatus,
) async {
  final GenerateBloc bloc = _bloc(
    store,
    _Script((http.Request request) async {
      if (request.method == 'POST') {
        return _pending();
      }
      return onStatus(request);
    }),
  );
  await bloc.generate(prompt: 'A city', options: freeGenerationOptions);
  return bloc;
}

GenerateBloc _bloc(
  LocalStore store,
  _Script script, {
  _Clock? clock,
  ActiveGeneration? activeGeneration,
  Duration? pollBudget,
  Duration? postTimeout,
}) {
  return GenerateBloc(
    apiClient: ApiClient(baseUrl: apiBaseUrl, userId: 'user-id', client: script.client),
    localStore: store,
    activeGeneration: activeGeneration,
    now: clock?.now,
    wait: clock?.wait,
    pollBudget: pollBudget ?? const Duration(seconds: 15),
    postTimeout: postTimeout ?? const Duration(seconds: 15),
  );
}

ActiveGeneration _savedActive() {
  return ActiveGeneration(
    id: _id,
    prompt: 'trigger-error',
    options: freeGenerationOptions,
    startedAt: DateTime.utc(2026, 1, 1),
  );
}

int _statusReads(_Script script) {
  return script.paths.where((String path) => path.startsWith('GET /api/generations/')).length;
}

int _posts(_Script script) {
  return script.paths.where((String path) => path.startsWith('POST ')).length;
}

http.Response _pending() {
  return http.Response('{"id":"$_id","status":"pending"}', 201);
}

http.Response _status(String body) {
  return http.Response(body, 200);
}

http.Response _error(int status, String code, String message) {
  return http.Response(
    '{"error":{"code":"$code","message":"$message"}}',
    status,
  );
}

class _Clock {
  DateTime current = DateTime.utc(2026, 1, 1);
  final List<int> waitMillis = <int>[];

  DateTime now() {
    return current;
  }

  Future<void> wait(Duration duration) async {
    waitMillis.add(duration.inMilliseconds);
    current = current.add(duration);
  }
}

class _Script {
  _Script(this._handle);

  final Future<http.Response> Function(http.Request request) _handle;
  int calls = 0;
  final List<String> paths = <String>[];
  late final http.Client client = MockClient((http.Request request) {
    calls += 1;
    paths.add('${request.method} ${request.url.path}');
    return _handle(request);
  });
}
