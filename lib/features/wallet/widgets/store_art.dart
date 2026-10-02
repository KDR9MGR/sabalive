import 'package:flutter/material.dart';

import '../../../core/widgets/remote_media.dart';
import '../../../data/store_repository.dart';
import '../../../theme/app_colors.dart';

/// A store item's picture: the artwork uploaded in the admin panel when there is
/// one (shown still — these sit in grids), otherwise the emoji stand-in. The emoji
/// also shows while the artwork loads and if it can't be loaded.
class StoreArt extends StatelessWidget {
  const StoreArt(this.item, {super.key, required this.size});

  final StoreItem item;
  final double size;

  @override
  Widget build(BuildContext context) {
    final emoji = Text(item.emoji, style: TextStyle(fontSize: size * 0.8));
    final url = item.assetUrl;
    if (url == null) return SizedBox.square(dimension: size, child: Center(child: emoji));
    return SizedBox.square(
      dimension: size,
      child: RemoteMedia(
        url,
        fit: BoxFit.contain,
        animate: false,
        fallback: Center(child: emoji),
      ),
    );
  }
}

/// Plays the item's artwork in motion, the way others will see it, before buying.
Future<void> showStorePreview(BuildContext context, StoreItem item) {
  return showDialog<void>(
    context: context,
    builder: (context) {
      final url = item.assetUrl;
      return Dialog(
        backgroundColor: AppColors.card,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 280,
                height: 280,
                child: url == null
                    ? Center(child: Text(item.emoji, style: const TextStyle(fontSize: 96)))
                    : RemoteMedia(
                        url,
                        fit: BoxFit.contain,
                        fallback: Center(
                          child: Text(item.emoji, style: const TextStyle(fontSize: 96)),
                        ),
                      ),
              ),
              const SizedBox(height: 8),
              Text(
                item.name,
                style: const TextStyle(
                  fontFamily: 'Poppins',
                  fontWeight: FontWeight.w600,
                  fontSize: 15,
                ),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close'),
              ),
            ],
          ),
        ),
      );
    },
  );
}
