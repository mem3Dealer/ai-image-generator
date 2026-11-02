import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../widgets/status_notice.dart';
import 'subscription_bloc.dart';
import 'subscription_state.dart';

Future<bool> showPaywall(BuildContext context) {
  final SubscriptionBloc bloc = context.read<SubscriptionBloc>();
  bloc.clearMessage();
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (BuildContext sheetContext) {
      return BlocProvider<SubscriptionBloc>.value(
        value: bloc,
        child: const PaywallSheet(),
      );
    },
  ).then((bool? purchased) => purchased ?? false);
}

class PaywallSheet extends StatelessWidget {
  const PaywallSheet({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<SubscriptionBloc, SubscriptionState>(
      builder: (BuildContext context, SubscriptionState state) {
        return Padding(
          padding: EdgeInsets.fromLTRB(24, 0, 24, 24 + MediaQuery.viewInsetsOf(context).bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text('Premium', style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 8),
              const Text(
                'Anime, Cinematic, and HD quality are part of Premium. '
                'Free includes Photorealistic, Digital Art, every aspect ratio, and Standard quality.',
              ),
              if (state.errorMessage != null) ...<Widget>[
                const SizedBox(height: 16),
                StatusNotice(
                  title: "Purchase didn't go through",
                  message: state.errorMessage!,
                  tone: StatusNoticeTone.error,
                ),
              ],
              const SizedBox(height: 20),
              FilledButton(
                onPressed: state.isPurchasing ? null : () => _purchase(context),
                child: _purchaseLabel(state.isPurchasing),
              ),
            ],
          ),
        );
      },
    );
  }
}

Widget _purchaseLabel(bool isPurchasing) {
  if (isPurchasing) {
    return const SizedBox(
      width: 18,
      height: 18,
      child: CircularProgressIndicator(strokeWidth: 2),
    );
  }
  return const Text('Continue with Premium');
}

Future<void> _purchase(BuildContext context) async {
  final bool purchased = await context.read<SubscriptionBloc>().purchase();
  if (!context.mounted || !purchased) {
    return;
  }
  Navigator.of(context).pop(true);
}
