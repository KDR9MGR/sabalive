import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/core/utils/personal_info_filter.dart';

/// Every expectation below was produced by running the same input through the
/// server's `mask_personal_info` (Postgres) — so this test fails if the app's
/// copy of the patterns drifts from the database's, which would make a sender's
/// own bubble differ from what everyone else is shown.
void main() {
  const cases = <(String, String, List<String>)>[
    ('hello everyone, nice stream!', 'hello everyone, nice stream!', []),
    ('call me 9876543210 now', 'call me *** now', ['phone']),
    ('my number is 98765 43210 ok', 'my number is *** ok', ['phone']),
    ('+91 98765-43210 whatsapp', '*** whatsapp', ['phone']),
    ('+91-9876543210', '***', ['phone']),
    ('(022) 2345 6789 office', '(*** office', ['phone']),
    ('9.8.7.6.5.4.3.2.1.0', '***', ['phone']),
    ('9\u{FE0F}\u{20E3}8\u{FE0F}\u{20E3}7\u{FE0F}\u{20E3}6\u{FE0F}\u{20E3}5\u{FE0F}\u{20E3}4\u{FE0F}\u{20E3}3\u{FE0F}\u{20E3}2\u{FE0F}\u{20E3}1\u{FE0F}\u{20E3}0\u{FE0F}\u{20E3}', '***', ['phone']),
    ('nine eight seven six five four three two one zero', '***', ['phone']),
    ('ek do teen char paanch chhe saat aath nau', '***', ['phone']),
    ('send me gift 500 coins', 'send me gift 500 coins', []),
    ('I am 25 years old', 'I am 25 years old', []),
    ('2026-10-02 party', '2026-10-02 party', []),
    ('room 1234 5678', 'room 1234 5678', []),
    ('mail me john.doe@gmail.com please', 'mail me *** please', ['email']),
    ('john (at) gmail (dot) com', '***', ['email']),
    ('john at gmail dot com', '***', ['email']),
    ('my upi is rahul@okaxis', 'my upi is ***', ['upi']),
    ('pay rahul123@ybl', 'pay ***', ['upi']),
    ('dm on instagram.com/cool_user', 'dm on ***', ['link']),
    ('https://wa.me/919876543210', '***', ['link']),
    ('join t.me/mygroup', 'join ***', ['link']),
    ('www.facebook.com/someone', '***', ['link']),
    ('visit https://example.com for more', 'visit https://example.com for more', []),
    ('@someone hi', '@someone hi', []),
    ('contact: 9876543210, or john@x.io', 'contact: ***, or ***', ['email', 'phone']),
    ('12345', '12345', []),
    ('1234567', '1234567', []),
    ('12345678', '12345678', []),
    ('123456789012', '***', ['phone']),
    ('price is 1,00,000 rupees', 'price is 1,00,000 rupees', []),
    ('gg \u{1F600}\u{1F600} love it \u{2764}\u{FE0F}', 'gg \u{1F600}\u{1F600} love it \u{2764}\u{FE0F}', []),
  ];

  group('PersonalInfoFilter matches the server', () {
    for (final (input, masked, kinds) in cases) {
      test(input, () {
        final r = PersonalInfoFilter.apply(input);
        expect(r.masked, masked);
        expect(r.kinds, kinds);
      });
    }
  });

  test('maskText returns just the text', () {
    expect(PersonalInfoFilter.maskText('call 9876543210'), 'call ***');
  });

  test('ordinary chat is untouched', () {
    const text = 'great stream, sending a rose! \u{1F339} see you at 8pm';
    expect(PersonalInfoFilter.maskText(text), text);
  });
}
