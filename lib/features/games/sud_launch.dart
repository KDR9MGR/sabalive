import 'dart:convert';

/// Everything the native SUD game SDK needs to start one game, read from the address our `sud` Edge Function's `launch` route answers with.
///
/// That address was built for the old web page (SUD's web SDK; their test environment answers it with error 10005 for every game, and SUD says the web route is not available
/// for us, only Android and iOS), but it carries exactly the values the native SDK takes, so the server did not have to change: the app id, the app KEY (the SDK's public
/// client key; the app SECRET never leaves the server), the game id, the room, the person, the one-time login code, a longer-lived launch token for renewing that code, our
/// function's address and whether SUD's test environment is meant. Nothing here is logged or shown.
class SudLaunch {
  const SudLaunch({
    required this.appId,
    required this.appKey,
    required this.gameId,
    required this.roomId,
    required this.userId,
    required this.code,
    required this.launchToken,
    required this.api,
    required this.testEnv,
    required this.language,
  });

  final String appId;
  final String appKey;

  /// SUD's own game id: 19 digits, kept as TEXT (the native SDK reads it as a 64-bit number).
  final String gameId;
  final String roomId;
  final String userId;

  /// The one-time login code (valid two hours); [launchToken] is what renews it.
  final String code;
  final String launchToken;

  /// `https://<project>.supabase.co/functions/v1/sud`, the only place a renewed code is asked from.
  final Uri api;
  final bool testEnv;

  /// SUD's language code, e.g. `en-US`.
  final String language;

  static final _digits = RegExp(r'^[0-9]{6,25}$');
  static final _safe = RegExp(r'^[A-Za-z0-9_-]{1,64}$');
  static final _lang = RegExp(r'^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})?$');
  static final _host = RegExp(r'^[a-z0-9-]+\.supabase\.co$');

  /// Our own Supabase function only, never an address a link could invent. Null when it is anything else.
  static Uri? trustedApi(String? value) {
    final u = Uri.tryParse(value ?? '');
    if (u == null || u.scheme != 'https' || !_host.hasMatch(u.host)) return null;
    final path = u.path.replaceAll(RegExp(r'/+$'), '');
    if (path != '/functions/v1/sud') return null;
    return Uri(scheme: 'https', host: u.host, path: path);
  }

  /// The launch address -> the values, or null when anything is missing or odd (the game then says it is not available instead of starting something half-made).
  static SudLaunch? fromUrl(Uri url) {
    String get(String k) => (url.queryParameters[k] ?? '').trim();
    final api = trustedApi(get('api'));
    final appId = get('appId'), appKey = get('appKey'), gameId = get('gameId'), roomId = get('roomId'), userId = get('userId');
    final code = get('code'), token = get('t');
    var lang = get('lang');
    if (api == null) return null;
    if (!_digits.hasMatch(appId) || appKey.isEmpty || appKey.length > 200) return null;
    if (!_digits.hasMatch(gameId)) return null;
    if (!_safe.hasMatch(roomId) || userId.isEmpty || userId.length > 200 || code.isEmpty || code.length > 4000 || token.isEmpty || token.length > 4000) return null;
    if (!_lang.hasMatch(lang)) lang = 'en-US';
    return SudLaunch(appId: appId, appKey: appKey, gameId: gameId, roomId: roomId, userId: userId, code: code, launchToken: token, api: api, testEnv: get('test') != '0', language: lang);
  }

  /// Where a new login code is asked for, and what is sent (the launch token proves it came from a launch of this person).
  Uri get refreshUrl => api.replace(path: '${api.path}/refresh');
  String get refreshBody => jsonEncode({'t': launchToken});
}

/// The size of a SUD game's panel: 1080 x 1669 pixels (height / width = 1.545), the size the owner chose on 2026-10-28 from a screenshot of a game on their phone, where the game fills it
/// edge to edge. Every SUD game uses it (SUD's own minimum sizes are only a lower bound, and a game scales itself to the view it is given).
const double kSudGameAspect = 1669 / 1080;

/// The game state the game sends when the player taps "back to the lobby": that is the end of this screen.
const String kSudBackLobbyState = 'mg_common_back_lobby';

/// How long the game may take to start before the screen gives up and says so (a slow line can need about a minute).
const Duration kSudLoadTimeout = Duration(seconds: 90);

/// The answer to the SDK's "how big is the game view": its size in device PIXELS, with no margin taken from the game.
String sudViewInfoJson(int widthPx, int heightPx) => jsonEncode({
      'ret_code': 0,
      'ret_msg': 'success',
      'view_size': {'width': widthPx < 1 ? 1 : widthPx, 'height': heightPx < 1 ? 1 : heightPx},
      'view_game_rect': {'left': 0, 'top': 0, 'right': 0, 'bottom': 0},
    });

/// The answer to the SDK's "what is the game configuration": SUD's defaults, with the ping and version labels hidden.
String sudGameConfigJson() => jsonEncode({
      'gameMode': 1,
      'gameCPU': 0,
      'gameSoundControl': 0,
      'gameSoundVolume': 100,
      'viewScale': 1.0,
      'autoScale': 0,
      'ui': {
        'ping': {'hide': true},
        'version': {'hide': true},
      },
    });

/// What a person reads when the SDK cannot start. Only SUD's number is shown, never a message of the SDK's own.
String sudStartFailure(Object? code) {
  final c = '${code ?? ''}'.replaceAll(RegExp(r'[^0-9A-Za-z_-]'), '');
  return 'The game could not start${c.isEmpty ? '' : ' (${c.length > 12 ? c.substring(0, 12) : c})'}. Please close it and try again.';
}

const String kSudTimeoutMessage = 'The game is taking too long to load. Check your connection, then close it and try again.';
