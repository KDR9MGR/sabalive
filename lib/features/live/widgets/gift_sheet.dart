import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/utils/formatters.dart';
import '../../../core/widgets/app_avatar.dart';
import '../../../data/models.dart';
import '../../../router/app_nav.dart';
import '../../../state/wallet_controller.dart';
import '../../../theme/app_colors.dart';

/// What the sheet resolves to: which gift, how many copies, and who it goes
/// to. [recipient] is the picked person (null when [sendToAll] is true, or
/// when the caller never passed a `recipients` list at all — that caller
/// handles who receives it on its own, e.g. PK's Me/Opponent side picker).
typedef GiftChoice = ({
  Gift gift,
  int quantity,
  AppUser? recipient,
  bool sendToAll,
});

/// Bottom sheet for picking a gift, a quantity, and — when the caller passes
/// [recipients] (everyone currently in the room worth gifting) — who it goes
/// to, right in the same sheet: an avatar row with "All" alongside each
/// person, matching a single-recipient app's own reference layout instead of
/// a separate picker step before or after this one. Returns the chosen
/// [GiftChoice], or null if dismissed.
Future<GiftChoice?> showGiftSheet(
  BuildContext context, {
  required String hostName,
  List<AppUser> recipients = const [],
}) {
  return showModalBottomSheet<GiftChoice>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.bgElevated,
    builder: (_) => _GiftSheet(hostName: hostName, recipients: recipients),
  );
}

class _GiftSheet extends StatefulWidget {
  const _GiftSheet({required this.hostName, required this.recipients});
  final String hostName;
  final List<AppUser> recipients;

  @override
  State<_GiftSheet> createState() => _GiftSheetState();
}

class _GiftSheetState extends State<_GiftSheet> {
  int _tab = 0;
  int _selected = 0;
  int _quantity = 1;
  late AppUser? _recipient = widget.recipients.isNotEmpty
      ? widget.recipients.first
      : null;
  bool _sendToAll = false;

  static const _quantities = [1, 10, 99];

  List<Gift> _list(List<Gift> catalog) => switch (_tab) {
    1 => catalog.reversed.toList(),
    2 => catalog.where((g) => g.effect).toList(),
    _ => catalog,
  };

