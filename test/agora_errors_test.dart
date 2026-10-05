import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/core/widgets/connection_banner.dart';
import 'package:sabalive/services/agora_errors.dart';

void main() {
  group('agoraErrorMessage', () {
    test('a refused join (quota, suspended app id, rejected) reads as unreachable', () {
      for (final e in [
        ErrorCodeType.errInvalidAppId,
        ErrorCodeType.errJoinChannelRejected,
        ErrorCodeType.errNoServerResources,
        ErrorCodeType.errClientIsBannedByServer,
      ]) {
        expect(agoraErrorMessage(e, 'raw sdk text'), agoraUnreachableMessage, reason: '$e');
      }
    });

    test('an expired or invalid token tells the person to rejoin', () {
      expect(agoraErrorMessage(ErrorCodeType.errTokenExpired, ''), agoraExpiredMessage);
      expect(agoraErrorMessage(ErrorCodeType.errInvalidToken, ''), agoraExpiredMessage);
    });

    test('other errors keep the SDK text, or fall back when it is empty', () {
      expect(agoraErrorMessage(ErrorCodeType.errNotReady, 'not ready'), 'not ready');
      expect(agoraErrorMessage(ErrorCodeType.errNotReady, ''), agoraUnreachableMessage);
    });
  });

  group('agoraFailureMessage', () {
    test('token reasons say rejoin; everything else says unreachable', () {
      expect(
        agoraFailureMessage(ConnectionChangedReasonType.connectionChangedTokenExpired),
        agoraExpiredMessage,
      );
      expect(
        agoraFailureMessage(ConnectionChangedReasonType.connectionChangedInvalidToken),
        agoraExpiredMessage,
      );
      expect(
        agoraFailureMessage(ConnectionChangedReasonType.connectionChangedRejectedByServer),
        agoraUnreachableMessage,
      );
      expect(
        agoraFailureMessage(ConnectionChangedReasonType.connectionChangedJoinFailed),
        agoraUnreachableMessage,
      );
    });
  });

  group('ConnectionBanner', () {
    Future<void> show(WidgetTester t, {bool reconnecting = false, String? failure}) =>
        t.pumpWidget(MaterialApp(
          home: Scaffold(body: ConnectionBanner(reconnecting: reconnecting, failure: failure)),
        ));

    testWidgets('is empty when connected', (t) async {
      await show(t);
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('shows Reconnecting while reconnecting', (t) async {
      await show(t, reconnecting: true);
      expect(find.text('Reconnecting…'), findsOneWidget);
    });

    testWidgets('a failure replaces the reconnecting text', (t) async {
      await show(t, reconnecting: true, failure: agoraUnreachableMessage);
      expect(find.text(agoraUnreachableMessage), findsOneWidget);
      expect(find.text('Reconnecting…'), findsNothing);
    });
  });
}
