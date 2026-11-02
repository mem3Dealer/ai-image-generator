import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/active_generation.dart';
import '../../core/api_client.dart';
import '../../core/api_exception.dart';
import '../../core/generation_options.dart';
import '../../core/history_entry.dart';
import '../../core/local_store.dart';
import '../../core/remote_generation.dart';
import '../../core/user_messages.dart';
import 'generate_state.dart';

class GenerateBloc extends Cubit<GenerateState> {
  GenerateBloc({
    required ApiClient apiClient,
    required LocalStore localStore,
    ActiveGeneration? activeGeneration,
    DateTime Function()? now,
    Future<void> Function(Duration duration)? wait,
    this.pollBudget = const Duration(seconds: 15),
    this.pollInterval = const Duration(seconds: 1),
    this.postTimeout = const Duration(seconds: 15),
  }) : _apiClient = apiClient,
       _localStore = localStore,
       _now = now ?? DateTime.now,
       _wait = wait ?? _delay,
       super(GenerateIdle(activeGeneration: activeGeneration));

  final ApiClient _apiClient;
  final LocalStore _localStore;
  final DateTime Function() _now;
  final Future<void> Function(Duration duration) _wait;
  final Duration pollBudget;
  final Duration pollInterval;
  final Duration postTimeout;
  bool _isRunning = false;

  Future<void> generate({
    required String prompt,
    required GenerationOptions options,
  }) async {
    if (_isRunning) {
      return;
    }
    _isRunning = true;
    try {
      await _generate(prompt: prompt, options: options);
    } finally {
      _isRunning = false;
    }
  }

  Future<void> continueActive() async {
    if (_isRunning) {
      return;
    }
    final GenerateState current = state;
    if (current is! GenerateIdle || current.activeGeneration == null) {
      return;
    }
    final ActiveGeneration active = current.activeGeneration!;
    _isRunning = true;
    emit(GenerateInProgress(activeGeneration: active));
    try {
      await _poll(active);
    } finally {
      _isRunning = false;
    }
  }

  Future<void> _generate({
    required String prompt,
    required GenerationOptions options,
  }) async {
    if (prompt.trim().isEmpty) {
      emit(const GenerateFailure(
        kind: GenerateFailureKind.invalidRequest,
        message: promptRequiredMessage,
      ));
      return;
    }
    emit(const GenerateInProgress());
    try {
      final ActiveGeneration active = await _create(prompt, options);
      emit(GenerateInProgress(activeGeneration: active));
      await _poll(active);
    } on TimeoutException {
      _emitRequestFailed(couldNotReachServerMessage);
    } on ApiTransportException {
      _emitRequestFailed(couldNotReachServerMessage);
    } on ApiUnexpectedResponseException {
      _emitRequestFailed(unexpectedResponseMessage);
    } on ApiResponseException catch (error) {
      emit(_failureForCreate(error, options));
    }
  }

  Future<ActiveGeneration> _create(String prompt, GenerationOptions options) async {
    final String id = await _limit(
      _apiClient.createGeneration(prompt: prompt, options: options),
      postTimeout,
    );
    final ActiveGeneration active = ActiveGeneration(
      id: id,
      prompt: prompt,
      options: options,
      startedAt: _now().toUtc(),
    );
    await _localStore.saveActiveGeneration(active);
    return active;
  }

  Future<void> _poll(ActiveGeneration active) async {
    final DateTime deadline = _now().add(pollBudget);
    while (true) {
      final Duration remaining = _remaining(deadline);
      if (remaining <= Duration.zero) {
        _emitInterrupted(active);
        return;
      }
      final RemoteGeneration? remote = await _readStatus(active, remaining);
      if (remote == null) {
        return;
      }
      if (remote.isProcessing) {
        final bool canPollAgain = await _pause(deadline);
        if (!canPollAgain) {
          _emitInterrupted(active);
          return;
        }
        continue;
      }
      await _finish(active, remote, deadline);
      return;
    }
  }

