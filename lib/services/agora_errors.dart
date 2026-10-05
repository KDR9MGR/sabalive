import 'package:agora_rtc_engine/agora_rtc_engine.dart';

/// The two things a person can usefully be told when Agora refuses or drops a
/// connection. English here is the translation key (see tool/i18n).
const agoraUnreachableMessage =
    "Can't reach the live service right now. Please try again in a moment.";
const agoraExpiredMessage =
    'Your connection to this room expired. Please leave and join again.';

/// Plain-language text for an Agora [onError] callback. The SDK's own message is
/// usually empty or technical, and without this a refused join (an exhausted
/// Agora quota, a suspended app id, a rejected channel) left the viewer on an
/// endless spinner with no explanation.
String agoraErrorMessage(ErrorCodeType err, String msg) => switch (err) {
      ErrorCodeType.errTokenExpired ||
      ErrorCodeType.errInvalidToken =>
        agoraExpiredMessage,
      ErrorCodeType.errInvalidAppId ||
      ErrorCodeType.errJoinChannelRejected ||
      ErrorCodeType.errNoServerResources ||
      ErrorCodeType.errClientIsBannedByServer =>
        agoraUnreachableMessage,
      _ => msg.isNotEmpty ? msg : agoraUnreachableMessage,
    };

/// Plain-language text for a connection that ended in
/// [ConnectionStateType.connectionStateFailed] — the SDK gave up, as opposed to
/// the brief "Reconnecting" state after a network blip.
String agoraFailureMessage(ConnectionChangedReasonType reason) => switch (reason) {
      ConnectionChangedReasonType.connectionChangedInvalidToken ||
      ConnectionChangedReasonType.connectionChangedTokenExpired =>
        agoraExpiredMessage,
      _ => agoraUnreachableMessage,
    };
