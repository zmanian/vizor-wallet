import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/theme/app_theme.dart';
import 'package:zcash_wallet/src/features/relay_feedback/relay_forecast.dart';
import 'package:zcash_wallet/src/features/relay_feedback/relay_forecast_client.dart';
import 'package:zcash_wallet/src/features/relay_feedback/relay_feedback_provider.dart';
import 'package:zcash_wallet/src/features/relay_feedback/relay_feedback_panel.dart';
import 'relay_forecast_test.dart' show txid, reversedTxid;
import 'package:zcash_wallet/src/providers/sync_provider.dart';
import 'package:zcash_wallet/src/rust/api/sync.dart' as rust_sync;
import '../../fakes/fake_sync_notifier.dart';
import 'package:zcash_wallet/src/providers/rpc_endpoint_provider.dart';
import 'package:zcash_wallet/src/core/config/rpc_endpoint_config.dart';

class TestRpcEndpoint extends RpcEndpointNotifier {
  @override
  RpcEndpointConfig build() => defaultRpcEndpointConfig('test');
}

class Source implements RelayForecastSource {
  int calls = 0;
  String? network;
  bool cancelled = false;
  int ageMs = 0;
  List<double>? probabilities;
  RelayStatus status = RelayStatus.pending;
  Completer<RelayForecast>? pending;
  @override
  Future<RelayForecast> fetch(
    RelayTransaction transaction, {
    Future<void>? cancelSignal,
  }) {
    calls++;
    network = transaction.network;
    cancelSignal?.then((_) => cancelled = true);
    return pending?.future ??
        Future.value(
          RelayForecast(
            status: status,
            asOfMs: DateTime.now().millisecondsSinceEpoch - ageMs,
            withinBlocks: probabilities,
          ),
        );
  }
}

class TestSession extends Notifier<RelaySession> {
  @override
  RelaySession build() => const RelaySession(
    accountUuid: 'account',
    unlocked: true,
    foreground: true,
  );
  void change(RelaySession value) => state = value;
}

final testSession = NotifierProvider<TestSession, RelaySession>(
  TestSession.new,
);