  Future<RemoteGeneration?> _readStatus(ActiveGeneration active, Duration remaining) async {
    try {
      return await _limit(_apiClient.getGeneration(active.id), remaining);
    } on TimeoutException {
      _emitInterrupted(active);
    } on ApiTransportException {
      _emitInterrupted(active);
    } on ApiUnexpectedResponseException {
      _emitInterrupted(active);
    } on ApiResponseException catch (error) {
      await _handleStatusError(active, error);
    }
    return null;
  }

  Future<void> _finish(
    ActiveGeneration active,
    RemoteGeneration remote,
    DateTime deadline,
  ) async {
    if (remote.isFailed) {
      await _saveFailure(active, remote.errorMessage ?? generationFailedMessage);
      return;
    }
    if (remote.isCompleted) {
      await _saveCompleted(active, remote.imageUrl, deadline);
      return;
    }
    _emitInterrupted(active);
  }

  Future<void> _saveCompleted(
    ActiveGeneration active,
    String? imageUrl,
    DateTime deadline,
  ) async {
    final Duration remaining = _remaining(deadline);
    if (imageUrl == null || remaining <= Duration.zero) {
      _emitInterrupted(active);
      return;
    }
    final Uint8List? bytes = await _download(active, imageUrl, remaining);
    if (bytes == null) {
      return;
    }
    final HistoryEntry entry = await _localStore.saveGeneration(
      generation: active,
      status: HistoryStatus.completed,
      imageBytes: bytes,
    );
    emit(GenerateSuccess(entry: entry));
  }

  Future<Uint8List?> _download(
    ActiveGeneration active,
    String imageUrl,
    Duration remaining,
  ) async {
    try {
      return await _limit(_apiClient.downloadImage(imageUrl), remaining);
    } on TimeoutException {
      _emitInterrupted(active);
    } on ApiTransportException {
      _emitInterrupted(active);
    } on ApiUnexpectedResponseException {
      _emitInterrupted(active);
    } on ApiResponseException {
      _emitInterrupted(active);
    }
    return null;
  }

  Future<void> _saveFailure(ActiveGeneration active, String message) async {
    await _localStore.saveGeneration(
      generation: active,
      status: HistoryStatus.failed,
    );
    emit(GenerateFailure(
      kind: GenerateFailureKind.generationFailed,
      message: message,
    ));
  }

  Future<void> _handleStatusError(
    ActiveGeneration active,
    ApiResponseException error,
  ) async {
    if (error.statusCode != 404) {
      _emitInterrupted(active);
      return;
    }
    await _localStore.clearActiveGeneration();
    emit(GenerateFailure(
      kind: GenerateFailureKind.unavailable,
      message: error.message,
    ));
  }

  Future<bool> _pause(DateTime deadline) async {
    final Duration remaining = _remaining(deadline);
    if (remaining <= Duration.zero) {
      return false;
    }
    final Duration pause = remaining < pollInterval ? remaining : pollInterval;
    await _wait(pause);
    return _remaining(deadline) > Duration.zero;
  }

  Future<T> _limit<T>(Future<T> request, Duration remaining) {
    if (remaining <= Duration.zero) {
      return Future<T>.error(TimeoutException('attempt deadline'));
    }
    return request.timeout(remaining);
  }

  Duration _remaining(DateTime deadline) {
    return deadline.difference(_now());
  }

  void _emitInterrupted(ActiveGeneration active) {
    emit(GenerateIdle(activeGeneration: active, isInterrupted: true));
  }

  void _emitRequestFailed(String message) {
    emit(GenerateFailure(
      kind: GenerateFailureKind.requestFailed,
      message: message,
    ));
  }
}

GenerateFailure _failureForCreate(ApiResponseException error, GenerationOptions options) {
  if (error.statusCode == 400) {
    return GenerateFailure(
      kind: GenerateFailureKind.invalidRequest,
      message: error.message,
    );
  }
  if (error.statusCode == 403 && error.code == 'PREMIUM_REQUIRED') {
    return GenerateFailure(
      kind: GenerateFailureKind.premiumRequired,
      message: error.message,
      rejectedOptions: options,
    );
  }
  return GenerateFailure(
    kind: GenerateFailureKind.requestFailed,
    message: error.message,
  );
}

Future<void> _delay(Duration duration) {
  return Future<void>.delayed(duration);
}
