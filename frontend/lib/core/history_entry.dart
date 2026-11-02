import 'generation_options.dart';

enum HistoryStatus { completed, failed }

class HistoryEntry {
  const HistoryEntry({
    required this.id,
    required this.prompt,
    required this.options,
    required this.createdAt,
    required this.status,
    required this.imagePath,
  });

  final String id;
  final String prompt;
  final GenerationOptions options;
  final DateTime createdAt;
  final HistoryStatus status;
  final String? imagePath;
}
