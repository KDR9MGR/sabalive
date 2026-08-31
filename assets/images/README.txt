Runtime image assets live here.

The app currently renders procedural gradient placeholders (see
lib/core/widgets/app_avatar.dart and app_thumb.dart) so it runs fully
offline with no network image dependency. Drop real photos/thumbnails
here and swap them into the widgets when a backend is wired up.
