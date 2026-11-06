# Picked up automatically by the Flutter Gradle plugin for release builds (R8).
# SUD game SDK: its models are read through Gson / reflection and its view is created by name; obfuscating them breaks the game ("the JSON fields do not match", SUD FAQ Q9001).
-keep class tech.sud.** { *; }
-keep interface tech.sud.** { *; }
-dontwarn tech.sud.**

# OkHttp (a dependency of SUD's plugin) mentions optional TLS providers that are not in the app; R8 would otherwise stop the release build on them.
-dontwarn org.bouncycastle.**
-dontwarn org.conscrypt.**
-dontwarn org.openjsse.**

# MS cloud (hosted LiveKit server, staging builds): the plugin's own classes are looked up by name from Dart's method channels. flutter_webrtc and its org.webrtc classes ship their own keep rules.
-keep class io.livekit.plugin.** { *; }
-dontwarn io.livekit.**
