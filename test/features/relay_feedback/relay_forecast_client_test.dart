import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/config/zcash_explorer.dart';
import 'package:zcash_wallet/src/core/network/network_http_client.dart';
import 'package:zcash_wallet/src/features/relay_feedback/relay_forecast.dart';
import 'package:zcash_wallet/src/features/relay_feedback/relay_forecast_client.dart';
import 'relay_forecast_test.dart' show txid, nowMs, forecastFixture;

class Bridge implements TorHttpBridge {
  Map<String, Object?>? body;
  bool fail = false;
  int calls = 0;
  int? redirect;
  bool hang = false;
  final cancellation = Completer<void>();
  @override
  Future<NetworkHttpResponse> post(
    Uri uri, {
    required Map<String, String> headers,
    required List<int> bodyBytes,
    required Duration? timeout,
    Future<void>? cancelSignal,
  }) async {
    calls++;
    cancelSignal?.then((_) {
      if (!cancellation.isCompleted) cancellation.complete();
    });
    if (hang) return Completer<NetworkHttpResponse>().future;
    if (redirect != null && calls == 1) {
      return NetworkHttpResponse(
        statusCode: redirect!,
        bodyBytes: Uint8List(0),
        headers: {
          'location': ['https://other.example/collect'],
        },
      );
    }
    body = jsonDecode(utf8.decode(bodyBytes)) as Map<String, Object?>;
    if (fail) throw StateError('Tor unavailable');
    return NetworkHttpResponse(
      statusCode: 200,
      bodyBytes: Uint8List.fromList(utf8.encode(jsonEncode(forecastFixture()))),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'a Tor bootstrap stall has an outer deadline and cancellation',
    () async {
      final bridge = Bridge()..hang = true;
      final client = RelayForecastClient(
        endpoint: Uri.parse('https://relay.example/v1/forecast'),
        transport: NetworkHttpClient(
          torDesired: () => true,
          torBootstrapping: () => true,
          torBridge: bridge,
        ),
      );
      addTearDown(client.close);
      await expectLater(
        client.fetch(
          RelayTransaction.fromWallet(
            networkName: 'main',
            txidHex: txid,
            order: ZcashExplorerTxidOrder.display,
          ),
        ),
        throwsA(isA<TimeoutException>()),
      );
      await bridge.cancellation.future.timeout(const Duration(seconds: 1));
    },
  );

  for (final code in [301, 302, 303, 307, 308]) {
    test('Tor relay does not follow $code to another host', () async {
      final bridge = Bridge()..redirect = code;
      final client = RelayForecastClient(
        endpoint: Uri.parse('https://relay.example/v1/forecast'),
        transport: NetworkHttpClient(
          torDesired: () => true,
          torBootstrapping: () => false,
          torBridge: bridge,
        ),
        clock: () => nowMs,
      );
      addTearDown(client.close);
      await expectLater(
        client.fetch(
          RelayTransaction.fromWallet(
            networkName: 'main',
            txidHex: txid,
            order: ZcashExplorerTxidOrder.display,
          ),
        ),
        throwsFormatException,
      );
      expect(bridge.calls, 1);
    });
  }
  test('direct relay does not follow a redirect', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final requests = <String>[];
    server.listen((request) async {
      requests.add(request.uri.path);
      request.response.statusCode = 303;
      request.response.headers.set('location', '/another');
      await request.response.close();
    });
    final client = RelayForecastClient(
      endpoint: Uri.parse('http://127.0.0.1:${server.port}/v1/forecast'),
      transport: NetworkHttpClient(torDesired: () => false),
    );
    addTearDown(client.close);
    await expectLater(
      client.fetch(
        RelayTransaction.fromWallet(
          networkName: 'main',
          txidHex: txid,
          order: ZcashExplorerTxidOrder.display,
        ),
      ),
      throwsFormatException,
    );
    expect(requests, ['/v1/forecast']);
  });

  test(
    'uses routed POST with only canonical ID and network; Tor failure propagates',
    () async {
      final bridge = Bridge();
      final transport = NetworkHttpClient(
        torDesired: () => true,
        torBootstrapping: () => false,
        torBridge: bridge,
      );
      final client = RelayForecastClient(
        endpoint: Uri.parse('https://relay.example/v1/forecast'),
        transport: transport,
        clock: () => nowMs,
      );
      addTearDown(client.close);
      final transaction = RelayTransaction.fromWallet(
        networkName: 'main',
        txidHex: txid,
        order: ZcashExplorerTxidOrder.display,
      );
      expect((await client.fetch(transaction)).status, RelayStatus.pending);
      expect(bridge.body, {'network': 'mainnet', 'txid': txid});
      bridge.fail = true;
      await expectLater(client.fetch(transaction), throwsStateError);
    },
  );
}
