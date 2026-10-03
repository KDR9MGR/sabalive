import 'dart:convert';

import 'package:http/http.dart' as http;

/// Watches every API response for the server's maintenance refusal (HTTP 503 with
/// "MAINTENANCE_MODE") and tells [onRefused] — so the app locks the moment any
/// request is turned away, even if the status it last read said otherwise. The
/// response is passed on unchanged.
class MaintenanceAwareClient extends http.BaseClient {
  MaintenanceAwareClient(this._inner, this.onRefused);

  final http.Client _inner;
  final void Function(Map<dynamic, dynamic> details) onRefused;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await _inner.send(request);
    if (response.statusCode != 503) return response;

    // Only a 503 is read (and handed on again), so everything else streams as usual.
    final bytes = await response.stream.toBytes();
    final details = parseMaintenanceRefusal(utf8.decode(bytes, allowMalformed: true));
    if (details != null) onRefused(details);
    return http.StreamedResponse(
      Stream.value(bytes),
      response.statusCode,
      contentLength: bytes.length,
      request: response.request,
      headers: response.headers,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }

  @override
  void close() => _inner.close();
}

/// If [body] is the gate's refusal, its `details` (status, title, message,
/// ends_at, server_time); otherwise null.
Map<dynamic, dynamic>? parseMaintenanceRefusal(String body) {
  try {
    final json = jsonDecode(body);
    if (json is! Map || json['message'] != 'MAINTENANCE_MODE') return null;
    final details = json['details'];
    if (details is Map) return details;
    if (details is String) {
      final parsed = jsonDecode(details);
      if (parsed is Map) return parsed;
    }
    // refused, but without the details: still maintenance
    return {'status': 'maintenance'};
  } catch (_) {
    return null;
  }
}
