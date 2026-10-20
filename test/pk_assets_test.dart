import 'dart:io';

import 'package:flutter_svga/flutter_svga.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/features/live/widgets/pk_svga.dart';
import 'package:sabalive/state/pk_theme_store.dart';

/// The PK animations in assets/pk: each is decoded by the real player (so a file the player can't read is caught here, not on a
/// phone), and the size and length the screens are laid out for are checked.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // file -> [view box width, view box height, seconds]
  const files = <String, List<num>>{
    'live_pk.svga': [750, 1624, 4.0],
    'live_pk_draw_icon.svga': [360, 450, 5.0],
    'live_pk_lose_icon.svga': [360, 450, 5.0],
    'live_pk_win_icon.svga': [360, 450, 5.0],
    'lose.svga': [300, 300, 5.0],
    'pk_anim.svga': [450, 600, 2.0],
    'pk_count_down.svga': [750, 750, 3.0], // the 3-2-1 is exactly the 3 s countdown
    'pk_matching.svga': [750, 500, 2.0],
    'pk_mic_blue.svga': [80, 80, 1.5],
    'pk_mic_blue_rtl.svga': [80, 80, 1.5],
    'pk_mic_red.svga': [80, 80, 1.5],
    'pk_mic_red_rtl.svga': [80, 80, 1.5],
    'pk_progress_battle.svga': [120, 120, 1.75],
    'pk_progress_blue.svga': [1053, 48, 25 / 30],
    'pk_progress_red.svga': [1053, 48, 25 / 30],
    'pk_start_anim.svga': [720, 360, 1.4],
    'pk_svga.svga': [500, 500, 3.0],
    'room_battle_start_animator.svga': [450, 800, 2.0],
  };

  test('assets/pk holds exactly the files the app names, and every one is listed here', () {
    final onDisk = Directory('assets/pk').listSync().map((e) => e.path.split('/').last).toSet();
    final named = {
      PkAsset.matching, PkAsset.invite, PkAsset.logo, PkAsset.gloves, PkAsset.countdown, PkAsset.versus, PkAsset.hero, PkAsset.badge,
      PkAsset.win, PkAsset.lose, PkAsset.draw, PkAsset.loseEmoji,
      for (final team in PkTeam.values) ...[PkAsset.bar(team), PkAsset.sword(team), PkAsset.sword(team, rtl: true)],
    }.map((p) => p.split('/').last).toSet();
    expect(onDisk, named, reason: 'a file on disk that no screen plays, or a screen asking for a file that is not there');
    expect(files.keys.toSet(), onDisk);
  });

  testWidgets('every PK animation decodes in the real player, at the size and length the screens expect', (t) async {
    await t.runAsync(() async {
      for (final e in files.entries) {
        final movie = await SVGAParser.shared.decodeFromAssets('assets/pk/${e.key}');
        final p = movie.params;
        expect(p.viewBoxWidth, e.value[0], reason: '${e.key} width');
        expect(p.viewBoxHeight, e.value[1], reason: '${e.key} height');
        expect(p.frames / p.fps, closeTo(e.value[2].toDouble(), 0.06), reason: '${e.key} seconds');
        expect(movie.sprites, isNotEmpty, reason: '${e.key} has something to draw');
        movie.dispose();
      }
    });
  });

  testWidgets('the blue bar is the red bar in blue: the same layers and frames', (t) async {
    await t.runAsync(() async {
      final red = await SVGAParser.shared.decodeFromAssets('assets/pk/pk_progress_red.svga');
      final blue = await SVGAParser.shared.decodeFromAssets('assets/pk/pk_progress_blue.svga');
      expect(blue.sprites.length, red.sprites.length);
      expect(blue.images.length, red.images.length);
      expect(blue.params.frames, red.params.frames);
      // the bar's rounded body is a vector shape: its fill went from red to blue
      _Rgb fill(MovieEntity m) {
        final shape = m.sprites.first.frames.first.shapes.first;
        final c = shape.styles.fill;
        return _Rgb(c.r, c.g, c.b);
      }

      final r = fill(red), b = fill(blue);
      expect(r.r, greaterThan(r.b), reason: 'red is mostly red');
      expect(b.b, greaterThan(b.r), reason: 'blue is mostly blue');
      red.dispose();
      blue.dispose();
    });
  });
}

/// A colour's three channels, to compare (the file's own colour type is a protobuf message).
class _Rgb {
  _Rgb(this.r, this.g, this.b);
  final double r, g, b;
}
