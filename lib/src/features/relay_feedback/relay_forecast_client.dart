import 'dart:convert';
import 'dart:async';
import '../../core/network/network_http_client.dart';
import 'relay_forecast.dart';

abstract interface class RelayForecastSource {
  Future<RelayForecast> fetch(
    RelayTransaction transaction, {
    Future<void>? cancelSignal,
  });
}

class RelayForecastClient implements RelayForecastSource {
  RelayForecastClient({
    required this.endpoint,
    NetworkHttpClient? transport,
    int Function()? clock,
  }) : _transport = transport ?? NetworkHttpClient(),
       _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch) {
    if (relayEndpoint(endpoint.toString()) == null) {
      throw const FormatException('Invalid relay endpoint');
    }
  }

  final Uri endpoint;
  final NetworkHttpClient _transport;
  final int Function() _clock;

  @override
  Future<RelayForecast> fetch(
    RelayTransaction transaction, {
    Future<void>? cancelSignal,
  }) async {
    final cancel = Completer<void>();
    void cancelRequest() {
      if (!cancel.isCompleted) cancel.complete();
    }

    if (cancelSignal != null) {
      unawaited(
        cancelSignal.then(
          (_) => cancelRequest(),
          onError: (_) => cancelRequest(),
        ),
      );
    }
    final NetworkHttpResponse response;
    try {
      response = await _transport
          .request(
            'POST',
            endpoint,
            headers: const {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            bodyBytes: utf8.encode(
              jsonEncode({
                'network': transaction.network,
                'txid': transaction.txid,
              }),
            ),
            timeout: const Duration(seconds: 3),
            cancelSignal: cancel.future,
            followRedirects: false,
          )
          .timeout(const Duration(seconds: 3));
    } finally {
      // Includes Tor bootstrap wait and aborts the underlying request on timeout.
      cancelRequest();
    }
    if (response.statusCode != 200 || response.bodyBytes.length > 65536) {
      throw const FormatException('Relay response unavailable');
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('Invalid relay response');
    }
    return RelayForecast.fromJson(
      decoded,
      transaction: transaction,
      nowMs: _clock(),
    );
  }

  void close() => _transport.close(force: true);
}
