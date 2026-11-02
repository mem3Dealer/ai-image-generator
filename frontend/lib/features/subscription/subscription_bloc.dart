import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/api_client.dart';
import '../../core/api_exception.dart';
import '../../core/local_store.dart';
import '../../core/subscription_status.dart';
import '../../core/user_messages.dart';
import 'subscription_state.dart';

class SubscriptionBloc extends Cubit<SubscriptionState> {
  SubscriptionBloc({
    required ApiClient apiClient,
    required LocalStore localStore,
    required SubscriptionStatus initialStatus,
  }) : _apiClient = apiClient,
       _localStore = localStore,
       super(SubscriptionState(status: initialStatus));

  final ApiClient _apiClient;
  final LocalStore _localStore;
  Future<SubscriptionStatus>? _refreshTask;
  int _revision = 0;

  Future<SubscriptionStatus> refresh() {
    final Future<SubscriptionStatus>? current = _refreshTask;
    if (current != null) {
      return current;
    }
    final Future<SubscriptionStatus> task = _refresh();
    _refreshTask = task;
    return task.whenComplete(() {
      _refreshTask = null;
    });
  }

  Future<bool> purchase() async {
    if (state.isPurchasing) {
      return false;
    }
    final SubscriptionStatus current = state.status;
    emit(SubscriptionState(status: current, isPurchasing: true));
    try {
      final SubscriptionStatus status = await _apiClient.purchasePremium();
      return await _storePurchase(current, status);
    } on ApiResponseException catch (error) {
      _emitPurchaseFailure(current, error.message);
      return false;
    } on ApiException {
      _emitPurchaseFailure(current, couldNotReachServerMessage);
      return false;
    }
  }

  Future<void> applyPremiumDenied() async {
    await _localStore.saveSubscription(SubscriptionStatus.free);
    _revision += 1;
    emit(const SubscriptionState(status: SubscriptionStatus.free));
  }

  void clearMessage() {
    if (state.errorMessage == null) {
      return;
    }
    emit(SubscriptionState(
      status: state.status,
      isRefreshing: state.isRefreshing,
      isPurchasing: state.isPurchasing,
    ));
  }

  Future<SubscriptionStatus> _refresh() async {
    final int revision = _revision;
    final SubscriptionStatus current = state.status;
    emit(SubscriptionState(status: current, isRefreshing: true));
    try {
      final SubscriptionStatus status = await _apiClient.getSubscription();
      return await _storeRefresh(revision, status);
    } on ApiException {
      return _keepStatusAfterFailedRefresh(revision);
    }
  }

  Future<SubscriptionStatus> _storeRefresh(
    int revision,
    SubscriptionStatus status,
  ) async {
    if (revision != _revision) {
      return state.status;
    }
    await _localStore.saveSubscription(status);
    if (revision != _revision) {
      await _localStore.saveSubscription(state.status);
      return state.status;
    }
    emit(SubscriptionState(status: status));
    return status;
  }

  SubscriptionStatus _keepStatusAfterFailedRefresh(int revision) {
    if (revision != _revision) {
      return state.status;
    }
    final SubscriptionStatus status = state.status;
    emit(SubscriptionState(
      status: status,
      errorMessage: couldNotCheckSubscriptionMessage,
    ));
    return status;
  }

  Future<bool> _storePurchase(SubscriptionStatus current, SubscriptionStatus status) async {
    if (status != SubscriptionStatus.premium) {
      _emitPurchaseFailure(current, unexpectedResponseMessage);
      return false;
    }
    await _localStore.saveSubscription(status);
    _revision += 1;
    emit(const SubscriptionState(status: SubscriptionStatus.premium));
    return true;
  }

  void _emitPurchaseFailure(SubscriptionStatus current, String message) {
    emit(SubscriptionState(status: current, errorMessage: message));
  }
}
