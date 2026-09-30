import 'dart:async';
import 'dart:convert';
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
  @override
  Future<NetworkHttpResponse> post(Uri uri, {required Map<String, String> headers,
    required List<int> bodyBytes, required Duration? timeout, Future<void>? cancelSignal}) async {
    body = jsonDecode(utf8.decode(bodyBytes)) as Map<String, Object?>;
    if (fail) throw StateError('Tor unavailable');
    return NetworkHttpResponse(statusCode: 200,
      bodyBytes: Uint8List.fromList(utf8.encode(jsonEncode(forecastFixture()))));
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('uses routed POST with only canonical ID and network; Tor failure propagates', () async {
    final bridge = Bridge();
    final transport = NetworkHttpClient(torDesired: () => true,
      torBootstrapping: () => false, torBridge: bridge);
    final client = RelayForecastClient(endpoint: Uri.parse('https://relay.example/v1/forecast'),
      transport: transport, clock: () => nowMs);
    addTearDown(client.close);
    final transaction = RelayTransaction.fromWallet(networkName: 'main', txidHex: txid,
      order: ZcashExplorerTxidOrder.display);
    expect((await client.fetch(transaction)).status, RelayStatus.pending);
    expect(bridge.body, {'network': 'mainnet', 'txid': txid});
    bridge.fail = true;
    await expectLater(client.fetch(transaction), throwsStateError);
  });
}
