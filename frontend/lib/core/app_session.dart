import 'active_generation.dart';
import 'subscription_status.dart';

class AppSession {
  const AppSession({
    required this.userId,
    required this.subscriptionStatus,
    required this.activeGeneration,
  });

  final String? userId;
  final SubscriptionStatus subscriptionStatus;
  final ActiveGeneration? activeGeneration;
}
