import 'dart:async';

import 'package:ai_image_generator/core/api_client.dart';
import 'package:ai_image_generator/core/local_store.dart';
import 'package:ai_image_generator/core/subscription_status.dart';
import 'package:ai_image_generator/core/user_messages.dart';
import 'package:ai_image_generator/features/subscription/subscription_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/temporary_store.dart';

void main() {
  late TemporaryStore temporary;
  late LocalStore store;

  setUp(() async {
    temporary = await openTemporaryStore();
    store = temporary.store;
    await store.ensureUserId();
  });

  tearDown(() async {
    await temporary.delete();
  });

  test('starts from the cached premium status', () async {
    await store.saveSubscription(SubscriptionStatus.premium);
    final SubscriptionBloc bloc = _bloc(
      store,
      _offlineClient(),
      SubscriptionStatus.premium,
    );
    expect(bloc.state.status, SubscriptionStatus.premium);
    expect(bloc.state.isRefreshing, isFalse);
    await bloc.close();
  });

  test('keeps a known status when refresh fails', () async {
    await store.saveSubscription(SubscriptionStatus.premium);
    final SubscriptionBloc bloc = _bloc(
      store,
      _offlineClient(),
      SubscriptionStatus.premium,
    );
    expect(await bloc.refresh(), SubscriptionStatus.premium);
    expect(bloc.state.status, SubscriptionStatus.premium);
    expect(bloc.state.errorMessage, couldNotCheckSubscriptionMessage);
    expect(
      (await store.readSession()).subscriptionStatus,
      SubscriptionStatus.premium,
    );
    await bloc.close();
  });

  test('keeps unknown when the first refresh fails', () async {
    final SubscriptionBloc bloc = _bloc(
      store,
      _offlineClient(),
      SubscriptionStatus.unknown,
    );
    expect(await bloc.refresh(), SubscriptionStatus.unknown);
    expect(
      (await store.readSession()).subscriptionStatus,
      SubscriptionStatus.unknown,
    );
    await bloc.close();
  });

  test('stores free and premium from the server', () async {
    final SubscriptionBloc bloc = _bloc(
      store,
      _statusClient('free'),
      SubscriptionStatus.unknown,
    );
    expect(await bloc.refresh(), SubscriptionStatus.free);
    expect((await store.readSession()).subscriptionStatus, SubscriptionStatus.free);
    await bloc.close();
    final SubscriptionBloc buyer = _bloc(
      store,
      _statusClient('premium'),
      SubscriptionStatus.free,
    );
    expect(await buyer.purchase(), isTrue);
    expect(buyer.state.status, SubscriptionStatus.premium);
    expect((await store.readSession()).subscriptionStatus, SubscriptionStatus.premium);
    await buyer.close();
  });

  test('purchase failure does not change the stored status', () async {
    await store.saveSubscription(SubscriptionStatus.free);
    final SubscriptionBloc bloc = _bloc(
      store,
      _offlineClient(),
      SubscriptionStatus.free,
    );
    expect(await bloc.purchase(), isFalse);
    expect(bloc.state.status, SubscriptionStatus.free);
    expect(bloc.state.errorMessage, couldNotReachServerMessage);
    expect((await store.readSession()).subscriptionStatus, SubscriptionStatus.free);
    await bloc.close();
  });

  test('a premium rejection stores free', () async {
    await store.saveSubscription(SubscriptionStatus.premium);
    final SubscriptionBloc bloc = _bloc(
      store,
      _offlineClient(),
      SubscriptionStatus.premium,
    );
    await bloc.applyPremiumDenied();
    expect(bloc.state.status, SubscriptionStatus.free);
    expect((await store.readSession()).subscriptionStatus, SubscriptionStatus.free);
    await bloc.close();
  });

  test('a stale free refresh does not replace a newer premium purchase', () async {
    final Completer<http.Response> subscription = Completer<http.Response>();
    final SubscriptionBloc bloc = _bloc(
      store,
      _purchaseWhileSubscriptionHangs(subscription),
      SubscriptionStatus.free,
    );
    final Future<SubscriptionStatus> refreshTask = bloc.refresh();
    await Future<void>.delayed(Duration.zero);
    expect(await bloc.purchase(), isTrue);
    subscription.complete(http.Response('{"status":"free"}', 200));
    expect(await refreshTask, SubscriptionStatus.premium);
    expect(bloc.state.status, SubscriptionStatus.premium);
    expect(bloc.state.errorMessage, isNull);
    expect((await store.readSession()).subscriptionStatus, SubscriptionStatus.premium);
    await bloc.close();
  });

  test('a failed refresh does not replace a newer premium purchase', () async {
    final Completer<http.Response> subscription = Completer<http.Response>();
    final SubscriptionBloc bloc = _bloc(
      store,
      _purchaseWhileSubscriptionHangs(subscription),
      SubscriptionStatus.free,
    );
    final Future<SubscriptionStatus> refreshTask = bloc.refresh();
    await Future<void>.delayed(Duration.zero);
    expect(await bloc.purchase(), isTrue);
    subscription.completeError(http.ClientException('offline'));
    expect(await refreshTask, SubscriptionStatus.premium);
    expect(bloc.state.status, SubscriptionStatus.premium);
    expect(bloc.state.errorMessage, isNull);
    expect((await store.readSession()).subscriptionStatus, SubscriptionStatus.premium);
    await bloc.close();
  });

  test('shares one in-flight refresh', () async {
    int calls = 0;
    final http.Client counting = MockClient((http.Request request) async {
      calls += 1;
      return http.Response('{"status":"free"}', 200);
    });
    final SubscriptionBloc bloc = _bloc(
      store,
      counting,
      SubscriptionStatus.unknown,
    );
    final Future<SubscriptionStatus> first = bloc.refresh();
    final Future<SubscriptionStatus> second = bloc.refresh();
    expect(await first, SubscriptionStatus.free);
    expect(await second, SubscriptionStatus.free);
    expect(calls, 1);
    await bloc.close();
  });
}

SubscriptionBloc _bloc(
  LocalStore store,
  http.Client client,
  SubscriptionStatus status,
) {
  return SubscriptionBloc(
    apiClient: ApiClient(baseUrl: apiBaseUrl, userId: 'user-id', client: client),
    localStore: store,
    initialStatus: status,
  );
}

http.Client _offlineClient() {
  return MockClient((http.Request request) async {
    throw http.ClientException('offline', request.url);
  });
}

http.Client _statusClient(String status) {
  return MockClient((http.Request request) async {
    return http.Response('{"status":"$status"}', 200);
  });
}

http.Client _purchaseWhileSubscriptionHangs(Completer<http.Response> subscription) {
  return MockClient((http.Request request) async {
    if (request.url.path == '/api/subscription/purchase') {
      return http.Response('{"status":"premium"}', 200);
    }
    return subscription.future;
  });
}
