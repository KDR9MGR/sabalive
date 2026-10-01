import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/models.dart';
import '../../data/offline_sellers_repository.dart';
import '../../theme/app_colors.dart';

/// A contact directory of offline coin sellers — real people who take cash/
/// UPI payment outside the app and get your coins credited manually. This
/// is separate from Coin Reseller (an in-app wallet-to-wallet transfer);
/// tapping a seller here just opens WhatsApp so you can arrange it with them.
class CoinSellersScreen extends StatefulWidget {
  const CoinSellersScreen({super.key});

  @override
  State<CoinSellersScreen> createState() => _CoinSellersScreenState();
}

class _CoinSellersScreenState extends State<CoinSellersScreen> {
  final _repo = OfflineSellersRepository();
  List<OfflineSeller> _sellers = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final sellers = await _repo.list();
      if (!mounted) return;
      setState(() {
        _sellers = sellers;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load sellers — pull to retry.';
      });
    }
  }

  Future<void> _openWhatsApp(OfflineSeller seller) async {
    final number = seller.whatsappNumber.replaceAll(RegExp(r'[^0-9]'), '');
    final text = Uri.encodeComponent(
        'Hi ${seller.name}, I\'d like to buy SABALIVE coins.');
    final ok = await launchUrl(
      Uri.parse('https://wa.me/$number?text=$text'),
      mode: LaunchMode.externalApplication,
    );
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open WhatsApp')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Offline Coin Sellers')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
                children: [
                  const Text(
                    'These sellers take payment outside the app (cash / UPI) '
                    'and get your coins credited directly. Message one on '
                    'WhatsApp to arrange a purchase.',
                    style: TextStyle(
                        fontSize: 12.5, color: AppColors.textSecondary, height: 1.5),
                  ),
                  const SizedBox(height: 18),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 30),
                      child: Text(_error!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: AppColors.textMuted)),
                    )
                  else if (_sellers.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 30),
                      child: Text(
                        'No sellers listed right now — check back soon.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: AppColors.textMuted, fontSize: 13),
                      ),
                    )
                  else
                    for (final s in _sellers) _sellerCard(s),
                ],
              ),
      ),
    );
  }

  Widget _sellerCard(OfflineSeller s) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.stroke),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: const BoxDecoration(
              gradient: AppColors.goldGradient,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: const Icon(Icons.storefront_rounded,
                color: Color(0xFF3A1A5E), size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(s.name,
                    style: const TextStyle(
                        fontFamily: 'Poppins',
                        fontWeight: FontWeight.w600,
                        fontSize: 14)),
                if (s.note != null && s.note!.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(s.note!,
                      style: const TextStyle(
                          fontSize: 11.5, color: AppColors.textMuted)),
                ],
              ],
            ),
          ),
          GestureDetector(
            onTap: () => _openWhatsApp(s),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF25D366),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.chat_bubble_rounded, color: Colors.white, size: 15),
                  SizedBox(width: 6),
                  Text('Chat',
                      style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 12.5)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
