import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_svga/flutter_svga.dart';
import 'package:flutter_svga/src/proto/svga.pb.dart' as pb;
import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/core/widgets/remote_media.dart';

/// A real .svga file, built the way the format defines it (a zlib-compressed
/// MovieEntity protobuf): a 32px red square sliding across a 200x100 canvas
/// over 20 frames at 20 fps. Proves the app's SVGA player reads actual files,
/// not just in-memory fakes.
Future<Uint8List> _buildSvga() async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    const Rect.fromLTWH(0, 0, 32, 32),
    Paint()..color = const Color(0xFFE53935),
  );
  final image = await recorder.endRecording().toImage(32, 32);
  final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;

  final movie = pb.MovieEntity()
    ..version = '2.0'
    ..params = (pb.MovieParams()
      ..viewBoxWidth = 200
      ..viewBoxHeight = 100
      ..fps = 20
      ..frames = 20)
    ..images['square'] = png.buffer.asUint8List()
    ..sprites.add(
      pb.SpriteEntity()
        ..imageKey = 'square'
        ..frames.addAll([
          for (var i = 0; i < 20; i++)
            pb.FrameEntity()
              ..alpha = 1
              ..layout = (pb.Layout()..x = 0..y = 0..width = 32..height = 32)
              ..transform = (pb.Transform()
                ..a = 1
                ..b = 0
                ..c = 0
                ..d = 1
                ..tx = i * 8.0
                ..ty = 34),
        ]),
    );
  return Uint8List.fromList(ZLibCodec().encode(movie.writeToBuffer()));
}

void main() {
  testWidgets('a real .svga file decodes: size, frames and its picture', (t) async {
    late Uint8List bytes;
    late MovieEntity decoded;
    await t.runAsync(() async {
      bytes = await _buildSvga();
      decoded = await SVGAParser.shared.decodeFromBuffer(bytes);
      // Opt-in: write the file out so it can be opened in the admin panel.
      final out = Platform.environment['WRITE_SAMPLE_SVGA'];
      if (out != null) File(out).writeAsBytesSync(bytes);
    });
    expect(decoded.params.viewBoxWidth, 200);
    expect(decoded.params.frames, 20);
    expect(decoded.sprites, hasLength(1));
    expect(decoded.sprites.first.frames, hasLength(20));
    expect(decoded.bitmapCache.keys, contains('square'), reason: 'image decoded');
  });

  testWidgets('RemoteMedia plays that file through once, then reports done', (t) async {
    late Uint8List bytes;
    await t.runAsync(() async => bytes = await _buildSvga());
    var finished = 0;
    await t.pumpWidget(
      MaterialApp(
        home: RemoteMedia(
          'https://x.co/slide.svga',
          loop: false,
          onFinished: () => finished++,
          svgaLoader: (_) => SVGAParser.shared.decodeFromBuffer(bytes),
        ),
      ),
    );
    // decoding the embedded PNG is real async work, outside the fake clock
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await t.pump();
    expect(find.byType(SVGAImage), findsOneWidget);
    expect(finished, 0);
    await t.pump(const Duration(milliseconds: 500));
    expect(finished, 0, reason: 'half way: 20 frames at 20 fps is one second');
    await t.pump(const Duration(milliseconds: 700));
    await t.pump();
    expect(finished, 1);
    await t.pumpWidget(const SizedBox());
  });
}
