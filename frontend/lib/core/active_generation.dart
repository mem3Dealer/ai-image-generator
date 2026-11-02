import 'generation_options.dart';

class ActiveGeneration {
  const ActiveGeneration({
    required this.id,
    required this.prompt,
    required this.options,
    required this.startedAt,
  });

  final String id;
  final String prompt;
  final GenerationOptions options;
  final DateTime startedAt;
}
