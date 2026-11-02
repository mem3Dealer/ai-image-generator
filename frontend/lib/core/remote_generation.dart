class RemoteGeneration {
  const RemoteGeneration.processing({required this.id})
    : status = 'processing',
      imageUrl = null,
      errorCode = null,
      errorMessage = null;

  const RemoteGeneration.completed({required this.id, required this.imageUrl})
    : status = 'completed',
      errorCode = null,
      errorMessage = null;

  const RemoteGeneration.failed({
    required this.id,
    required this.errorCode,
    required this.errorMessage,
  }) : status = 'failed',
       imageUrl = null;

  final String id;
  final String status;
  final String? imageUrl;
  final String? errorCode;
  final String? errorMessage;

  bool get isProcessing => status == 'processing';

  bool get isCompleted => status == 'completed';

  bool get isFailed => status == 'failed';
}
