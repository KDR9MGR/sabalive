import '../config/supabase_client.dart';

/// Our merchant identity at the Tulasi game platform. It appears in every game URL, so it is not a secret.
const int kTulasiMerchantId = 1503251;

/// Where the games live unless the platform sent a different domain for a game.
const String kTulasiDefaultGameDomain = 'https://gamesp.tulasigame.com/';

/// The platform's room id (it asked for 111 for now).
const int kTulasiRoomId = 111;

/// One game the platform authorised for us (the `merchant_games` table, filled by the `tulasi` Edge Function).
class MerchantGame {
  const MerchantGame({
    required this.id,
    required this.name,
    this.identification,
    this.imageUrl,
    this.description,
    this.gameDomain,
  });

  factory MerchantGame.fromRow(Map<String, dynamic> row) => MerchantGame(
        id: (row['id'] as num).toInt(),
        name: (row['name'] as String?)?.trim() ?? '',
        identification: _clean(row['identification']),
        imageUrl: _clean(row['image_url']),
        description: _clean(row['description']),
        gameDomain: _clean(row['game_domain']),
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

  /// Can it be opened at all (it needs a path)?
  bool get launchable => identification != null;
}

/// A launch: the one-time token the platform will present back to us, and our permanent numeric player id.
class GameSession {
  const GameSession({required this.token, required this.uid});

  factory GameSession.fromJson(Map<String, dynamic> j) =>
      GameSession(token: j['token'] as String, uid: (j['uid'] as num).toInt());

  final String token;
  final int uid;
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
  /// The enabled games, in the platform's order.
  Future<List<MerchantGame>> games() async {
    // status 1 = on in Tulasi's dashboard; hidden = switched off on OUR side from the panel's Games page (a Sync never changes it)
    final rows = await supabase.from('merchant_games').select().eq('status', 1).eq('hidden', false).order('sort_order', ascending: true);
    return [
      for (final r in rows)
        if ((r['name'] as String?)?.trim().isNotEmpty == true) MerchantGame.fromRow(r),
    ];
  }

  /// Starts a launch (the server checks the person is 18+, not a ghost, and that games are on).
  Future<GameSession> start(MerchantGame game) async {
    final j = await supabase.rpc('start_game_session', params: {'p_game_id': '${game.id}'});
    return GameSession.fromJson(Map<String, dynamic>.from(j as Map));
  }
}
