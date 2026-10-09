import 'package:flutter/widgets.dart';

/// Asks every widget to build again, without losing where the user is (navigation, an open live, a
/// half-typed message all stay as they were). For changes that many widgets read directly rather than
/// through an inherited widget: the brand colours, the font, the language.
void rebuildEverything() {
  void visit(Element e) {
    e.markNeedsBuild();
    e.visitChildren(visit);
  }

  WidgetsBinding.instance.rootElement?.visitChildren(visit);
}
