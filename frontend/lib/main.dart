import 'package:flutter/material.dart';

import 'app.dart';
import 'core/api_client.dart';
import 'core/app_session.dart';
import 'core/local_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final LocalStore localStore = await LocalStore.open();
  final AppSession session = await localStore.ensureUserId();
  final String? userId = session.userId;
  if (userId == null) {
    throw StateError('User id was not created');
  }
  runApp(
    ImageGeneratorApp(
      localStore: localStore,
      apiClient: ApiClient(baseUrl: apiBaseUrl, userId: userId),
      userId: userId,
      initialSubscription: session.subscriptionStatus,
      activeGeneration: session.activeGeneration,
    ),
  );
}
