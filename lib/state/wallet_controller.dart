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
  int _adminCoins = 0;
  List<WalletTx> _tx = const [];
  List<Gift> _gifts = const [];
  List<CoinPack> _coinPacks = const [];
  bool _loading = true;
  String? _profileId;
  StreamSubscription<AuthState>? _authSub;
  RealtimeChannel? _walletChannel;

  int get coins => _coins;
  int get diamonds => _diamonds;
  /// Coins actually granted by the admin panel — excludes self-purchase
  /// and coin-seller/reseller transfers. Display-only, for Wallet &
  /// Earnings; [coins] (the real, true spendable balance every RPC
  /// checks against) is unaffected.
  int get adminCoins => _adminCoins;
  double get earningsInr => _diamonds * 0.82; // fake conversion rate
  bool get loading => _loading;
  List<WalletTx> get transactions => List.unmodifiable(_tx);
  List<Gift> get gifts => List.unmodifiable(_gifts);
  List<CoinPack> get coinPacks => List.unmodifiable(_coinPacks);

  /// The gift with this id from the loaded catalog, or null when it isn't
  /// there (retired since the catalog loaded). Lets a room screen turn the
  /// gift_id on a chat row into the gift to play.
  Gift? giftById(String id) {
    for (final g in _gifts) {
      if (g.id == id) return g;
    }
    return null;
  }

  bool canAfford(int price) => _coins >= price;

  DateTime? _catalogAt;

  Future<void> _loadCatalog() async {
    final giftRows = await supabase.from('gifts').select().eq('status', 'active').order('sort_order', ascending: true);
    final packRows = await supabase.from('coin_packages').select().eq('status', 'active').order('sort_order', ascending: true);
    _gifts = giftRows.map(Gift.fromRow).toList();
    _coinPacks = List.generate(
      packRows.length,
      (i) => CoinPack.fromRow(packRows[i], popular: i == packRows.length ~/ 2),
    );
    _catalogAt = DateTime.now();
    notifyListeners();
  }

  /// Reads the gift catalog again if it is older than [maxAge]. It was only read when the app started, so a
  /// gift added or changed in the panel (new artwork, speed, sound) did not reach a phone until it restarted,
  /// and a viewer could not play a new gift that someone else sent. Called when a live opens. Never throws.
  Future<void> refreshCatalog({Duration maxAge = const Duration(minutes: 5)}) async {
    final at = _catalogAt;
    if (at != null && DateTime.now().difference(at) < maxAge) return;
    try {
      await _loadCatalog();
    } catch (_) {/* keep the catalog we have */}
  }

  /// Wallet & Earnings' Transaction History excludes these same kinds, so
  /// the list never contradicts [adminCoins] sitting above it.
  static const _nonAdminKinds = {'purchase', 'transfer_in', 'transfer_out'};
  static const _nonAdminKindsFilter = '(purchase,transfer_in,transfer_out)';

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
        .not('kind', 'in', _nonAdminKindsFilter)
        .order('created_at', ascending: false)
        .limit(50);
    _tx = ledgerRows.map(WalletTx.fromLedgerRow).toList();
    await _refreshAdminCoins();

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
            final kind = payload.newRecord['kind'] as String?;
            if (kind != null && !_nonAdminKinds.contains(kind)) {
              _tx = [WalletTx.fromLedgerRow(payload.newRecord), ..._tx];
            }
            unawaited(_refreshAdminCoins());
            notifyListeners();
          },
        )
        .subscribe();

    _loading = false;
    notifyListeners();
  }

  Future<void> _refreshAdminCoins() async {
    try {
      final v = await supabase.rpc('admin_granted_coin_balance');
      _adminCoins = (v as num).toInt();
    } catch (_) {
      /* best-effort — the real balance elsewhere is unaffected */
    }
  }

  void _clearWallet() {
    _coins = 0;
    _diamonds = 0;
    _adminCoins = 0;
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

  /// Sends [gift] to everyone in the room as ONE server action (`send_gift_to_all`): the host and whoever is
  /// on a seat, never the sender. The server charges price x people up front, so it either all goes or none
  /// of it does, and the room gets a single "sent (gift) to All" line. Returns how many people got it.
  ///
  /// If the backend doesn't have the function yet (an app newer than the database), it falls back to
  /// sending one gift per person in [fallbackRecipients].
  Future<int> sendGiftToAll(
    Gift gift, {
    required String liveStreamId,
    required List<AppUser> fallbackRecipients,
  }) async {
    try {
      final n = await supabase.rpc('send_gift_to_all', params: {
        'p_gift_id': gift.id,
        'p_live_stream_id': liveStreamId,
      });
      return (n as num?)?.toInt() ?? 0;
    } catch (e) {
      if (!isMissingFunction(e)) rethrow;
    }
    final me = supabase.auth.currentUser?.id;
    var sent = 0;
    for (final r in fallbackRecipients) {
      if (r.id == me) continue;
      await sendGift(gift, r, liveStreamId: liveStreamId);
      sent++;
    }
    return sent;
  }

  /// The database has no function with that name (yet): PostgREST code PGRST202 / Postgres 42883.
  @visibleForTesting
  static bool isMissingFunction(Object e) {
    if (e is PostgrestException) {
      return e.code == 'PGRST202' ||
          e.code == '42883' ||
          e.message.contains('Could not find the function');
    }
    return false;
  }

  /// ALPHA: no real payment gateway yet, so this credits the pack's coins
  /// server-side via `dev_purchase_coins` (writes a `wallet_ledger` purchase
  /// row; the balance updates over Realtime). Swap for a real
  /// gateway + webhook before production.
  Future<void> buyCoins(CoinPack pack) async {
    await supabase.rpc('dev_purchase_coins', params: {'p_package_id': pack.id});
  }

  @override
  void dispose() {
    _authSub?.cancel();
    _walletChannel?.unsubscribe();
    super.dispose();
  }
}
