import 'package:flutter/material.dart' hide Text;
import 'package:flutter_svga/flutter_svga.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

import '../../../config/supabase_client.dart';
import '../../../core/widgets/remote_media.dart';
import '../../../data/models.dart';
import 'emote_overlay.dart';
import 'seat_room.dart';

/// CP (couple) seats of an AUDIO room (owner, 2026-11-05; database: migration 20261105100000_cp_seats).
///
/// Two extra seats are drawn above the room's seat grid, with a pink couple banner behind them (the SVGA in `assets/cp/`: a crowned heart between two
/// avatar slots, with wings). The host switches them on and off and is seated on the LEFT one automatically; who may sit on the right one is decided on the
/// server (`cp_seat_refusal`, not decided yet). They are the seat numbers 24 and 25: above any room's seat count (the grid stops at 16), so an older app that
/// does not know about them simply never draws them.
const int kCpSeatLeft = 24;
const int kCpSeatRight = 25;
const List<int> kCpSeats = [kCpSeatLeft, kCpSeatRight];

bool isCpSeat(int seat) => seat == kCpSeatLeft || seat == kCpSeatRight;

/// The function that seats the caller on [seat]: a couple seat has its own (the ordinary claim_seat refuses a seat above the room's seat count).
String claimSeatRpc(int seat) => isCpSeat(seat) ? 'claim_cp_seat' : 'claim_seat';

/// The function that changes the seat count: while CP seats are on, one that leaves them alone.
String setSeatCountRpc({required bool cpSeats}) => cpSeats ? 'set_seat_count_v2' : 'set_seat_count';

/// The bundled banner and where its two avatar slots are, in the file's own 750 x 140 canvas.
abstract final class CpBanner {
  static const asset = 'assets/cp/cp_banner.svga';
  static const double width = 750;
  static const double height = 140;

  /// The pink bar spans x 118..628 and the wings 85..657 of the canvas.
  static const double wingsLeft = 85;
  static const double wingsRight = 657;

  /// Centres of the file's avatar slots: `avatar2` (left, the host's) and `avatar1` (right).
  static const Offset leftSlot = Offset(297, 71);
  static const Offset rightSlot = Offset(448.5, 71);

  /// The file draws a grey placeholder disc in each slot; the real seats stand there instead, so they are hidden.
  static const placeholders = ['avatar1', 'avatar2'];

  /// Reads the bundled file and hides the placeholder discs. Shared movie per phone run: the room's rows come and go (PK, seat changes).
  static Future<MovieEntity> load(String path) async {
    final movie = await SVGAParser.shared.decodeFromAssets(path);
    for (final key in placeholders) {
      movie.dynamicItem.setHidden(true, key);
    }
    return movie;
  }
}

/// Where the banner and the two seats go for a row [available] wide: the banner is scaled so its wings just fit, centred, so the heart lies between the seats.
class CpLayout {
  const CpLayout._(this.scale, this.bannerLeft, this.bannerWidth, this.bannerHeight, this.left, this.right, this.rowHeight);

  factory CpLayout.forWidth(double available, {double seat = CpSeatsRow.seatSlot}) {
    final s = available / (CpBanner.wingsRight - CpBanner.wingsLeft);
    final w = CpBanner.width * s;
    final h = CpBanner.height * s;
    // the banner is centred on its wings, which are not centred on the canvas (85 on the left, 93 on the right)
    final left = available / 2 - ((CpBanner.wingsLeft + CpBanner.wingsRight) / 2) * s;
    final l = Offset(left + CpBanner.leftSlot.dx * s, CpBanner.leftSlot.dy * s);
    final r = Offset(left + CpBanner.rightSlot.dx * s, CpBanner.rightSlot.dy * s);
    // a seat is its picture slot and the name under it
    final seatBottom = l.dy + seat / 2 + CpSeatsRow.labelRoom;
    return CpLayout._(s, left, w, h, l, r, seatBottom > h ? seatBottom : h);
  }

  final double scale;
  final double bannerLeft;
  final double bannerWidth;
  final double bannerHeight;

  /// Centre of the left (host's) and right seat's picture.
  final Offset left;
  final Offset right;
  final double rowHeight;
}

/// The two couple seats on their banner. Used by [SeatGrid] above its rows while the room has CP seats switched on.
class CpSeatsRow extends StatelessWidget {
  const CpSeatsRow({
    super.key,
    required this.occupants,
    required this.hostId,
    required this.onSeatTap,
    this.lockedSeats = const {},
    this.mutedSeats = const {},
    this.speakingSeats = const {},
    this.diamonds = const {},
    this.emotes,
    @visibleForTesting this.bannerLoader,
  });

