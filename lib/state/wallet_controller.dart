import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/supabase_client.dart';
import '../core/utils/ids.dart';
import '../data/models.dart';

/// Real Supabase-backed wallet. Balance and history come from `wallets` /
/// `wallet_ledger` and update live via Realtime — the client never mutates
/// either directly (no RLS write path exists for them); every change goes
/// through a server-side function (`send_gift`, `request_withdrawal`, …).
class WalletController extends ChangeNotifier {
  WalletController() {
    _loadCatalog();
    _authSub = supabase.auth.onAuthStateChange.listen((state) {
      final uid = state.session?.user.id;
      if (uid == _profileId) return;
      _profileId = uid;
      if (uid != null) {
        _bindWallet(uid);
      } else {
        _clearWallet();
      }
    });
    final currentUid = supabase.auth.currentUser?.id;
    if (currentUid != null) {
      _profileId = currentUid;
      _bindWallet(currentUid);
    } else {
      _loading = false;
    }
  }

  int _coins = 0;
  int _diamonds = 0;
  List<WalletTx> _tx = const [];
  List<Gift> _gifts = const [];
  List<CoinPack> _coinPacks = const [];
  bool _loading = true;
  String? _profileId;
  StreamSubscription<AuthState>? _authSub;
  RealtimeChannel? _walletChannel;

  int get coins => _coins;
  int get diamonds => _diamonds;
  double get earningsInr => _diamonds * 0.82; // fake conversion rate
  bool get loading => _loading;
  List<WalletTx> get transactions => List.unmodifiable(_tx);
  List<Gift> get gifts => List.unmodifiable(_gifts);
  List<CoinPack> get coinPacks => List.unmodifiable(_coinPacks);

  bool canAfford(int price) => _coins >= price;

  Future<void> _loadCatalog() async {
    final giftRows = await supabase.from('gifts').select().eq('status', 'active').order('sort_order');
    final packRows = await supabase.from('coin_packages').select().eq('status', 'active').order('sort_order');
    _gifts = giftRows.map(Gift.fromRow).toList();
    _coinPacks = List.generate(
      packRows.length,
      (i) => CoinPack.fromRow(packRows[i], popular: i == packRows.length ~/ 2),
    );
    notifyListeners();
  }

  Future<void> _bindWallet(String uid) async {
    _loading = true;
    notifyListeners();

    final walletRow = await supabase.from('wallets').select().eq('profile_id', uid).maybeSingle();
    if (walletRow != null) {
      _coins = (walletRow['coins'] as num).toInt();
      _diamonds = (walletRow['diamonds'] as num).toInt();
    }

    final ledgerRows = await supabase
        .from('wallet_ledger')
        .select()
        .eq('profile_id', uid)
        .order('created_at', ascending: false)
        .limit(50);
    _tx = ledgerRows.map(WalletTx.fromLedgerRow).toList();

    await _walletChannel?.unsubscribe();
    _walletChannel = supabase
        .channel('wallet-$uid')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'wallets',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'profile_id', value: uid),
          callback: (payload) {
            _coins = (payload.newRecord['coins'] as num).toInt();
            _diamonds = (payload.newRecord['diamonds'] as num).toInt();
            notifyListeners();
          },
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'wallet_ledger',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'profile_id', value: uid),
          callback: (payload) {
            _tx = [WalletTx.fromLedgerRow(payload.newRecord), ..._tx];
            notifyListeners();
          },
        )
        .subscribe();

    _loading = false;
    notifyListeners();
  }

  void _clearWallet() {
    _coins = 0;
    _diamonds = 0;
    _tx = const [];
    _loading = false;
    unawaited(_walletChannel?.unsubscribe());
    _walletChannel = null;
    notifyListeners();
  }

  /// Sends [gift] to [receiver] — server-authoritative via the `send_gift`
  /// Postgres function. [receiver] must be a real signed-up profile; demo
  /// hosts (mock data, not yet backed by a real account) are rejected with a
  /// clear error rather than silently no-op'ing or crashing on a bad UUID.
  Future<void> sendGift(Gift gift, AppUser receiver, {String? liveStreamId}) async {
    if (!isRealId(receiver.id)) {
      throw Exception("${receiver.name} is a demo host — gifts can't be sent yet.");
    }
    await supabase.rpc('send_gift', params: {
      'p_gift_id': gift.id,
      'p_receiver_id': receiver.id,
      'p_live_stream_id': liveStreamId,
    });
  }

  /// ALPHA: no real payment gateway yet, so this credits the pack's coins
  /// server-side via `dev_purchase_coins` (writes a `wallet_ledger` purchase
  /// row; the balance updates over Realtime). Swap for a real
  /// gateway + webhook before production.
  Future<void> buyCoins(CoinPack pack) async {
    await supabase.rpc('dev_purchase_coins', params: {'p_package_id': pack.id});
  }

  Future<void> withdraw(int diamonds) async {
    await supabase.rpc('request_withdrawal', params: {'p_diamonds': diamonds});
  }

  @override
  void dispose() {
    _authSub?.cancel();
    _walletChannel?.unsubscribe();
    super.dispose();
  }
}
