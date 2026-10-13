import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sabalive/services/screen_protection.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.sabalive.in/screen_protection');
  final calls = <bool>[];

  setUp(() {
    ScreenProtection.resetForTest();
    calls.clear();
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'setSecure') calls.add((call.arguments as Map)['on'] as bool);
      return null;
    });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test('turning it on asks the phone to block screenshots, once', () async {
    await ScreenProtection.set(true);
    await ScreenProtection.set(true);
    expect(calls, [true]);
    expect(ScreenProtection.isOn, isTrue);
  });

  test('and off again', () async {
    await ScreenProtection.set(true);
    await ScreenProtection.set(false);
    expect(calls, [true, false]);
    expect(ScreenProtection.isOn, isFalse);
  });

  test('the last choice is kept, and applied at the next start before anything else', () async {
    await ScreenProtection.set(true);
    ScreenProtection.resetForTest();
    calls.clear();
    await ScreenProtection.restore();
    expect(calls, [true]);
    expect(ScreenProtection.isOn, isTrue);
  });

  test('with nothing saved it stays off (and that is not an error)', () async {
    await ScreenProtection.restore();
    expect(ScreenProtection.isOn, isFalse);
  });

  test('a phone that cannot do it (iOS, no native side) is ignored, not a crash', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    await ScreenProtection.set(true);
    expect(ScreenProtection.isOn, isFalse, reason: 'nothing was actually switched');
  });

  test('a failing native call is swallowed', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => throw PlatformException(code: 'boom'));
    await ScreenProtection.set(true);
    expect(ScreenProtection.isOn, isFalse);
  });
}
