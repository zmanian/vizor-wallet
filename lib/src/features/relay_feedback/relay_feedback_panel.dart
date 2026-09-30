import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/config/zcash_explorer.dart';
import '../../providers/rpc_endpoint_provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_button.dart';
import 'relay_forecast.dart';
import 'relay_feedback_provider.dart';

/// Display-only feedback: cannot submit, retry, unlock, or confirm a payment.
class RelayFeedbackPanel extends ConsumerWidget {
  const RelayFeedbackPanel({
    required this.accountUuid,

    required this.displayTxids,
    this.active = true,
    super.key,
  });
  final String? accountUuid;
  final List<String> displayTxids;
  final bool active;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final endpoint = ref.watch(relayEndpointProvider);
    // Default builds do not instantiate any account, consent or network state.
    if (endpoint == null ||
        !active ||
        displayTxids.isEmpty ||
        accountUuid == null) {
      return const SizedBox.shrink();
    }
    if (ModalRoute.isCurrentOf(context) == false) {
      return const SizedBox.shrink();
    }
    final session = ref.watch(relaySessionProvider);
    if (!session.unlocked ||
        !session.foreground ||
        session.accountUuid != accountUuid) {
      return const SizedBox.shrink();
    }
    final networkName = ref.watch(rpcEndpointProvider).networkName;
    final transactions = <RelayTransaction>{};
    try {
      for (final txid in displayTxids) {
        transactions.add(
          RelayTransaction.fromWallet(
            networkName: networkName,
            txidHex: txid,
            order: ZcashExplorerTxidOrder.display,
          ),
        );
      }
    } on FormatException {
      return const SizedBox.shrink();
    }
    final walletStatuses = ref.watch(relayWalletStatusesProvider);
    transactions.removeWhere((tx) => walletStatuses[tx.txid] == true);
    if (transactions.isEmpty) return const SizedBox.shrink();
    final enabled = ref.watch(relayConsentProvider);
    final colors = context.colors;
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Relay feedback · experimental',
                style: AppTypography.bodyMediumStrong.copyWith(
                  color: colors.text.primary,
                ),
              ),
              const SizedBox(height: AppSpacing.s),
              if (!enabled) ...[
                Text(
                  'Share transaction IDs from open status screens with ${endpoint.host} for this session. '
                  'Your network privacy settings still apply.',
                  style: AppTypography.bodySmall.copyWith(
                    color: colors.text.primary,
                  ),
                ),
                const SizedBox(height: AppSpacing.s),
                AppButton(
                  size: AppButtonSize.small,
                  variant: AppButtonVariant.secondary,
                  onPressed: () =>
                      ref.read(relayConsentProvider.notifier).enable(),
                  child: const Text('Enable relay feedback'),
                ),
              ] else ...[
                if (transactions.length > 1)
                  Text(
                    '${transactions.length} pending transactions are tracked separately.',
                    style: AppTypography.bodySmall.copyWith(
                      color: colors.text.primary,
                    ),
                  ),
                for (final transaction in transactions)
                  _ForecastRow(
                    accountUuid: accountUuid!,
                    transaction: transaction,
                    showId: transactions.length > 1,
                  ),
                AppButton(
                  size: AppButtonSize.small,
                  variant: AppButtonVariant.ghost,
                  onPressed: () =>
                      ref.read(relayConsentProvider.notifier).disable(),
                  child: const Text('Stop relay feedback'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ForecastRow extends ConsumerWidget {
  const _ForecastRow({
    required this.accountUuid,
    required this.transaction,
    required this.showId,
  });
  final String accountUuid;
  final RelayTransaction transaction;
  final bool showId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(
      relayForecastProvider((
        accountUuid: accountUuid,
        transaction: transaction,
      )),
    );
    // Loading a new session must never display an old account's cached value.
    final forecast = value.isLoading ? null : value.value;
    final probabilities = forecast?.withinBlocks;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.s),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showId)
            Text(
              '${transaction.txid.substring(0, 8)}…',
              style: AppTypography.bodySmall,
            ),
          Text(
            forecast?.headline ?? 'Checking relay observations…',
            style: AppTypography.bodyMediumStrong.copyWith(
              color: context.colors.text.primary,
            ),
          ),
          Text(
            forecast?.detail ??
                'Your wallet continues tracking the transaction.',
            style: AppTypography.bodySmall.copyWith(
              color: context.colors.text.primary,
            ),
          ),
          if (probabilities != null)
            Text(
              'Estimated inclusion: ${(probabilities[0] * 100).round()}% in the next block; '
              '${(probabilities[1] * 100).round()}% within two blocks.',
              style: AppTypography.bodySmall.copyWith(
                color: context.colors.text.primary,
              ),
            ),
        ],
      ),
    );
  }
}
