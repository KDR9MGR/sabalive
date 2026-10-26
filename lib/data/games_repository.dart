import 'package:flutter/foundation.dart';

import '../config/supabase_client.dart';

/// Our merchant identity at the Tulasi game platform. It appears in every game URL, so it is not a secret.
const int kTulasiMerchantId = 1503251;

/// Where the games live unless the platform sent a different domain for a game.
const String kTulasiDefaultGameDomain = 'https://gamesp.tulasigame.com/';

/// The platform's room id (it asked for 111 for now).
const int kTulasiRoomId = 111;

/// Who runs a game: Tulasi (a game URL we open) or SUD (its web SDK, in a page of ours, see `supabase/functions/sud`).
enum GameProvider { tulasi, sud }

/// One game we can open: a Tulasi game (the `merchant_games` table, filled by the `tulasi` Edge Function) or a SUD game (`sud_games`, kept from the panel).
class MerchantGame {
  const MerchantGame({
    required this.id,
    required this.name,
    this.identification,
    this.imageUrl,
    this.description,
    this.gameDomain,
    this.provider = GameProvider.tulasi,
    this.aspect,
    this.usesCoins = false,
  });

  factory MerchantGame.fromRow(Map<String, dynamic> row) => MerchantGame(
        id: (row['id'] as num).toInt(),
        name: (row['name'] as String?)?.trim() ?? '',
        identification: _clean(row['identification']),
        imageUrl: _clean(row['image_url']),
        description: _clean(row['description']),
        gameDomain: _clean(row['game_domain']),
      );

  /// A row of `sud_games`. Its id starts at 1,000,000 so it never meets a Tulasi id in the one merged list; the game's own id stays in the path-like
  /// [identification] (`sud-<SUD game id>`), which is also where the page size is remembered.
  factory MerchantGame.fromSudRow(Map<String, dynamic> row) => MerchantGame(
        id: (row['id'] as num).toInt(),
        name: (row['name'] as String?)?.trim() ?? '',
        identification: 'sud-${row['provider_game_id']}',
        imageUrl: _clean(row['image_url']),
        description: _clean(row['description']),
        provider: GameProvider.sud,
        aspect: (row['aspect'] as num?)?.toDouble(),
        usesCoins: row['uses_coins'] == true,
      );

  static String? _clean(Object? v) {
    final s = v is String ? v.trim() : null;
    return s == null || s.isEmpty ? null : s;
  }

  final int id;
  final String name;

  /// The game's path in its URL, e.g. `kingdoms`.
  final String? identification;
  final String? imageUrl;
  final String? description;

  /// A domain the platform sent for this game (a custom one); null = the default.
  final String? gameDomain;

  final GameProvider provider;

  /// A SUD game's height / width (from SUD's minimum-size table): its page has no Cocos engine to measure, so the panel starts at, and keeps, this.
  final double? aspect;

  /// Whether players stake wallet coins in it (a SUD coin game; every Tulasi game does).
  final bool usesCoins;

  bool get isSud => provider == GameProvider.sud;

  /// Can it be opened at all (it needs a path)?
  bool get launchable => identification != null;
}

/// A launch: for a Tulasi game the one-time token the platform will present back to us and our permanent numeric player id; for a SUD game the ready address
/// of our game page (it carries the one-time login code) and the game's proportions.
class GameSession {
  const GameSession({required this.token, required this.uid, this.url, this.aspect});

  factory GameSession.fromJson(Map<String, dynamic> j) =>
      GameSession(token: j['token'] as String, uid: (j['uid'] as num).toInt());

  /// The answer of the `sud` function's `launch` route: `{ url, aspect, ... }`.
  factory GameSession.fromSud(Map<dynamic, dynamic> j) {
    final raw = j['url'];
    final url = raw is String ? Uri.tryParse(raw) : null;
    if (url == null || url.scheme != 'https' || url.host.isEmpty) throw Exception('This game is not available right now');
    return GameSession(token: '', uid: 0, url: url, aspect: (j['aspect'] as num?)?.toDouble());
  }

  final String token;
  final int uid;

  /// Set for a SUD game: open exactly this address.
  final Uri? url;
  final double? aspect;
}

/// The domain to open a game on: the game's own if it is a proper https domain, else the default. Always ends with `/`.
String gameDomainFor(MerchantGame game) {
  final custom = game.gameDomain;
  if (custom != null) {
    final u = Uri.tryParse(custom);
    if (u != null && u.scheme == 'https' && u.host.contains('.') && u.userInfo.isEmpty) {
      return custom.endsWith('/') ? custom : '$custom/';
    }
  }
  return kTulasiDefaultGameDomain;
}

