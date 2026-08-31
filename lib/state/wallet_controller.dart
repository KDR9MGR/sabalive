import 'package:flutter/foundation.dart';

import '../data/mock_data.dart';
import '../data/models.dart';

/// In-memory wallet. Tracks a coin balance + diamond (earnings) balance and a
/// running transaction log. Buying coins and sending gifts mutate these.
class WalletController extends ChangeNotifier {
  int _coins = 12450;
  int _diamonds = 18600;
  final List<WalletTx> _tx = Mock.transactions();

  int get coins => _coins;
  int get diamonds => _diamonds;
  double get earningsInr => _diamonds * 0.82; // fake conversion
  List<WalletTx> get transactions => List.unmodifiable(_tx);

  bool canAfford(int price) => _coins >= price;

  void buyCoins(CoinPack pack) {
    final total = pack.coins + pack.bonus;
    _coins += total;
    _tx.insert(0, WalletTx(TxType.topUp, 'Coin top-up ${pack.price}', total, 'Just now'));
    notifyListeners();
  }

  bool sendGift(Gift gift, String toName) {
    if (!canAfford(gift.price)) return false;
    _coins -= gift.price;
    _tx.insert(
      0,
      WalletTx(TxType.giftSent, '${gift.name} ${gift.emoji} to $toName', -gift.price, 'Just now'),
    );
    notifyListeners();
    return true;
  }

  void receiveGift(Gift gift, String fromName) {
    _diamonds += gift.price;
    _tx.insert(
      0,
      WalletTx(TxType.giftReceived, '${gift.name} ${gift.emoji} from $fromName', gift.price, 'Just now'),
    );
    notifyListeners();
  }

  bool withdraw(int diamonds) {
    if (diamonds > _diamonds) return false;
    _diamonds -= diamonds;
    _tx.insert(0, WalletTx(TxType.withdraw, 'Withdrawal to bank', -diamonds, 'Just now'));
    notifyListeners();
    return true;
  }
}
