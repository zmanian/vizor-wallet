import '../../core/config/zcash_explorer.dart';

final _hash = RegExp(r'^[0-9a-f]{64}$');

/// Empty or invalid configuration disables the experiment without networking.
Uri? relayEndpoint(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null || uri.host.isEmpty || uri.userInfo.isNotEmpty ||
      uri.hasQuery || uri.hasFragment) return null;
  final loopback = uri.host == '127.0.0.1' || uri.host == '::1';
  if (uri.scheme != 'https' && !(uri.scheme == 'http' && loopback)) return null;
  return uri;
}

class RelayTransaction {
  const RelayTransaction._(this.network, this.txid);

  factory RelayTransaction.fromWallet({required String networkName,
    required String txidHex, required ZcashExplorerTxidOrder order}) {
    final network = switch (networkName) {
      'main' || 'mainnet' => 'mainnet',
      'test' || 'testnet' => 'testnet',
      _ => throw const FormatException('Unsupported relay network'),
    };
    final txid = zcashDisplayTxidHex(txidHex, order);
    if (!_hash.hasMatch(txid)) throw const FormatException('Invalid transaction ID');
    return RelayTransaction._(network, txid);
  }

  final String network;
  final String txid;
  @override
  bool operator ==(Object other) => other is RelayTransaction &&
      network == other.network && txid == other.txid;
  @override
  int get hashCode => Object.hash(network, txid);
}

enum RelayStatus { notObserved, pending, included, expired, unavailable }

class RelayForecast {
  const RelayForecast({required this.status, required this.asOfMs,
    this.tipHash, this.tipHeight, this.withinBlocks});

  factory RelayForecast.fromJson(Map<String, Object?> json, {
    required RelayTransaction transaction, required int nowMs,
  }) {
    final at = json['as_of_ms'];
    if (json['network'] != transaction.network || json['txid'] != transaction.txid ||
        at is! int || at < 0 || nowMs - at > 15000 || at - nowMs > 5000) {
      throw const FormatException('Mismatched or stale relay response');
    }
    final status = switch (json['status']) {
      'not_observed' => RelayStatus.notObserved,
      'announcement_only' || 'observed_pending' || 'forecast' => RelayStatus.pending,
      'included' => RelayStatus.included,
      'expired' => RelayStatus.expired,
      _ => RelayStatus.unavailable,
    };
    final tip = json['tip_hash'];
    final height = json['tip_height'];
    final model = json['model'];
    List<double>? probabilities;
    if (json['status'] == 'forecast' && json['shadow'] == false &&
        model is Map && model['validated'] == true && model['synthetic'] == false &&
        model['model_id'] is String && (model['model_id'] as String).isNotEmpty &&
        tip is String && _hash.hasMatch(tip) && height is int && height >= 0) {
      final values = json['probabilities'];
      if (values is Map) {
        final raw = [values['within_1'], values['within_2'], values['within_3']];
        if (raw.every((p) => p is num && p.isFinite && p >= 0 && p <= 1)) {
          final p = raw.cast<num>().map((p) => p.toDouble()).toList();
          if (p[0] <= p[1] && p[1] <= p[2]) probabilities = List.unmodifiable(p);
        }
      }
    }
    return RelayForecast(status: status, asOfMs: at,
      tipHash: tip is String && _hash.hasMatch(tip) ? tip : null,
      tipHeight: height is int && height >= 0 ? height : null,
      withinBlocks: probabilities);
  }

  final RelayStatus status;
  final int asOfMs;
  final String? tipHash;
  final int? tipHeight;
  final List<double>? withinBlocks;

  String get headline => switch (status) {
    RelayStatus.notObserved => 'Not yet seen by the relay',
    RelayStatus.pending => 'Seen by the relay',
    RelayStatus.included => 'Inclusion reported',
    RelayStatus.expired => 'Expiry reported',
    RelayStatus.unavailable => 'Network feedback unavailable',
  };

  String get detail => switch (status) {
    RelayStatus.notObserved => 'This does not mean the transaction failed. The wallet continues tracking it.',
    RelayStatus.pending => 'Waiting for inclusion. The wallet verifies confirmation independently.',
    RelayStatus.included => 'The relay reports a block inclusion. Check the wallet status for confirmation.',
    RelayStatus.expired => 'The wallet must verify expiry before you send again.',
    RelayStatus.unavailable => 'The wallet continues tracking your transaction normally.',
  };
}