  @override
  Widget build(BuildContext context) {
    final wallet = context.watch<WalletController>();
    final gifts = _list(wallet.gifts);

    if (gifts.isEmpty) {
      return const SizedBox(
        height: 220,
        child: Center(
          child: CircularProgressIndicator(color: AppColors.primaryBright),
        ),
      );
    }

    final gift = gifts[_selected.clamp(0, gifts.length - 1)];
    final total = gift.price * _quantity;
    final canAfford = wallet.canAfford(total);
    final canSend = _sendToAll || _recipient != null;

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 10),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.stroke,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
            child: Row(
              children: [
                const Text(
                  'Send a Gift',
                  style: TextStyle(
                    fontFamily: 'Poppins',
                    fontWeight: FontWeight.w600,
                    fontSize: 16,
                  ),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: () {
                    Navigator.pop(context);
                    AppNav.buyCoins(context);
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: AppColors.stroke),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.monetization_on_rounded,
                          color: AppColors.coin,
                          size: 16,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          compactCount(wallet.coins),
                          style: const TextStyle(
                            fontFamily: 'Poppins',
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(width: 4),
                        const Icon(
                          Icons.add_circle,
                          color: AppColors.primaryBright,
                          size: 16,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (widget.recipients.isNotEmpty) _recipientRow(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                for (final (i, label) in ['Popular', 'New', 'Effects'].indexed)
                  Padding(
                    padding: const EdgeInsets.only(right: 20),
                    child: GestureDetector(
                      onTap: () => setState(() {
                        _tab = i;
                        _selected = 0;
                      }),
                      child: Text(
                        label,
                        style: TextStyle(
                          fontFamily: 'Poppins',
                          fontWeight: FontWeight.w600,
                          fontSize: 13.5,
                          color: _tab == i
                              ? AppColors.textPrimary
                              : AppColors.textMuted,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.34,
            ),
            child: GridView.builder(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 4,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childAspectRatio: 0.86,
              ),
              itemCount: gifts.length,
              itemBuilder: (context, i) {
                final g = gifts[i];
                final sel = i == _selected;
                return GestureDetector(
                  onTap: () => setState(() => _selected = i),
                  child: Container(
                    decoration: BoxDecoration(
                      color: sel
                          ? AppColors.primary.withValues(alpha: 0.18)
                          : AppColors.surface,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: sel ? AppColors.primaryBright : AppColors.stroke,
                      ),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(g.emoji, style: const TextStyle(fontSize: 28)),
                        const SizedBox(height: 4),
                        Text(
                          g.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 10,
                            color: AppColors.textSecondary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(
                              Icons.monetization_on_rounded,
                              color: AppColors.coin,
                              size: 10,
                            ),
                            const SizedBox(width: 2),
                            Text(
                              '${g.price}',
                              style: const TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                color: AppColors.coin,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 12),
          // Quantity + Send row — recipient is already picked via the avatar
          // row above, so this is a single Send action regardless of who
          // (or "All") it's going to.
          Padding(
            padding: EdgeInsets.fromLTRB(
              20,
              0,
              20,
              14 + MediaQuery.of(context).padding.bottom,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                _quantityPicker(),
                const SizedBox(width: 10),
                Expanded(
                  child: _sendButton(
                    label: !canSend
                        ? 'Pick who to send to'
                        : canAfford
                        ? (_sendToAll ? 'Send All · $total' : 'Send · $total')
                        : 'Not enough coins — top up',
                    gradient: _sendToAll ? AppColors.goldGradient : null,
                    onTap: !canSend
                        ? null
                        : () {
                            if (!canAfford) {
                              Navigator.pop(context);
                              AppNav.buyCoins(context);
                              return;
                            }
                            Navigator.pop(context, (
                              gift: gift,
                              quantity: _quantity,
                              recipient: _sendToAll ? null : _recipient,
                              sendToAll: _sendToAll,
                            ));
                          },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _recipientRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
      child: SizedBox(
        height: 62,
        child: ListView(
          scrollDirection: Axis.horizontal,
          children: [
            if (widget.recipients.length > 1)
              _recipientChip(
                selected: _sendToAll,
                label: 'All',
                onTap: () => setState(() => _sendToAll = true),
                child: const CircleAvatar(
                  radius: 22,
                  backgroundColor: AppColors.surface,
                  child: Icon(
                    Icons.groups_rounded,
                    color: AppColors.primaryBright,
                  ),
                ),
              ),
            for (final r in widget.recipients)
              _recipientChip(
                selected: !_sendToAll && _recipient?.id == r.id,
                label: r.name,
                onTap: () => setState(() {
                  _sendToAll = false;
                  _recipient = r;
                }),
                child: AppAvatar(name: r.name, imageUrl: r.avatarUrl, size: 44),
              ),
          ],
        ),
      ),
    );
  }

  Widget _recipientChip({
    required bool selected,
    required String label,
    required VoidCallback onTap,
    required Widget child,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: GestureDetector(
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected
                      ? AppColors.primaryBright
                      : Colors.transparent,
                  width: 2,
                ),
              ),
              child: child,
            ),
            const SizedBox(height: 3),
            SizedBox(
              width: 48,
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 9.5,
                  color: AppColors.textMuted,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _quantityPicker() {
    return GestureDetector(
      onTap: () async {
        final picked = await showModalBottomSheet<int>(
          context: context,
          backgroundColor: AppColors.bgElevated,
          builder: (_) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Padding(
                  padding: EdgeInsets.all(14),
                  child: Text(
                    'Quantity',
                    style: TextStyle(
                      fontFamily: 'Poppins',
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                for (final q in _quantities)
                  ListTile(
                    title: Text('x$q'),
                    trailing: q == _quantity
                        ? const Icon(
                            Icons.check_rounded,
                            color: AppColors.primaryBright,
                          )
                        : null,
                    onTap: () => Navigator.pop(context, q),
                  ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
        if (picked != null) setState(() => _quantity = picked);
      },
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.stroke),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'x$_quantity',
              style: const TextStyle(
                fontFamily: 'Poppins',
                fontWeight: FontWeight.w600,
                fontSize: 14,
              ),
            ),
            const SizedBox(width: 4),
            const Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 18,
              color: AppColors.textMuted,
            ),
          ],
        ),
      ),
    );
  }

  Widget _sendButton({
    required String label,
    required VoidCallback? onTap,
    Gradient? gradient,
  }) {
    final active = onTap != null;
    return Opacity(
      opacity: active ? 1 : 0.5,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: onTap,
          child: Ink(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              gradient: gradient ?? AppColors.primaryGradient,
              borderRadius: BorderRadius.circular(22),
            ),
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _sendToAll ? Icons.groups_rounded : Icons.send_rounded,
                    size: 17,
                    color: Colors.white,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'Poppins',
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
