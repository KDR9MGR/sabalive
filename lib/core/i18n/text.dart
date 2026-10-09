import 'package:flutter/widgets.dart' as w;

import '../../theme/app_font.dart';
import 'i18n.dart';

export 'i18n.dart' show tr;

/// A drop-in for Flutter's `Text` that shows the string in the app's chosen
/// language (see I18n). Every screen uses this one: the files import
/// `package:flutter/material.dart` with `hide Text` plus this file, so no call site
/// had to change. Anything without a translation shows exactly as written.
class Text extends w.StatelessWidget {
  const Text(
    this.data, {
    super.key,
    this.style,
    this.strutStyle,
    this.textAlign,
    this.textDirection,
    this.locale,
    this.softWrap,
    this.overflow,
    this.textScaler,
    this.maxLines,
    this.semanticsLabel,
    this.textWidthBasis,
    this.textHeightBehavior,
    this.selectionColor,
  }) : textSpan = null;

  const Text.rich(
    this.textSpan, {
    super.key,
    this.style,
    this.strutStyle,
    this.textAlign,
    this.textDirection,
    this.locale,
    this.softWrap,
    this.overflow,
    this.textScaler,
    this.maxLines,
    this.semanticsLabel,
    this.textWidthBasis,
    this.textHeightBehavior,
    this.selectionColor,
  }) : data = null;

  final String? data;
  final w.InlineSpan? textSpan;
  final w.TextStyle? style;
  final w.StrutStyle? strutStyle;
  final w.TextAlign? textAlign;
  final w.TextDirection? textDirection;
  final w.Locale? locale;
  final bool? softWrap;
  final w.TextOverflow? overflow;
  final w.TextScaler? textScaler;
  final int? maxLines;
  final String? semanticsLabel;
  final w.TextWidthBasis? textWidthBasis;
  final w.TextHeightBehavior? textHeightBehavior;
  final w.Color? selectionColor;

  @override
  w.Widget build(w.BuildContext context) {
    // the panel's font, when one other than the bundled Poppins is chosen: applied on top of the
    // surrounding text style so weight, size and colour stay what the screen asked for
    final w.TextStyle? shown = AppFont.isCustom
        ? AppFont.style(w.DefaultTextStyle.of(context).style.merge(style))
        : style;
    final span = textSpan;
    if (span != null) {
      return w.Text.rich(
        translateSpan(span),
        style: shown,
        strutStyle: strutStyle,
        textAlign: textAlign,
        textDirection: textDirection,
        locale: locale,
        softWrap: softWrap,
        overflow: overflow,
        textScaler: textScaler,
        maxLines: maxLines,
        semanticsLabel: semanticsLabel,
        textWidthBasis: textWidthBasis,
        textHeightBehavior: textHeightBehavior,
        selectionColor: selectionColor,
      );
    }
    return w.Text(
      I18n.tr(data!),
      style: shown,
      strutStyle: strutStyle,
      textAlign: textAlign,
      textDirection: textDirection,
      locale: locale,
      softWrap: softWrap,
      overflow: overflow,
      textScaler: textScaler,
      maxLines: maxLines,
      semanticsLabel: semanticsLabel,
      textWidthBasis: textWidthBasis,
      textHeightBehavior: textHeightBehavior,
      selectionColor: selectionColor,
    );
  }
}

/// A TextSpan tree with every piece of text translated (for `Text.rich` and
/// `RichText`).
w.InlineSpan translateSpan(w.InlineSpan span) {
  if (span is w.TextSpan) {
    return w.TextSpan(
      text: span.text == null ? null : I18n.tr(span.text!),
      children: span.children?.map(translateSpan).toList(),
      style: span.style,
      recognizer: span.recognizer,
      mouseCursor: span.mouseCursor,
      onEnter: span.onEnter,
      onExit: span.onExit,
      semanticsLabel: span.semanticsLabel,
      locale: span.locale,
      spellOut: span.spellOut,
    );
  }
  return span;
}
