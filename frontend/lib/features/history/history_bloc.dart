import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/history_entry.dart';
import '../../core/local_store.dart';

class HistoryState {
  const HistoryState({
    this.isLoading = false,
    this.entries = const <HistoryEntry>[],
  });

  final bool isLoading;
  final List<HistoryEntry> entries;
}

class HistoryBloc extends Cubit<HistoryState> {
  HistoryBloc({required LocalStore localStore})
    : _localStore = localStore,
      super(const HistoryState());

  final LocalStore _localStore;
  int _request = 0;

  Future<void> load() async {
    final int request = ++_request;
    emit(HistoryState(isLoading: true, entries: state.entries));
    final List<HistoryEntry> entries = await _localStore.readHistory();
    if (request != _request) {
      return;
    }
    emit(HistoryState(entries: entries));
  }
}
