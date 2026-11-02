import '../../core/active_generation.dart';
import '../../core/generation_options.dart';
import '../../core/history_entry.dart';

sealed class GenerateState {
  const GenerateState();
}

class GenerateIdle extends GenerateState {
  const GenerateIdle({this.activeGeneration, this.isInterrupted = false});

  final ActiveGeneration? activeGeneration;
  final bool isInterrupted;
}

class GenerateInProgress extends GenerateState {
  const GenerateInProgress({this.activeGeneration});

  final ActiveGeneration? activeGeneration;
}

class GenerateSuccess extends GenerateState {
  const GenerateSuccess({required this.entry});

  final HistoryEntry entry;
}

enum GenerateFailureKind {
  generationFailed,
  premiumRequired,
  invalidRequest,
  requestFailed,
  unavailable,
}

class GenerateFailure extends GenerateState {
  const GenerateFailure({
    required this.kind,
    required this.message,
    this.rejectedOptions,
  });

  final GenerateFailureKind kind;
  final String message;
  final GenerationOptions? rejectedOptions;
}
