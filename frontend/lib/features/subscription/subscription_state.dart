import '../../core/subscription_status.dart';

class SubscriptionState {
  const SubscriptionState({
    required this.status,
    this.isRefreshing = false,
    this.isPurchasing = false,
    this.errorMessage,
  });

  final SubscriptionStatus status;
  final bool isRefreshing;
  final bool isPurchasing;
  final String? errorMessage;
}
