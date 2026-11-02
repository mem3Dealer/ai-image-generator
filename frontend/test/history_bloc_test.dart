import 'dart:typed_data';

import 'package:ai_image_generator/core/active_generation.dart';
import 'package:ai_image_generator/core/generation_options.dart';
import 'package:ai_image_generator/core/history_entry.dart';
import 'package:ai_image_generator/core/local_store.dart';
import 'package:ai_image_generator/features/history/history_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/temporary_store.dart';

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

  test('loads local history from newest to oldest', () async {
    await store.saveGeneration(
      generation: _generation('older', DateTime.utc(2026, 1, 1)),
      status: HistoryStatus.failed,
    );
    await store.saveGeneration(
      generation: _generation('newer', DateTime.utc(2026, 2, 1)),
      status: HistoryStatus.completed,
      imageBytes: Uint8List.fromList(<int>[1]),
    );
    final HistoryBloc bloc = HistoryBloc(localStore: store);
    await bloc.load();
    expect(bloc.state.isLoading, isFalse);
    expect(bloc.state.entries.map((HistoryEntry entry) => entry.id), <String>['newer', 'older']);
    await bloc.close();
  });
}

ActiveGeneration _generation(String id, DateTime startedAt) {
  return ActiveGeneration(
    id: id,
    prompt: 'prompt-$id',
    options: freeGenerationOptions,
    startedAt: startedAt,
  );
}
