import 'dart:async';

import 'package:flutter/material.dart' hide Text;

import '../../../data/notice_feed.dart';
import '../../../state/remote_config_controller.dart';
import 'notice_strip.dart';

/// The notification strips on HOME (everywhere outside a full-screen live): the same big-gift and big-game-win strips a live room draws, at the same height
/// (owner, 2026-11-07: "both gift and game win strip should show in home and in room, both at same height").
///
/// It listens to the shared [NoticeFeed] only while [active] (signed in, and no full-screen live is open: a room draws its own strips through its effect controller, so the two
/// never draw the same announcement twice) and gives the channel back when it stops being active. It draws nothing and takes no touch while no strip is playing.
class HomeNoticeLayer extends StatefulWidget {
  const HomeNoticeLayer({super.key, required this.active, this.feed, this.noticesOn});

  final bool active;

  /// Where the announcements come from; the shared feed unless a test gives its own.
  final Stream<FeedNotice>? feed;

  /// The panel switch (`gift_notice_strip`); on unless the panel says otherwise.
  final bool Function()? noticesOn;

  @override
  State<HomeNoticeLayer> createState() => _HomeNoticeLayerState();
}

class _HomeNoticeLayerState extends State<HomeNoticeLayer> {
  final NoticeStripController _notices = NoticeStripController();
  StreamSubscription<FeedNotice>? _sub;
  Timer? _prewarm;

  bool get _on => (widget.noticesOn ?? () => RemoteConfigController.instance.flag('gift_notice_strip'))();

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(covariant HomeNoticeLayer old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    if (widget.active && _sub == null) {
      // read the two strip files a few seconds after Home opens, while it is calm (once per run: the movies are kept)
      _prewarm ??= Timer(const Duration(seconds: 6), () => unawaited(NoticeArt.prewarm()));
      _sub = (widget.feed ?? NoticeFeed.instance.stream).listen(_onNotice, onError: (Object _) {});
    } else if (!widget.active && _sub != null) {
      unawaited(_sub!.cancel());
      _sub = null;
    }
  }

  void _onNotice(FeedNotice n) {
    if (!mounted || n.coins <= 0 || !_on) return;
    _notices.add(NoticeStripItem.fromFeed(n));
  }

  @override
  void dispose() {
    _prewarm?.cancel();
    unawaited(_sub?.cancel());
    _notices.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Positioned.fill(child: NoticeStripLayer(controller: _notices));
}
