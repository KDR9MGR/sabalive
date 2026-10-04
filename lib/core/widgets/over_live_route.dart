import 'package:flutter/material.dart';

/// A page presented as a tall sheet over the live room instead of replacing it.
/// The room stays on screen (dimmed) behind it and keeps running — its timer,
/// chat and audio/video connection are untouched — and tapping outside or going
/// back returns to it. Used for everything a user opens from inside a live
/// (Coin Bag, Wallet, Store, Garage, Inbox, ...).
class OverLiveRoute<T> extends PageRoute<T> {
  OverLiveRoute(this.page);

  final Widget page;

  @override
  Color? get barrierColor => Colors.black54;

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => 'Close';

  @override
  bool get maintainState => true;

  @override
  bool get opaque => false;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 260);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return Align(
      alignment: Alignment.bottomCenter,
      child: FractionallySizedBox(
        heightFactor: 0.9,
        widthFactor: 1,
        child: ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
          child: MediaQuery.removePadding(
            context: context,
            removeTop: true,
            child: page,
          ),
        ),
      ),
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(0, 1),
        end: Offset.zero,
      ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
      child: child,
    );
  }
}
