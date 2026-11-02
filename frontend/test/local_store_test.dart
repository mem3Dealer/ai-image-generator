import 'dart:io';
import 'dart:typed_data';

import 'package:ai_image_generator/core/active_generation.dart';
import 'package:ai_image_generator/core/app_session.dart';
import 'package:ai_image_generator/core/generation_options.dart';
import 'package:ai_image_generator/core/history_entry.dart';
import 'package:ai_image_generator/core/local_store.dart';
import 'package:ai_image_generator/core/subscription_status.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory root;
  late String imagesPath;
  late LocalStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('ai_image_generator_');
    imagesPath = p.join(root.path, 'images');
    store = await LocalStore.openAt(
      databasePath: p.join(root.path, 'app.db'),
      imagesPath: imagesPath,
    );
    expect(root.path.startsWith(Directory.systemTemp.path), isTrue);
    expect(root.path.contains('${Platform.pathSeparator}Documents'), isFalse);
    expect(p.join(root.path, 'app.db').startsWith(root.path), isTrue);
    expect(imagesPath.startsWith(root.path), isTrue);
  });

  tearDown(() async {
    await store.close();
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test('creates one user id and keeps the subscription unknown', () async {
    final AppSession created = await store.ensureUserId();
    final AppSession loaded = await store.ensureUserId();
    expect(created.userId, isNotNull);
    expect(
      created.userId,
      matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')),
    );
    expect(loaded.userId, created.userId);
    expect(loaded.subscriptionStatus, SubscriptionStatus.unknown);
  });

  test('stores free and premium without writing unknown', () async {
    await store.ensureUserId();
    await store.saveSubscription(SubscriptionStatus.free);
    expect((await store.readSession()).subscriptionStatus, SubscriptionStatus.free);
    await store.saveSubscription(SubscriptionStatus.premium);
    expect((await store.readSession()).subscriptionStatus, SubscriptionStatus.premium);
    expect(
      () => store.saveSubscription(SubscriptionStatus.unknown),
      throwsArgumentError,
    );
  });

  test('keeps a single active generation snapshot', () async {
    final ActiveGeneration first = _active('first', DateTime.utc(2026, 1, 1));
    final ActiveGeneration second = _active('second', DateTime.utc(2026, 1, 2));
    await store.saveActiveGeneration(first);
    await store.saveActiveGeneration(second);
    final AppSession session = await store.readSession();
    expect(session.activeGeneration?.id, 'second');
    expect(session.activeGeneration?.prompt, 'prompt-second');
    expect(session.activeGeneration?.options.style, animeStyle);
    expect(session.activeGeneration?.startedAt, DateTime.utc(2026, 1, 2));
  });

  test('writes a completed image inside the temporary directory and clears the active id', () async {
    final ActiveGeneration generation = _active('done', DateTime.utc(2026, 3, 1, 4));
    final Uint8List bytes = Uint8List.fromList(<int>[1, 2, 3, 4]);
    await store.saveActiveGeneration(generation);
    final HistoryEntry entry = await store.saveGeneration(
      generation: generation,
      status: HistoryStatus.completed,
      imageBytes: bytes,
    );
    expect(entry.imagePath, isNotNull);
    expect(entry.imagePath!.startsWith(imagesPath), isTrue);
    expect(await File(entry.imagePath!).readAsBytes(), bytes);
    expect((await store.readSession()).activeGeneration, isNull);
    final List<HistoryEntry> history = await store.readHistory();
    expect(history, hasLength(1));
    expect(history.single.status, HistoryStatus.completed);
    expect(history.single.prompt, generation.prompt);
    expect(history.single.options.quality, hdQuality);
  });

  test('stores a failed generation without an image file', () async {
    final ActiveGeneration generation = _active('failed', DateTime.utc(2026, 3, 2));
    await store.saveActiveGeneration(generation);
    final HistoryEntry entry = await store.saveGeneration(
      generation: generation,
      status: HistoryStatus.failed,
    );
    expect(entry.imagePath, isNull);
    expect(await File(p.join(imagesPath, '${generation.id}.png')).exists(), isFalse);
    expect((await store.readSession()).activeGeneration, isNull);
    expect((await store.readHistory()).single.status, HistoryStatus.failed);
  });

  test('does not record history when the image file cannot be saved', () async {
    final ActiveGeneration generation = _active('blocked', DateTime.utc(2026, 3, 3));
    await store.saveActiveGeneration(generation);
    await Directory(imagesPath).delete(recursive: true);
    await File(imagesPath).writeAsString('blocked');
    await expectLater(
      store.saveGeneration(
        generation: generation,
        status: HistoryStatus.completed,
        imageBytes: Uint8List.fromList(<int>[9]),
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect((await store.readSession()).activeGeneration?.id, generation.id);
    expect(await store.readHistory(), isEmpty);
  });

  test('returns history from newest to oldest', () async {
    await store.saveGeneration(
      generation: _active('older', DateTime.utc(2026, 1, 1)),
      status: HistoryStatus.failed,
    );
    await store.saveGeneration(
      generation: _active('newer', DateTime.utc(2026, 2, 1)),
      status: HistoryStatus.failed,
    );
    final List<HistoryEntry> history = await store.readHistory();
    expect(history.map((HistoryEntry entry) => entry.id), <String>['newer', 'older']);
  });
}

ActiveGeneration _active(String id, DateTime startedAt) {
  return ActiveGeneration(
    id: id,
    prompt: 'prompt-$id',
    options: const GenerationOptions(
      style: animeStyle,
      aspectRatio: wideAspectRatio,
      quality: hdQuality,
    ),
    startedAt: startedAt,
  );
}
