import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/supabase_client.dart';
import '../data/calls_repository.dart';

/// Listens (app-wide) for inbound calls so an incoming-call banner can be
/// shown over whatever screen the user is on.
class CallsController extends ChangeNotifier {
  CallsController() {
    _authSub = supabase.auth.onAuthStateChange.listen((state) {
      if (state.session?.user.id == null) {
        _teardown();
      } else {
        _bind();
      }
    });
    if (supabase.auth.currentUser != null) _bind();
  }

  final _repo = CallsRepository();
  CallInfo? _incoming;
  RealtimeChannel? _channel;
  StreamSubscription<AuthState>? _authSub;

  CallInfo? get incoming => _incoming;

  void _bind() {
    _channel?.unsubscribe();
    _channel = _repo.subscribeIncoming((call) async {
      // enrich with the caller's name
      final caller = await _repo.profile(call.callerId);
      _incoming = CallInfo.fromRow({
        'id': call.id,
        'caller_id': call.callerId,
        'callee_id': call.calleeId,
        'kind': call.kind == CallKind.video ? 'video' : 'audio',
        'status': call.status,
        'channel': call.channel,
        'other_name': caller?.name ?? 'Someone',
      });
      notifyListeners();
    });
  }

  void clearIncoming() {
    _incoming = null;
    notifyListeners();
  }

  void _teardown() {
    _incoming = null;
    _channel?.unsubscribe();
    _channel = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _authSub?.cancel();
    _channel?.unsubscribe();
    super.dispose();
  }
}
