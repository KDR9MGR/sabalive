import 'package:flutter/material.dart' hide Text;
import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/core/media/disk_cached_image.dart';
import 'package:sabalive/core/utils/formatters.dart';
import 'package:sabalive/core/widgets/app_avatar.dart';

/// Avatars are decoded at the size they are drawn (a 1024 px upload is a 4 MB bitmap in memory), not at their upload size.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const url = 'https://x.supabase.co/storage/v1/object/public/avatars/u/avatar.jpg';

  ImageProvider avatarProvider(WidgetTester t) {
    final boxes = t.widgetList<Container>(find.byType(Container)).where((c) => c.decoration is BoxDecoration && (c.decoration as BoxDecoration).image != null);
    return (boxes.first.decoration as BoxDecoration).image!.image;
  }

  Future<void> show(WidgetTester t, double size, {double dpr = 3}) async {
    t.view.devicePixelRatio = dpr;
    t.view.physicalSize = Size(400 * dpr, 800 * dpr);
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(home: Scaffold(body: Center(child: AppAvatar(name: 'Asha', imageUrl: url, size: size)))));
  }

  testWidgets('a 44 dp avatar on a 3x screen decodes about 165 px wide, not 1024', (t) async {
    await show(t, 44);
    final p = avatarProvider(t);
    expect(p, isA<ResizeImage>());
    final w = (p as ResizeImage).width!;
    expect(w, inInclusiveRange(150, 180), reason: '44 x 3 x 1.25');
    expect(p.imageProvider, isA<DiskCachedNetworkImage>(), reason: 'kept on the phone after the first download');
  });

  testWidgets('a big avatar still decodes sharp, and never above the 1024 px it was uploaded at', (t) async {
    await show(t, 120);
    expect((avatarProvider(t) as ResizeImage).width, inInclusiveRange(440, 460));
    await show(t, 400);
    expect((avatarProvider(t) as ResizeImage).width, 1024, reason: 'capped');
  });

  testWidgets('a tiny avatar still gets a sane minimum', (t) async {
    await show(t, 12, dpr: 1);
    expect((avatarProvider(t) as ResizeImage).width, 48);
  });

  testWidgets('without a photo nothing is loaded at all', (t) async {
    t.view.physicalSize = const Size(1200, 2400);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.pumpWidget(const MaterialApp(home: Scaffold(body: Center(child: AppAvatar(name: 'Asha', size: 44)))));
    expect(find.text(initialsOf('Asha')), findsOneWidget);
    final withImage = t.widgetList<Container>(find.byType(Container)).where((c) => c.decoration is BoxDecoration && (c.decoration as BoxDecoration).image != null);
    expect(withImage, isEmpty);
  });
}