Widget harness(Source source, {bool configured = true, int copies = 1}) =>
    ProviderScope(
      overrides: [
        rpcEndpointProvider.overrideWith(TestRpcEndpoint.new),
        syncProvider.overrideWith(FakeSyncNotifier.new),
        relayEndpointProvider.overrideWithValue(
          configured ? Uri.parse('https://relay.example/v1/forecast') : null,
        ),
        relaySourceProvider.overrideWithValue(source),
        relaySessionProvider.overrideWith((ref) => ref.watch(testSession)),
      ],
      child: MaterialApp(
        home: AppTheme(
          data: AppThemeData.light,
          child: Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: [
                  for (var i = 0; i < copies; i++)
                    const RelayFeedbackPanel(
                      accountUuid: 'account',
                      displayTxids: [txid],
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

Future<void> enable(WidgetTester tester) async {
  await tester.tap(find.text('Enable relay feedback').first);
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('disabled builds and unconsented panels make no requests', (
    tester,
  ) async {
    final source = Source();
    await tester.pumpWidget(harness(source, configured: false));
    expect(find.text('Enable relay feedback'), findsNothing);
    expect(source.calls, 0);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(harness(source));
    expect(find.text('Enable relay feedback'), findsOneWidget);
    await tester.pump(const Duration(seconds: 10));
    expect(source.calls, 0);
    await enable(tester);
    expect(find.text('Seen by the relay'), findsOneWidget);
    expect(source.calls, 1);
    expect(
      source.network,
      'testnet',
      reason: 'Use the active wallet network, not the mainnet build default',
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('two views share a request and stop cancels active tracking', (
    tester,
  ) async {
    final source = Source();
    await tester.pumpWidget(harness(source, copies: 2));
    await enable(tester);
    expect(source.calls, 1);
    expect(find.text('Seen by the relay'), findsNWidgets(2));
    await tester.tap(find.text('Stop relay feedback').first);
    await tester.pump();
    await tester.pump(const Duration(seconds: 20));
    expect(source.calls, 1);
    expect(source.cancelled, isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'a covered status route stops polling until it is visible again',
    (tester) async {
      final source = Source();
      await tester.pumpWidget(harness(source));
      await enable(tester);
      final navigator = Navigator.of(
        tester.element(find.byType(RelayFeedbackPanel)),
      );
      unawaited(
        navigator.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Another screen')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 20));
      expect(source.calls, 1);
      expect(source.cancelled, isTrue);
      navigator.pop();
      await tester.pumpAndSettle();
      expect(source.calls, 2);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'displayed probabilities expire even when the next request hangs',
    (tester) async {
      final source = Source()
        ..ageMs = 14000
        ..probabilities = [0.8, 0.9, 0.95];
      await tester.pumpWidget(harness(source));
      await enable(tester);
      expect(find.textContaining('80% in the next block'), findsOneWidget);
      source.pending = Completer<RelayForecast>();
      await tester.pump(const Duration(milliseconds: 1200));
      await tester.pump();
      expect(find.textContaining('80% in the next block'), findsNothing);
      expect(find.text('Network feedback unavailable'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('a reorg can return reported inclusion to pending', (
    tester,
  ) async {
    final source = Source()..status = RelayStatus.included;
    await tester.pumpWidget(harness(source));
    await enable(tester);
    expect(find.text('Inclusion reported'), findsOneWidget);
    source.status = RelayStatus.pending;
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.text('Seen by the relay'), findsOneWidget);
    expect(find.text('Inclusion reported'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('lock cancels a slow request and suppresses its late result', (
    tester,
  ) async {
    final source = Source()..pending = Completer<RelayForecast>();
    await tester.pumpWidget(harness(source));
    await enable(tester);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(RelayFeedbackPanel)),
    );
    container
        .read(testSession.notifier)
        .change(
          const RelaySession(
            accountUuid: 'account',
            unlocked: false,
            foreground: true,
          ),
        );
    await tester.pump();
    await tester.pump();
    expect(source.cancelled, isTrue);
    source.pending!.complete(
      RelayForecast(
        status: RelayStatus.included,
        asOfMs: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    await tester.pump();
    expect(find.text('Inclusion reported'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'wallet confirmation stops tracking and a wallet reorg resumes it',
    (tester) async {
      final source = Source();
      await tester.pumpWidget(harness(source));
      await enable(tester);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(RelayFeedbackPanel)),
      );
      final sync = container.read(syncProvider.notifier) as FakeSyncNotifier;
      sync.emit(
        SyncState(
          accountUuid: 'account',
          hasRecentTransactionsData: true,
          recentTransactions: [
            rust_sync.TransactionInfo(
              txidHex: reversedTxid,
              minedHeight: BigInt.from(10),
              expiredUnmined: false,
              accountBalanceDelta: 0,
              fee: BigInt.zero,
              blockTime: BigInt.zero,
              isTransparent: false,
              txKind: 'sent',
              displayAmount: BigInt.one,
              displayPool: 'shielded',
              createdTime: BigInt.zero,
            ),
          ],
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 20));
      expect(source.calls, 1);
      expect(source.cancelled, isTrue);
      expect(find.text('Seen by the relay'), findsNothing);
      sync.emit(
        SyncState(accountUuid: 'account', hasRecentTransactionsData: true),
      );
      await tester.pump();
      await tester.pump();
      expect(
        source.calls,
        1,
        reason: 'A truncated recent history is not reorg evidence',
      );
      sync.emit(
        SyncState(
          accountUuid: 'account',
          hasRecentTransactionsData: true,
          recentTransactions: [
            rust_sync.TransactionInfo(
              txidHex: reversedTxid,
              minedHeight: BigInt.zero,
              expiredUnmined: false,
              accountBalanceDelta: 0,
              fee: BigInt.zero,
              blockTime: BigInt.zero,
              isTransparent: false,
              txKind: 'sent',
              displayAmount: BigInt.one,
              displayPool: 'shielded',
              createdTime: BigInt.zero,
            ),
          ],
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(source.calls, 2);
      expect(find.text('Seen by the relay'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('background and account changes halt polling', (tester) async {
    final source = Source();
    await tester.pumpWidget(harness(source));
    await enable(tester);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(RelayFeedbackPanel)),
    );
    container
        .read(testSession.notifier)
        .change(
          const RelaySession(
            accountUuid: 'account',
            unlocked: true,
            foreground: false,
          ),
        );
    await tester.pump();
    await tester.pump(const Duration(seconds: 15));
    expect(source.calls, 1);
    container
        .read(testSession.notifier)
        .change(
          const RelaySession(
            accountUuid: 'other',
            unlocked: true,
            foreground: true,
          ),
        );
    await tester.pump();
    await tester.pump(const Duration(seconds: 15));
    expect(source.calls, 1);
    await tester.pumpWidget(const SizedBox());
  });
}
