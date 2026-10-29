# Picked up automatically by the Flutter Gradle plugin for release builds (R8).
# SUD game SDK: its models are read through Gson / reflection and its view is created by name; obfuscating them breaks the game ("the JSON fields do not match", SUD FAQ Q9001).
-keep class tech.sud.** { *; }
-keep interface tech.sud.** { *; }
-dontwarn tech.sud.**

# OkHttp (a dependency of SUD's plugin) mentions optional TLS providers that are not in the app; R8 would otherwise stop the release build on them.
-dontwarn org.bouncycastle.**
-dontwarn org.conscrypt.**
-dontwarn org.openjsse.**
