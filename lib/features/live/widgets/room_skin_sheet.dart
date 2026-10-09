import 'package:flutter/material.dart' hide Text;

import '../../../core/utils/errors.dart';
import '../../../core/widgets/remote_media.dart';
import '../../../data/store_repository.dart';
import '../../../router/app_nav.dart';
import '../../../theme/app_colors.dart';
import '../../../core/i18n/text.dart';

/// The host's "Room skin" tool: pick the background of this audio room from the skins they own
/// (bought in the Store, or put in their Bag by the team), or go back to the plain room.
///
/// Equipping a skin is the same action as in the Bag (`set_item_equipped`); the database copies the
/// equipped skin onto every live of that host, so the room, and every viewer's screen, change at once.
Future<void> showRoomSkinSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.bgElevated,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
    ),
    builder: (sheetContext) => RoomSkinSheet(
      onOpenStore: () {
        Navigator.pop(sheetContext);
        AppNav.store(context);
      },
    ),
  );
}

class RoomSkinSheet extends StatefulWidget {
  const RoomSkinSheet({super.key, this.repo, this.onOpenStore});

  /// Injectable for tests.
  final StoreRepository? repo;

  /// Shown as a button when the host owns no skin yet.
  final VoidCallback? onOpenStore;

  @override
  State<RoomSkinSheet> createState() => _RoomSkinSheetState();
}

class _RoomSkinSheetState extends State<RoomSkinSheet> {
  late final StoreRepository _repo = widget.repo ?? StoreRepository();
  List<OwnedItem>? _skins;
  String? _loadError;
  String? _busyId; // the tile being applied ('none' for the plain room)
  String? _message;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loadError = null;
      _skins = null;
    });
    try {
      final all = await _repo.myItems();
      if (!mounted) return;
      setState(() {
        _skins = [
          for (final o in all)
            if (o.item.category == StoreCategory.roomSkin && !o.isExpired) o,
        ];
      });
    } catch (e) {
      if (mounted) setState(() => _loadError = friendlyError(e));
    }
  }

  Future<void> _choose(OwnedItem? skin) async {
    if (_busyId != null) return;
    final skins = _skins ?? const <OwnedItem>[];
    setState(() {
      _busyId = skin?.item.id ?? 'none';
      _message = null;
    });
    try {
      if (skin == null) {
        // back to the plain room: let go of whichever skin is on
        for (final o in skins.where((o) => o.equipped)) {
          await _repo.setEquipped(o.item.id, false);
        }
      } else if (!skin.equipped) {
        await _repo.setEquipped(skin.item.id, true); // swaps out any other skin
      }
      await _load();
      if (mounted) setState(() => _message = skin == null ? 'Back to the plain room' : '${skin.item.name} is on');
    } catch (e) {
      if (mounted) setState(() => _message = friendlyError(e));
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final skins = _skins;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Room skin',
              textAlign: TextAlign.center,
              style: TextStyle(fontFamily: 'Poppins', fontWeight: FontWeight.w700, fontSize: 15),
            ),
            const SizedBox(height: 4),
            const Text(
              'The background of your room, for everyone in it.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textMuted, fontSize: 12),
            ),
            const SizedBox(height: 14),
            if (_loadError != null) ...[
              Text(_loadError!, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.danger)),
              TextButton(onPressed: _load, child: const Text('Try again')),
            ] else if (skins == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 30),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (skins.isEmpty) ...[
              const Icon(Icons.wallpaper_rounded, size: 40, color: AppColors.textMuted),
              const SizedBox(height: 10),
              const Text(
                "You don't have a room skin yet. Skins you buy in the Store, or that the team adds to your Bag, show up here.",
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textMuted, fontSize: 12.5),
              ),
              if (widget.onOpenStore != null)
                TextButton(onPressed: widget.onOpenStore, child: const Text('Open the Store')),
            ] else
              Flexible(
                child: GridView.count(
                  shrinkWrap: true,
                  crossAxisCount: 3,
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  childAspectRatio: 0.78,
                  children: [
                    _Tile(
                      key: const ValueKey('skin-none'),
                      name: 'Plain room',
                      selected: !skins.any((o) => o.equipped),
                      busy: _busyId == 'none',
                      onTap: () => _choose(null),
                      preview: const Icon(Icons.block_rounded, color: AppColors.textMuted, size: 30),
                    ),
                    for (final o in skins)
                      _Tile(
                        key: ValueKey('skin-${o.item.id}'),
                        name: o.item.name,
                        selected: o.equipped,
                        busy: _busyId == o.item.id,
                        onTap: () => _choose(o),
                        preview: o.item.assetUrl == null
                            ? Text(o.item.emoji, style: const TextStyle(fontSize: 34))
                            : RemoteMedia(
                                o.item.assetUrl!,
                                animate: false,
                                fit: BoxFit.cover,
                                fallback: Center(child: Text(o.item.emoji, style: const TextStyle(fontSize: 34))),
                              ),
                      ),
                  ],
                ),
              ),
            if (_message != null) ...[
              const SizedBox(height: 10),
              Text(_message!, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12.5)),
            ],
          ],
        ),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    super.key,
    required this.name,
    required this.selected,
    required this.busy,
    required this.onTap,
    required this.preview,
  });

  final String name;
  final bool selected;
  final bool busy;
  final VoidCallback onTap;
  final Widget preview;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: selected ? AppColors.primaryBright : Colors.transparent,
                  width: 2,
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Center(child: preview),
                  if (busy) const Center(child: CircularProgressIndicator(strokeWidth: 2)),
                  if (selected && !busy)
                    Positioned(
                      top: 6,
                      right: 6,
                      child: Icon(Icons.check_circle_rounded, size: 18, color: AppColors.primaryBright),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11.5),
          ),
        ],
      ),
    );
  }
}
