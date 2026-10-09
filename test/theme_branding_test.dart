import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sabalive/core/utils/rebuild_everything.dart';
import 'package:sabalive/state/theme_config_controller.dart';
import 'package:sabalive/theme/app_colors.dart';
import 'package:sabalive/theme/app_font.dart';
import 'package:sabalive/theme/app_palette.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false; // no downloads in tests

  tearDown(() {
    AppColors.apply(AppPalette.stock);
    AppFont.use('Poppins');
  });

  group('AppPalette', () {
    test('the panel defaults give exactly the original palette', () {
      final p = AppPalette.fromBrand(AppPalette.defaultBrand, AppPalette.defaultAccent);
      expect(p, AppPalette.stock);
      expect(AppPalette.stock.bg, const Color(0xFF0B0716));
      expect(AppPalette.stock.primary, const Color(0xFF9B3DF5));
    });

    test('another brand colour recolours the backgrounds and the purples, keeping them dark', () {
      final p = AppPalette.fromBrand(const Color(0xFF0E9F6E), const Color(0xFFF5279B)); // green
      expect(p, isNot(AppPalette.stock));
      final bg = HSLColor.fromColor(p.bg);
      expect(bg.lightness, lessThan(0.08));
      expect(bg.hue, closeTo(HSLColor.fromColor(const Color(0xFF0E9F6E)).hue, 2));
      // lighter surfaces stack up from the page background
      expect(HSLColor.fromColor(p.surface).lightness, greaterThan(bg.lightness));
      expect(HSLColor.fromColor(p.surfaceAlt).lightness, greaterThan(HSLColor.fromColor(p.surface).lightness));
      expect(HSLColor.fromColor(p.stroke).lightness, greaterThan(HSLColor.fromColor(p.surfaceAlt).lightness));
      expect(HSLColor.fromColor(p.primaryBright).lightness, greaterThan(HSLColor.fromColor(p.primary).lightness));
      expect(HSLColor.fromColor(p.primaryDeep).lightness, lessThan(HSLColor.fromColor(p.primary).lightness));
    });

    test('a grey or white brand gives neutral backgrounds, not a colour cast', () {
      final p = AppPalette.fromBrand(const Color(0xFFFFFFFF), const Color(0xFFF5279B));
      for (final c in [p.bg, p.bgElevated, p.surface, p.stroke]) {
        final hsl = HSLColor.fromColor(c);
        expect(hsl.saturation, lessThan(0.05), reason: 'no tint');
      }
    });

    test('the accent is used as given', () {
      final p = AppPalette.fromBrand(const Color(0xFF2563EB), const Color(0xFFFFAA00));
      expect(p.magenta, const Color(0xFFFFAA00));
    });

    test('a brand too dark or too pale to read on a dark screen is lifted into range', () {
      expect(HSLColor.fromColor(AppPalette.fromBrand(const Color(0xFF000033), const Color(0xFFF5279B)).primary).lightness,
          greaterThanOrEqualTo(0.45));
      expect(HSLColor.fromColor(AppPalette.fromBrand(const Color(0xFFFFFFFF), const Color(0xFFF5279B)).primary).lightness,
          lessThanOrEqualTo(0.66));
    });

    test('AppColors follows the palette that was applied, gradients included', () {
      final p = AppPalette.fromBrand(const Color(0xFF0E9F6E), const Color(0xFFF5279B));
      AppColors.apply(p);
      expect(AppColors.bg, p.bg);
      expect(AppColors.primary, p.primary);
      expect(AppColors.brandGradient.colors.last, p.magenta);
      expect(AppColors.heroGlow.colors.last, p.bg);
      AppColors.apply(AppPalette.stock);
      expect(AppColors.bg, const Color(0xFF0B0716));
      expect(AppColors.brandGradient.colors.first, const Color(0xFF7C3AED));
    });
  });

  testWidgets('a new palette reaches widgets that read AppColors while they build', (t) async {
    await t.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Builder(builder: (_) => ColoredBox(key: const ValueKey('bg'), color: AppColors.bg)),
      ),
    );
    expect(t.widget<ColoredBox>(find.byKey(const ValueKey('bg'))).color, AppPalette.stock.bg);

    final p = AppPalette.fromBrand(const Color(0xFF0E9F6E), const Color(0xFFF5279B));
    AppColors.apply(p);
    await t.pump();
    expect(t.widget<ColoredBox>(find.byKey(const ValueKey('bg'))).color, AppPalette.stock.bg,
        reason: 'nothing rebuilds by itself');
    rebuildEverything();
    await t.pump();
    expect(t.widget<ColoredBox>(find.byKey(const ValueKey('bg'))).color, p.bg);
  });

  group('Branding', () {
    test('reads colours with or without the # and keeps the fallback for anything unreadable', () {
      final b = Branding.fromRow({'brand_color': '#0e9f6e', 'accent_color': 'nonsense', 'font_family': '  '});
      expect(b.brand, const Color(0xFF0E9F6E));
      expect(b.accent, Branding.stock.accent);
      expect(b.font, 'Poppins');
      expect(Branding.fromRow({'brand_color': '2563EB'}).brand, const Color(0xFF2563EB));
    });

    test('a row can leave a field out (it keeps what the app already had)', () {
      final had = Branding.fromRow({'brand_color': '#0e9f6e', 'font_family': 'Roboto'});
      final next = Branding.fromRow({'accent_color': '#ffaa00'}, fallback: had);
      expect(next.brand, had.brand);
      expect(next.font, 'Roboto');
      expect(next.accent, const Color(0xFFFFAA00));
    });

    test('toHex round-trips', () {
      expect(Branding.toHex(const Color(0xFF0E9F6E)), '#0e9f6e');
      expect(Branding.parseHex(Branding.toHex(const Color(0xFF123456))), const Color(0xFF123456));
    });

    test('restore applies what the last run saved, before any network', () async {
      SharedPreferences.setMockInitialValues({
        'theme.brand': '#0e9f6e',
        'theme.accent': '#ffaa00',
        'theme.font': 'Poppins',
      });
      await ThemeConfigController.restore();
      expect(AppColors.magenta, const Color(0xFFFFAA00));
      expect(AppColors.primary, isNot(AppPalette.stock.primary));
    });

    test('with nothing saved the stock look stays', () async {
      SharedPreferences.setMockInitialValues({});
      await ThemeConfigController.restore();
      expect(AppColors.palette, AppPalette.stock);
    });
  });

  group('AppFont', () {
    test('a real Google font is accepted whatever the capitals, a made-up one is not', () {
      expect(AppFont.resolve('open sans'), 'Open Sans');
      expect(AppFont.resolve('Roboto'), 'Roboto');
      expect(AppFont.resolve('Not A Real Font 123'), isNull);
      expect(AppFont.resolve(''), isNull);
      expect(AppFont.resolve(null), isNull);
    });

    test('a made-up name keeps Poppins instead of throwing', () {
      expect(AppFont.use('Not A Real Font 123'), isFalse);
      expect(AppFont.family, 'Poppins');
      const base = TextStyle(fontSize: 14, fontWeight: FontWeight.w700);
      expect(AppFont.style(base), same(base), reason: 'the default font changes nothing');
    });

    test('a chosen font applies to text styles and keeps their weight and size', () {
      expect(AppFont.use('Roboto'), isTrue);
      expect(AppFont.isCustom, isTrue);
      final styled = AppFont.style(const TextStyle(fontSize: 14, fontWeight: FontWeight.w700));
      expect(styled.fontSize, 14);
      expect(styled.fontFamily, contains('Roboto'));
    });
  });
}
