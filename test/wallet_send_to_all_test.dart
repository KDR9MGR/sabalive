import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/state/wallet_controller.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  group('WalletController.isMissingFunction', () {
    test('PostgREST says the function is not in the schema (backend older than the app)', () {
      expect(
        WalletController.isMissingFunction(
          const PostgrestException(message: 'Could not find the function public.send_gift_to_all', code: 'PGRST202'),
        ),
        isTrue,
      );
      expect(
        WalletController.isMissingFunction(const PostgrestException(message: 'function does not exist', code: '42883')),
        isTrue,
      );
    });

    test('a real refusal is not mistaken for a missing function (so nothing is sent twice)', () {
      expect(
        WalletController.isMissingFunction(const PostgrestException(message: 'Insufficient coins', code: 'P0001')),
        isFalse,
      );
      expect(WalletController.isMissingFunction(Exception('offline')), isFalse);
    });
  });
}
