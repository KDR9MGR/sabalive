/// Real native Google Sign-In (the OS-level "Choose an account" picker,
/// not a browser redirect) needs a **Web** OAuth 2.0 Client ID from Google
/// Cloud Console — this is required by Supabase's `signInWithIdToken` to
/// verify the token server-side, even though the actual sign-in happens
/// natively on-device.
///
/// To fill this in:
/// 1. Google Cloud Console → APIs & Services → Credentials → Create
///    Credentials → OAuth client ID.
/// 2. Create THREE client IDs under the same project: one "Web application"
///    (this is the one that goes below — no redirect URIs needed for this
///    use), one "Android" (package name `com.sabalive.in`, plus the SHA-1
///    fingerprint of whichever keystore signs the build being tested —
///    debug and release keystores each need their own SHA-1 registered),
///    and one "iOS" (bundle id from ios/Runner.xcodeproj, currently
///    `com.sabalive.in`).
/// 3. Paste the **Web** client ID's value below.
/// 4. Supabase dashboard → Authentication → Providers → Google: paste that
///    same Web client ID (and its secret) there too — Supabase needs it to
///    verify the ID token this app sends it.
/// 5. iOS only: add the iOS client's reversed-client-id as a URL scheme in
///    ios/Runner/Info.plist (the google_sign_in package's own setup docs
///    show the exact block) — Android needs no extra native config beyond
///    the SHA-1 registration above.
///
/// Until this is filled in, [AuthController.loginWithSocial] falls back to
/// the web-redirect OAuth flow (same as Apple/Facebook) rather than
/// throwing or faking a successful login.
class GoogleConfig {
  GoogleConfig._();

  static const String webClientId =
      '350645363676-lk53ek8gfttb1322aijqe832ojqhrs3b.apps.googleusercontent.com';

  static bool get isConfigured => webClientId.isNotEmpty;

  /// Is the on-device Google picker usable here? NOT on iOS (2026-10-27): the iOS plugin needs the iOS client's `GIDClientID` in Info.plist, which this app does not have
  /// (the Firebase file has no CLIENT_ID), and without it the plugin raises a native exception that Dart cannot catch: tapping "Google" closed the whole app, which an App
  /// Store review would count as a crash. On iOS Google signs in through the browser flow (the same one Apple uses) until the iOS client is created and its id added
  /// to Info.plist (step 5 above); then this can be switched back on.
  static bool nativeSignInSupported({required bool isIOS}) => isConfigured && !isIOS;
}
