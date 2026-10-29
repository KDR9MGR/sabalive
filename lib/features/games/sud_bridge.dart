import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:sud_gip_plugin/sud_gip_plugin.dart';

import 'sud_launch.dart';

/// The answer of a call into SUD's native SDK: 0 is success.
class SudResult {
  const SudResult(this.code, [this.message = '']);

  /// What the plugin answers: `{retCode, retMsg}`; anything else (no answer) is a failure.
  factory SudResult.from(Map<String, dynamic>? m) => SudResult((m?['retCode'] as num?)?.toInt() ?? -1, '${m?['retMsg'] ?? ''}');

  final int code;
  final String message;
  bool get ok => code == 0;
}

/// What the running game tells the app.
class SudGameEvents {
  const SudGameEvents({this.onLoading, this.onStarted, this.onDestroyed, this.onExpireCode, this.onState});

  /// Loading progress (0-100); [retCode] is SUD's code for that step (0 = fine).
  final void Function(int progress, int retCode)? onLoading;
  final VoidCallback? onStarted;
  final VoidCallback? onDestroyed;

  /// The login code expired: ask for a new one and give it back with [SudBridge.updateCode].
  final VoidCallback? onExpireCode;
  final void Function(String state, String dataJson)? onState;
}

/// The few things the game screen does with SUD's SDK, in one place so the screen can be tested without a phone (the real one is [PluginSudBridge]).
abstract class SudBridge {
  /// The native view the game is drawn in. [onCreated] gets the view's id once it exists: the game can only be loaded after that.
  Widget buildView(void Function(int viewId) onCreated);

  Future<SudResult> init({required String appId, required String appKey, required String userId, required bool testEnv});

  Future<SudResult> load(int viewId, SudLaunch launch, {required String viewInfoJson, required String configJson, required SudGameEvents events});

  Future<void> updateCode(int viewId, String code);
  Future<void> pause(int viewId);
  Future<void> resume(int viewId);

  /// Stops the game in this view (the view stays, a new game can be loaded in it).
  Future<void> destroy(int viewId);

  /// Frees the view for good: after this its id must not be used again.
  Future<void> release(int viewId);
}

/// SUD's own Flutter plugin (`sud_gip_plugin`, which wraps their native Android / iOS SDK).
class PluginSudBridge implements SudBridge {
  @override
  Widget buildView(void Function(int viewId) onCreated) {
    // The second kind (hybrid composition on Android): the first puts the native surface above everything and, per the plugin's own note, cannot be used with the Pro SDK.
    return getSudGIPPlatformView2(onCreated);
  }

  @override
  Future<SudResult> init({required String appId, required String appKey, required String userId, required bool testEnv}) async =>
      SudResult.from(await SudGipPlugin.initSDKWithEnv(appId, appKey, userId, testEnv));

  @override
  Future<SudResult> load(int viewId, SudLaunch launch, {required String viewInfoJson, required String configJson, required SudGameEvents events}) async {
    SudGipPlugin.setFSMGame(
      viewId,
      SudGIPFSMGameDelegate(
        onGameLoadingProgress: (stage, retCode, progress) => events.onLoading?.call(progress, retCode),
        onGameStarted: () => events.onStarted?.call(),
        onGameDestroyed: () => events.onDestroyed?.call(),
        onExpireCode: (_) => events.onExpireCode?.call(),
        onGameStateChange: (state, dataJson) => events.onState?.call(state, dataJson),
      ),
    );
    return SudResult.from(await SudGipPlugin.loadGame(viewId, launch.userId, launch.roomId, launch.code, launch.gameId, launch.language, viewInfoJson, configJson));
  }

  @override
  Future<void> updateCode(int viewId, String code) async {
    await SudGipPlugin.updateCode(viewId, code);
  }

  @override
  Future<void> pause(int viewId) async {
    await SudGipPlugin.pauseGame(viewId);
  }

  @override
  Future<void> resume(int viewId) async {
    await SudGipPlugin.playGame(viewId);
  }

  @override
  Future<void> destroy(int viewId) async {
    SudGipPlugin.removeFSMGame(viewId);
    await SudGipPlugin.destroyGame(viewId);
  }

  @override
  Future<void> release(int viewId) async {
    try {
      await destroy(viewId);
    } catch (_) {
      // leaving anyway
    }
    try {
      await SudGipPlugin.dispose(viewId);
    } catch (_) {}
  }
}

/// Asks our server for a new login code (the old one lives two hours). Null when it cannot be had: the game then keeps going until SUD refuses it.
typedef SudCodeRenewer = Future<String?> Function(SudLaunch launch);

Future<String?> renewSudCode(SudLaunch launch, {http.Client? client}) async {
  final c = client ?? http.Client();
  try {
    final res = await c.post(launch.refreshUrl, headers: const {'Content-Type': 'application/json'}, body: launch.refreshBody).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) return null;
    final body = jsonDecode(res.body);
    final code = body is Map ? body['code'] : null;
    return code is String && code.isNotEmpty ? code : null;
  } catch (_) {
    return null;
  } finally {
    if (client == null) c.close();
  }
}