  final Map<int, AppUser> occupants;
  final String hostId;
  final Set<int> lockedSeats;
  final Set<int> mutedSeats;
  final Set<int> speakingSeats;
  final Map<String, int> diamonds;
  final EmoteController? emotes;
  final void Function(int seat) onSeatTap;
  final SvgaLoader? bannerLoader;

  /// The picture of a couple seat (a bit smaller than an ordinary seat: two of them have to sit either side of the heart).
  static const double seatSize = 46;

  /// The square a seat's picture and frame get, and the line for the name under it.
  static const double seatSlot = 60;
  static const double labelRoom = 18;

  Widget _seat(int seat, Offset centre) {
    final occupant = occupants[seat];
    return Positioned(
      left: centre.dx - seatSlot / 2,
      top: centre.dy - seatSlot / 2,
      width: seatSlot,
      child: SeatCircle(
        key: ValueKey('cp-seat-$seat'),
        seat: seat,
        occupant: occupant,
        locked: lockedSeats.contains(seat),
        muted: mutedSeats.contains(seat),
        speaking: speakingSeats.contains(seat),
        diamonds: occupant == null ? null : (diamonds[occupant.id] ?? 0),
        isHost: occupant?.id == hostId,
        // the two sit side by side: the host's picture is NOT drawn bigger here
        hostBigger: false,
        // a person on a couple seat sits WITHOUT their avatar frame (owner, 2026-11-06): the banner is the decoration
        showFrame: false,
        emptyLabel: 'CP',
        // an empty couple seat is the golden throne like every other seat (owner, 2026-11-07)
        goldenSeat: true,
        size: seatSize,
        slot: seatSlot,
        emotes: emotes,
        onTap: () => onSeatTap(seat),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final layout = CpLayout.forWidth(box.maxWidth);
      return SizedBox(
        height: layout.rowHeight,
        child: Stack(
          // the banner is wider than the row (its see-through margins reach past it)
          clipBehavior: Clip.none,
          children: [
            Positioned(
              left: layout.bannerLeft,
              top: 0,
              width: layout.bannerWidth,
              height: layout.bannerHeight,
              // taps go to the seats, never to the picture behind them
              child: IgnorePointer(
                child: RepaintBoundary(
                  child: RemoteMedia(CpBanner.asset, key: const ValueKey('cp-banner'), svgaLoader: bannerLoader ?? CpBanner.load, loop: true, fit: BoxFit.fill),
                ),
              ),
            ),
            _seat(kCpSeatLeft, layout.left),
            _seat(kCpSeatRight, layout.right),
          ],
        ),
      );
    });
  }
}

/// Whether the server has the `cp_seats` column. Optimistic: the first "column does not exist" answer (an app that is ahead of the database) turns it off for the
/// rest of the run, so a missing migration costs one failed read, never a broken room.
abstract final class CpSeatsSupport {
  static bool _available = true;
  static bool get available => _available;

  /// `, cp_seats` to add to a live_streams select, or nothing when the server does not have it.
  static String get column => _available ? ', cp_seats' : '';

  /// True when [e] says the column is missing (and remembers it).
  static bool noteError(Object e) {
    if (e is PostgrestException && (e.code == '42703' || (e.message).contains('cp_seats'))) {
      _available = false;
      return true;
    }
    return false;
  }

  @visibleForTesting
  static void reset() => _available = true;
}

/// One live_streams row with [columns] and, when the server has it, `cp_seats`. Falls back to the plain columns if the server is behind.
Future<Map<String, dynamic>?> readStreamRow(String streamId, String columns) async {
  try {
    return await supabase.from('live_streams').select('$columns${CpSeatsSupport.column}').eq('id', streamId).maybeSingle();
  } catch (e) {
    if (!CpSeatsSupport.noteError(e)) rethrow;
    return supabase.from('live_streams').select(columns).eq('id', streamId).maybeSingle();
  }
}

/// Whether CP seats are on for [streamId] right now (false when they cannot be read).
Future<bool> fetchCpSeatsOn(String streamId) async {
  if (!CpSeatsSupport.available) return false;
  try {
    final row = await supabase.from('live_streams').select('cp_seats').eq('id', streamId).maybeSingle();
    return row?['cp_seats'] == true;
  } catch (e) {
    CpSeatsSupport.noteError(e);
    return false;
  }
}
