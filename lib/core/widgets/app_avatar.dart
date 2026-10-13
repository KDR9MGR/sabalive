import 'package:flutter/material.dart' hide Text;

import '../../theme/app_colors.dart';
import '../utils/formatters.dart';
import 'remote_media.dart';
import '../i18n/text.dart';
import '../../state/remote_config_controller.dart';

/// Avatars smaller than this show their frame as a still picture instead of playing it.
const double kAnimatedFrameMinSize = 48;

/// Avatars smaller than this show no frame at all: at that size a frame is a smudge that crowds whatever is
/// beside it (the host's name pill, a chat chip, a list row).
const double kFrameMinSize = 40;

/// Shows the user's real uploaded photo when [imageUrl] is set; otherwise
/// falls back to a deterministic gradient with initials, keeping every user
/// visually distinct even with no photo.
///
/// [size] is the avatar's WHOLE footprint, frame included. With a frame the picture is drawn smaller inside it
/// ([frameScale] times), and the frame fills the footprint: nothing is ever painted outside the box the avatar
/// was given, so a frame can never spill over a neighbouring seat, label, name or list row.
class AppAvatar extends StatelessWidget {
  const AppAvatar({
    super.key,
    required this.name,
    this.size = 44,
    this.ring = false,
    this.ringColor,
    this.live = false,
    this.imageUrl,
    this.frameUrl,
  });

  final String name;
  final double size;
  final bool ring;
  final Color? ringColor;
  final bool live;
  final String? imageUrl;

  /// The user's equipped avatar frame (see AppUser.frameUrl): animated artwork
  /// drawn around the picture, filling the avatar's footprint. It sits BEHIND the picture, so
  /// whatever its artwork looks like, it can never hide the face. Not drawn below [kFrameMinSize].
  final String? frameUrl;

  /// How much bigger than the picture the frame artwork is: the picture takes 1 / [frameScale] of the footprint.
  static const frameScale = 1.4;

  /// Is a frame drawn on an avatar of this [size] with this [frameUrl]?
  static bool showsFrame(double size, String? frameUrl) =>
      frameUrl != null && frameUrl.isNotEmpty && size >= kFrameMinSize;

  /// The size of the picture itself inside a footprint of [size].
  static double pictureSize(double size, String? frameUrl) =>
      showsFrame(size, frameUrl) ? size / frameScale : size;

  @override
  Widget build(BuildContext context) {
    final tint = AppColors.tints[name.hashCode.abs() % AppColors.tints.length];
    final hasPhoto = imageUrl != null && imageUrl!.isNotEmpty;
    final framed = showsFrame(size, frameUrl);
    final pic = pictureSize(size, frameUrl);
    final photo = Container(
      width: pic,
      height: pic,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: hasPhoto
            ? null
            : LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: tint,
              ),
        image: hasPhoto
            ? DecorationImage(
                image: NetworkImage(imageUrl!),
                fit: BoxFit.cover,
              )
            : null,
        border: ring
            ? Border.all(
                color: ringColor ?? AppColors.gold,
                width: pic * 0.05 + 1.2,
              )
            : null,
      ),
      alignment: Alignment.center,
      child: hasPhoto
          ? null
          : Text(
              initialsOf(name),
              style: TextStyle(
                fontFamily: 'Poppins',
                fontWeight: FontWeight.w600,
                fontSize: pic * 0.38,
                color: Colors.white,
              ),
            ),
    );

    final frame = frameUrl;
    final avatar = !framed
        ? photo
        : SizedBox(
            width: size,
            height: size,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // fills the footprint, behind the picture; never takes taps
                IgnorePointer(
                  child: SizedBox.square(
                    dimension: size,
                    child: RemoteMedia(
                      frame!,
                      key: ValueKey(frame),
                      fit: BoxFit.contain,
                      // A live room has dozens of avatars (chat, viewers, seats); a
                      // frame animating on each one kept the GPU busy and heated phones.
                      // Small ones show the still first frame; big ones still play.
                      // also switchable from the panel (feature_flags.animated_frames) without a release
                      animate: size >= kAnimatedFrameMinSize &&
                          RemoteConfigController.instance.flag('animated_frames'),
                    ),
                  ),
                ),
                photo,
              ],
            ),
          );

    if (!live) return avatar;

    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.bottomCenter,
      children: [
        avatar,
        Positioned(
          bottom: -size * 0.12,
          child: Container(
            padding: EdgeInsets.symmetric(
                horizontal: size * 0.14, vertical: size * 0.02),
            decoration: BoxDecoration(
              gradient: AppColors.liveGradient,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: AppColors.bg, width: 1.5),
            ),
            child: Text(
              'LIVE',
              style: TextStyle(
                fontFamily: 'Poppins',
                fontWeight: FontWeight.w700,
                fontSize: size * 0.18,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
