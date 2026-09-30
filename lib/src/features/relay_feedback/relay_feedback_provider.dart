import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/account_provider.dart';
import '../../providers/app_security_provider.dart';
import '../../providers/sync_provider.dart';
import '../../core/config/zcash_explorer.dart';
import 'relay_forecast.dart';
import 'relay_forecast_client.dart';

final relayEndpointProvider = Provider<Uri?>(
  (ref) => relayEndpoint(const String.fromEnvironment('VIZOR_RELAY_API_URL')),
);

class RelaySession {
  const RelaySession({
    required this.accountUuid,
    required this.unlocked,
    required this.foreground,
  });
  final String? accountUuid;
  final bool unlocked;
  final bool foreground;
}

class _Foreground extends Notifier<bool> {
  @override
  bool build() {
    final listener = AppLifecycleListener(
      onStateChange: (value) {
        state = value == AppLifecycleState.resumed;
      },
    );
    ref.onDispose(listener.dispose);
    final initial = WidgetsBinding.instance.lifecycleState;
    return initial == null || initial == AppLifecycleState.resumed;
  }
}

final _foregroundProvider = NotifierProvider<_Foreground, bool>(
  _Foreground.new,
);

final relaySessionProvider = Provider<RelaySession>(
  (ref) => RelaySession(
    accountUuid: ref.watch(accountProvider).value?.activeAccountUuid,
    unlocked: !ref.watch(appSecurityProvider).requiresUnlock,
    foreground: ref.watch(_foregroundProvider),
  ),
);

class RelayConsent extends Notifier<bool> {
  @override
  bool build() {
    // Consent does not survive an account change, lock, or process restart.
    ref.watch(relaySessionProvider.select((s) => (s.accountUuid, s.unlocked)));
    return false;
  }

  void enable() => state = true;
  void disable() => state = false;
}

final relayConsentProvider = NotifierProvider<RelayConsent, bool>(
  RelayConsent.new,
);

final relaySourceProvider = Provider.autoDispose<RelayForecastSource?>((ref) {
  final endpoint = ref.watch(relayEndpointProvider);
  if (endpoint == null) return null;
  final client = RelayForecastClient(endpoint: endpoint);
  ref.onDispose(client.close);
  return client;
});

/// Recent history is truncated. Remember terminal evidence until the wallet
/// explicitly reports the same ID pending again; absence is not reorg evidence.
class RelayWalletStatuses extends Notifier<Map<String, bool>> {
  @override
  Map<String, bool> build() {
    final identity = ref.watch(
      relaySessionProvider.select((s) => (s.accountUuid, s.unlocked)),
    );
    Map<String, bool> statuses(SyncState? wallet) {
      if (!identity.$2 ||
          wallet == null ||
          !wallet.belongsToAccount(identity.$1) ||
          !wallet.hasRecentTransactionsData) {
        return {};
      }
      return {
        for (final tx in wallet.recentTransactions)
          zcashDisplayTxidHex(tx.txidHex, ZcashExplorerTxidOrder.protocol):
              tx.minedHeight > BigInt.zero || tx.expiredUnmined,
      };
    }

    ref.listen(syncProvider, (_, next) {
      state = {...state, ...statuses(next.value)};
    });
    return statuses(ref.read(syncProvider).value);
  }
}

final relayWalletStatusesProvider =
    NotifierProvider<RelayWalletStatuses, Map<String, bool>>(
      RelayWalletStatuses.new,
    );

typedef RelayWatchKey = ({String accountUuid, RelayTransaction transaction});

/// A family shares one serial poll loop between views of the same transaction.
/// The wallet's own sync state remains the only confirmation authority.
final relayForecastProvider = StreamProvider.autoDispose
    .family<RelayForecast, RelayWatchKey>((ref, key) {
      final session = ref.watch(relaySessionProvider);
      final enabled = ref.watch(relayConsentProvider);
      final endpoint = ref.watch(relayEndpointProvider);
      if (!enabled ||
          endpoint == null ||
          !session.unlocked ||
          !session.foreground ||
          session.accountUuid != key.accountUuid) {
        return const Stream.empty();
      }
      final source = ref.watch(relaySourceProvider);
      if (source == null) return const Stream.empty();
      final controller = StreamController<RelayForecast>();
      final cancel = Completer<void>();
      Timer? pollTimer;
      Timer? freshnessTimer;
      Completer<void>? wake;
      var stopped = false;
      RelayForecast unavailable() => RelayForecast(
        status: RelayStatus.unavailable,
        asOfMs: DateTime.now().millisecondsSinceEpoch,
      );
      void publish(RelayForecast result) {
        if (stopped) return;
        freshnessTimer?.cancel();
        controller.add(result);
        if (result.status != RelayStatus.unavailable) {
          final remaining =
              result.asOfMs + 15000 - DateTime.now().millisecondsSinceEpoch;
          freshnessTimer = Timer(
            Duration(milliseconds: remaining < 0 ? 0 : remaining),
            () {
              if (!stopped) controller.add(unavailable());
            },
          );
        }
      }

      ref.onDispose(() {
        stopped = true;
        cancel.complete();
        pollTimer?.cancel();
        freshnessTimer?.cancel();
        final pendingWake = wake;
        if (pendingWake != null && !pendingWake.isCompleted) {
          pendingWake.complete();
        }
        unawaited(controller.close());
      });
      Future<void> poll() async {
        final elapsed = Stopwatch()..start();
        var attempts = 0;
        int? lastAsOf;
        while (!stopped && elapsed.elapsed < const Duration(hours: 1)) {
          var failed = false;
          try {
            final result = await source.fetch(
              key.transaction,
              cancelSignal: cancel.future,
            );
            if (stopped) return;
            final now = DateTime.now().millisecondsSinceEpoch;
            if ((lastAsOf != null && result.asOfMs < lastAsOf) ||
                now - result.asOfMs >= 15000 ||
                result.asOfMs - now > 5000) {
              throw const FormatException('Stale relay update');
            }
            lastAsOf = result.asOfMs;
            publish(result);
          } catch (_) {
            if (stopped) return;
            failed = true;
            // Never surface raw errors: they can contain sensitive identifiers.
            publish(unavailable());
          }
          attempts++;
          if (stopped) return;
          final delay = wake = Completer<void>();
          pollTimer = Timer(
            Duration(
              seconds: failed
                  ? 15
                  : attempts < 15
                  ? 1
                  : 5,
            ),
            delay.complete,
          );
          await delay.future;
        }
        if (!stopped) {
          publish(unavailable());
          await controller.close();
        }
      }

      unawaited(poll());
      return controller.stream;
    });
