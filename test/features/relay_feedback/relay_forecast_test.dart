import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/config/zcash_explorer.dart';
import 'package:zcash_wallet/src/features/relay_feedback/relay_forecast.dart';

const txid = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const reversedTxid =
    'efcdab8967452301efcdab8967452301efcdab8967452301efcdab8967452301';
const nowMs = 1800000000000;

Map<String, Object?> forecastFixture({String status = 'forecast'}) => {
  'network': 'mainnet',
  'txid': txid,
  'as_of_ms': nowMs,
  'tip_hash': 'a' * 64,
  'tip_height': 3500000,
  'status': status,
  'shadow': true,
  'model': {'validated': false, 'synthetic': false, 'model_id': 'research'},
  'probabilities': {'within_1': .8, 'within_2': .9, 'within_3': .95},
};

void main() {
  final transaction = RelayTransaction.fromWallet(
    networkName: 'main',
    txidHex: txid,
    order: ZcashExplorerTxidOrder.display,
  );
  RelayForecast parse(Map<String, Object?> json) =>
      RelayForecast.fromJson(json, transaction: transaction, nowMs: nowMs);

  test('converts history IDs once and refuses unsupported networks', () {
    expect(
      RelayTransaction.fromWallet(
        networkName: 'test',
        txidHex: reversedTxid,
        order: ZcashExplorerTxidOrder.protocol,
      ).txid,
      txid,
    );
    expect(
      RelayTransaction.fromWallet(
        networkName: 'test',
        txidHex: txid,
        order: ZcashExplorerTxidOrder.display,
      ).network,
      'testnet',
    );
    expect(
      () => RelayTransaction.fromWallet(
        networkName: 'regtest',
        txidHex: txid,
        order: ZcashExplorerTxidOrder.display,
      ),
      throwsFormatException,
    );
    expect(
      () => RelayTransaction.fromWallet(
        networkName: 'main',
        txidHex: 'oops',
        order: ZcashExplorerTxidOrder.display,
      ),
      throwsFormatException,
    );
  });

  test(
    'permits HTTPS or numeric loopback tunnels without query credentials',
    () {
      expect(relayEndpoint(''), isNull);
      expect(
        relayEndpoint('https://relay.example/v1/forecast')?.host,
        'relay.example',
      );
      expect(relayEndpoint('http://127.0.0.1:18790/v1/forecast')?.port, 18790);
      for (final bad in [
        'http://relay.example/v1/forecast',
        'https://key@relay.example/v1/forecast',
        'https://relay.example/?key=secret',
        'https://relay.example/#secret',
        'file:///tmp/api',
      ]) {
        expect(relayEndpoint(bad), isNull, reason: bad);
      }
    },
  );

  test('research forecasts establish observation but expose no percentage', () {
    final result = parse(forecastFixture());
    expect(result.status, RelayStatus.pending);
    expect(result.withinBlocks, isNull);
    expect(result.headline, 'Seen by the relay');
  });

  test('only a fresh validated non-shadow model can expose probabilities', () {
    final json = forecastFixture()
      ..['shadow'] = false
      ..['model'] = {
        'validated': true,
        'synthetic': false,
        'model_id': 'validated',
      };
    expect(parse(json).withinBlocks, [.8, .9, .95]);
    for (final bad in [
      {'within_1': .9, 'within_2': .8, 'within_3': 1},
      {'within_1': -1, 'within_2': .9, 'within_3': 1},
      {'within_1': .8},
    ]) {
      expect(parse({...json, 'probabilities': bad}).withinBlocks, isNull);
    }
    expect(parse({...json, 'shadow': true}).withinBlocks, isNull);
  });

  test('wrong identities and stale or future responses are rejected', () {
    for (final change in [
      {'txid': reversedTxid},
      {'network': 'testnet'},
      {'as_of_ms': nowMs - 15001},
      {'as_of_ms': nowMs + 5001},
      {'as_of_ms': 'now'},
    ]) {
      expect(
        () => parse({...forecastFixture(), ...change}),
        throwsFormatException,
      );
    }
  });

  test(
    'unknown and stale evidence never becomes zero probability or failure',
    () {
      expect(
        parse(forecastFixture(status: 'not_observed')).status,
        RelayStatus.notObserved,
      );
      for (final status in [
        'stale',
        'insufficient_evidence',
        'unsupported',
        'unexpected',
      ]) {
        final result = parse(forecastFixture(status: status));
        expect(result.status, RelayStatus.unavailable);
        expect(result.withinBlocks, isNull);
      }
    },
  );

  test(
    'inclusion and expiry remain relay reports, not wallet confirmation',
    () {
      expect(
        parse(forecastFixture(status: 'included')).headline,
        'Inclusion reported',
      );
      expect(
        parse(forecastFixture(status: 'expired')).headline,
        'Expiry reported',
      );
      expect(parse(forecastFixture(status: 'included')).withinBlocks, isNull);
    },
  );
}
