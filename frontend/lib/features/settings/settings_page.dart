import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/subscription_status.dart';
import '../../widgets/status_notice.dart';
import '../subscription/subscription_bloc.dart';
import '../subscription/subscription_state.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({required this.userId, super.key});

  final String userId;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      children: <Widget>[
        Text('Settings', style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 24),
        const _FieldLabel('Anonymous User ID'),
        SelectableText(userId),
        const SizedBox(height: 20),
        const _FieldLabel('Subscription status'),
        const _SubscriptionSection(),
        const SizedBox(height: 20),
        const _FieldLabel('App version'),
        const _AppVersion(),
      ],
    );
  }
}

class _SubscriptionSection extends StatelessWidget {
  const _SubscriptionSection();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<SubscriptionBloc, SubscriptionState>(
      builder: (BuildContext context, SubscriptionState state) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(_statusLabel(state.status), style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: state.isRefreshing
                  ? null
                  : () => context.read<SubscriptionBloc>().refresh(),
              child: _refreshLabel(state.isRefreshing),
            ),
            if (state.errorMessage != null) ...<Widget>[
              const SizedBox(height: 12),
              StatusNotice(
                title: "Couldn't refresh status",
                message: state.errorMessage!,
                tone: StatusNoticeTone.error,
              ),
            ],
          ],
        );
      },
    );
  }
}

class _AppVersion extends StatefulWidget {
  const _AppVersion();

  @override
  State<_AppVersion> createState() => _AppVersionState();
}

class _AppVersionState extends State<_AppVersion> {
  late final Future<PackageInfo> _info = PackageInfo.fromPlatform();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<PackageInfo>(
      future: _info,
      builder: (BuildContext context, AsyncSnapshot<PackageInfo> snapshot) {
        return Text(snapshot.data?.version ?? 'Unknown');
      },
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(label, style: Theme.of(context).textTheme.titleMedium),
    );
  }
}

Widget _refreshLabel(bool isRefreshing) {
  if (isRefreshing) {
    return const SizedBox(
      width: 18,
      height: 18,
      child: CircularProgressIndicator(strokeWidth: 2),
    );
  }
  return const Text(
    'Restore / Refresh subscription status',
    textAlign: TextAlign.center,
  );
}

String _statusLabel(SubscriptionStatus status) {
  switch (status) {
    case SubscriptionStatus.unknown:
      return 'Unknown';
    case SubscriptionStatus.free:
      return 'Free';
    case SubscriptionStatus.premium:
      return 'Premium';
  }
}
