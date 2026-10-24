import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:path_provider/path_provider.dart';

import 'effect_file_cache.dart';

/// The pictures (avatars, card photos, gift and store icons, tag and badge pictures) kept on the phone, apart from the effect files: its own folder, its
/// own size limit, and a gap between trims because it takes many small files at once.
///
/// Flutter's own image cache lives in memory and is emptied whenever the app is closed, so every start downloaded every avatar again: that is most of the
/// "Cached Egress" meter. With this each picture is downloaded once per phone (while the system keeps the temporary folder), then read from storage.
final EffectFileCache imageFileCache = EffectFileCache(
  directory: () async => Directory('${(await getTemporaryDirectory()).path}/image_files'),
  maxBytes: 120 * 1024 * 1024,
  maxFileBytes: 8 * 1024 * 1024,
  timeout: const Duration(seconds: 20),
  minTrimGap: const Duration(seconds: 30),
);

/// A drop-in for [NetworkImage] that reads the picture from the phone when it is already there, and downloads and keeps it when it is not. Wrap it in
/// [ResizeImage] to decode it small. A picture that cannot be fetched (offline, deleted, not a picture) fails like any image, so `errorBuilder` still runs.
@immutable
class DiskCachedNetworkImage extends ImageProvider<DiskCachedNetworkImage> {
  const DiskCachedNetworkImage(this.url, {this.scale = 1.0, EffectFileCache? cache}) : _cache = cache;

  final String url;
  final double scale;
  final EffectFileCache? _cache;

  EffectFileCache get cache => _cache ?? imageFileCache;

  @override
  Future<DiskCachedNetworkImage> obtainKey(ImageConfiguration configuration) => SynchronousFuture<DiskCachedNetworkImage>(this);

  @override
  ImageStreamCompleter loadImage(DiskCachedNetworkImage key, ImageDecoderCallback decode) {
    return MultiFrameImageStreamCompleter(
      codec: _load(key, decode),
      scale: key.scale,
      debugLabel: key.url,
      informationCollector: () => [DiagnosticsProperty<ImageProvider>('Image provider', this), DiagnosticsProperty<String>('URL', url)],
    );
  }

  Future<ui.Codec> _load(DiskCachedNetworkImage key, ImageDecoderCallback decode) async {
    final file = await cache.cached(key.url) ?? await cache.fetch(key.url);
    if (file == null) throw DiskCachedImageException(key.url);
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) {
      // a damaged copy: forget it so the next ask downloads it again
      unawaited(file.delete().catchError((_) => file));
      throw DiskCachedImageException(key.url);
    }
    try {
      return await decode(await ui.ImmutableBuffer.fromUint8List(bytes));
    } catch (_) {
      // not a picture (or a half-written file): drop the stored copy so it is not served again
      unawaited(file.delete().catchError((_) => file));
      rethrow;
    }
  }

  @override
  bool operator ==(Object other) => other is DiskCachedNetworkImage && other.url == url && other.scale == scale;

  @override
  int get hashCode => Object.hash(url, scale);

  @override
  String toString() => '${objectRuntimeType(this, 'DiskCachedNetworkImage')}("$url", scale: ${scale.toStringAsFixed(1)})';
}

/// The picture could not be fetched or read.
class DiskCachedImageException implements Exception {
  DiskCachedImageException(this.url);
  final String url;

  @override
  String toString() => 'Could not load the picture $url';
}