/// The complete game URL: `<domain><identification>/?merchant=..&gameId=..&lang=..&isLandscape=..&roomId=..&token=..`.
/// The platform wants every parameter kept as it is. Never log this: it carries the token.
Uri buildGameUrl(MerchantGame game, String token, {String lang = 'en', bool landscape = false}) {
  final base = Uri.parse(gameDomainFor(game));
  final path = '${base.path.endsWith('/') ? base.path : '${base.path}/'}${game.identification}/';
  return base.replace(
    path: path,
    queryParameters: {
      'merchant': '$kTulasiMerchantId',
      'gameId': '${game.id}',
      'lang': lang,
      'isLandscape': '$landscape',
      'roomId': '$kTulasiRoomId',
      'token': token,
    },
  );
}

/// What a game page may navigate to, and what its `tulasigame://` messages mean.
enum GameNavigation { allow, exit, recharge, block }

/// Decides one navigation of the game's WebView. [gameHost] is the host the game was opened on.
GameNavigation decideGameNavigation(String url, {required String gameHost}) {
  final u = Uri.tryParse(url);
  if (u == null) return GameNavigation.block;
  if (u.scheme == 'tulasigame') {
    return switch (u.host) {
      'exit' => GameNavigation.exit,
      'recharge' => GameNavigation.recharge,
      _ => GameNavigation.block,
    };
  }
  if (u.scheme == 'about' || u.scheme == 'blob' || u.scheme == 'data') return GameNavigation.allow;
  if (u.scheme != 'https') return GameNavigation.block;
  final h = u.host.toLowerCase();
  if (h == gameHost.toLowerCase() || h == 'tulasigame.com' || h.endsWith('.tulasigame.com')) return GameNavigation.allow;
  return GameNavigation.block;
}

class GamesRepository {
  GamesRepository({@visibleForTesting Future<dynamic> Function(String function, Map<String, dynamic> body)? invoke})
      : _invoke = invoke ?? _invokeFunction;

  final Future<dynamic> Function(String function, Map<String, dynamic> body) _invoke;

  static Future<dynamic> _invokeFunction(String function, Map<String, dynamic> body) async =>
      (await supabase.functions.invoke(function, body: body)).data;

  /// The enabled games: Tulasi's in the platform's order, then SUD's in the panel's order.
  Future<List<MerchantGame>> games() async {
    // status 1 = on in Tulasi's dashboard; hidden = switched off on OUR side from the panel's Games page (a Sync never changes it)
    final rows = await supabase.from('merchant_games').select().eq('status', 1).eq('hidden', false).order('sort_order', ascending: true);
    return [
      for (final r in rows)
        if ((r['name'] as String?)?.trim().isNotEmpty == true) MerchantGame.fromRow(r),
      ...await _sudGames(),
    ];
  }

  /// SUD's games. Never fails the list: a server without the table (or a read that fails) simply has no SUD games, and Tulasi's still show.
  Future<List<MerchantGame>> _sudGames() async {
    try {
      final rows = await supabase.from('sud_games').select().eq('status', 1).eq('hidden', false).order('sort_order', ascending: true).order('id', ascending: true);
      return [
        for (final r in rows)
          if ((r['name'] as String?)?.trim().isNotEmpty == true && r['provider_game_id'] != null) MerchantGame.fromSudRow(Map<String, dynamic>.from(r)),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// Starts a launch. A Tulasi launch is checked on the server (18+, not a ghost, games on). A SUD launch goes through the `sud` function, which asks the
  /// database the same questions (and, for a coin game, the coin switch), mints the login code and answers with the address of our game page.
  /// [roomId] is the live the person is in, so everyone in that live plays together; without one the table is the person's own. [lang] is the app language.
  Future<GameSession> start(MerchantGame game, {String? roomId, String lang = 'en'}) async {
    if (game.isSud) {
      final data = await _invoke('sud/launch', {'gameId': game.id, if (roomId != null && roomId.isNotEmpty) 'roomId': roomId, 'lang': lang});
      if (data is! Map) throw Exception('This game is not available right now');
      return GameSession.fromSud(data);
    }
    final j = await supabase.rpc('start_game_session', params: {'p_game_id': '${game.id}'});
    return GameSession.fromJson(Map<String, dynamic>.from(j as Map));
  }
}
