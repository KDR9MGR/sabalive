import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// Keeps the gift / entry-effect files (videos and sounds) on the phone, so a gift plays from storage the
/// second time instead of being streamed again, and so the next effect in a busy room can be fetched while
/// the current one is still playing (prefetch) and start the instant its turn comes.
///
/// It is only a speed-up: every method answers "no file" instead of throwing, and the players fall back to
/// streaming the url when there is none. The folder lives in the temporary directory (the system may clear
/// it) and is trimmed to [maxBytes], oldest first.
class EffectFileCache {
  EffectFileCache({
    Future<Directory> Function()? directory,
    http.Client? client,
    this.maxBytes = 150 * 1024 * 1024,
    this.maxFileBytes = 30 * 1024 * 1024,
    this.timeout = const Duration(seconds: 25),
  })  : _directory = directory ?? _defaultDirectory,
        _client = client ?? http.Client();

  /// The one the live screens share.
  static final EffectFileCache instance = EffectFileCache();

  final Future<Directory> Function() _directory;
  final http.Client _client;
  final int maxBytes;
  final int maxFileBytes;
  final Duration timeout;

  final Map<String, Future<File?>> _inFlight = {};
  Directory? _dir;

  static Future<Directory> _defaultDirectory() async {
    final tmp = await getTemporaryDirectory();
    return Directory('${tmp.path}/effect_files');
  }

  Future<Directory> _ensureDir() async {
    final d = _dir ??= await _directory();
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  /// A stable, filesystem-safe name for [url]: a 64-bit FNV-1a of the whole url (query included, so a
  /// re-uploaded file with a new token is a new file) plus the original extension.
  static String fileNameFor(String url) {
    var h = 0xcbf29ce484222325;
    for (final b in utf8.encode(url)) {
      h ^= b;
      h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    final path = Uri.tryParse(url)?.path ?? url;
    final dot = path.lastIndexOf('.');
    var ext = dot < 0 ? '' : path.substring(dot + 1).toLowerCase();
    if (ext.length > 5 || !RegExp(r'^[a-z0-9]+$').hasMatch(ext)) ext = 'bin';
    return '${h.toRadixString(16).padLeft(16, '0')}.$ext';
  }

  /// The file for [url] if it is already stored, else null. Never downloads.
  Future<File?> cached(String url) async {
    try {
      final f = File('${(await _ensureDir()).path}/${fileNameFor(url)}');
      return await f.exists() ? f : null;
    } catch (_) {
      return null;
    }
  }

  /// The file for [url], downloading it first when it is not stored. Asks for the same url share one
  /// download. Null when it could not be fetched (offline, too big, not found).
  Future<File?> fetch(String url) {
    // (a block body: returning the removed future from whenComplete would make it wait on itself)
    return _inFlight[url] ??= _fetch(url).whenComplete(() {
      _inFlight.remove(url);
    });
  }

  /// Start fetching [url] in the background; nothing waits on it.
  void prefetch(String url) => unawaited(fetch(url));

  Future<File?> _fetch(String url) async {
    try {
      final hit = await cached(url);
      if (hit != null) {
        unawaited(hit.setLastModified(DateTime.now()).catchError((_) {})); // recently used
        return hit;
      }
      final response = await _client.get(Uri.parse(url)).timeout(timeout);
      if (response.statusCode != 200) return null;
      final bytes = response.bodyBytes;
      if (bytes.isEmpty || bytes.length > maxFileBytes) return null;
      final dir = await _ensureDir();
      final target = File('${dir.path}/${fileNameFor(url)}');
      final part = File('${target.path}.part');
      await part.writeAsBytes(bytes, flush: true);
      await part.rename(target.path);
      unawaited(_trim(dir));
      return target;
    } catch (_) {
      return null;
    }
  }

  Future<void> _trim(Directory dir) async {
    try {
      final files = <(File, int, DateTime)>[];
      var total = 0;
      await for (final e in dir.list()) {
        if (e is! File || e.path.endsWith('.part')) continue;
        final stat = await e.stat();
        files.add((e, stat.size, stat.modified));
        total += stat.size;
      }
      if (total <= maxBytes) return;
      files.sort((a, b) => a.$3.compareTo(b.$3)); // oldest first
      for (final (file, size, _) in files) {
        if (total <= maxBytes) break;
        await file.delete();
        total -= size;
      }
    } catch (_) {}
  }
}
