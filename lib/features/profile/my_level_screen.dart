import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart' hide Text;
import 'package:provider/provider.dart';

import '../../core/utils/formatters.dart';
import '../../core/widgets/level_star.dart';
import '../../core/widgets/pills.dart';
import '../../data/level_images.dart';
import '../../data/levels_repository.dart';
import '../../state/auth_controller.dart';
import '../../theme/app_colors.dart';
import '../../core/i18n/text.dart';

/// Wealth (coins spent) and Charm (value received) — two separate level
/// tracks, both to level 100. See levels_repository.dart's own doc comment
/// for how these relate to the older combined xp/level "LV X" badge shown
/// elsewhere in the app, which this screen no longer shows at all.
/// A level shows as unlocked when it is the person's level or they have reached its XP. The panel lets each level's XP be any number, so a lower-numbered
/// level can need more XP than the person's level; it stays locked until they get there.
@visibleForTesting
bool levelUnlocked(LevelThreshold t, MyLevel mine) => t.level == mine.level || mine.xp >= t.xpRequired;

/// How often an open My Level screen asks again, so XP or a level changed in the panel (Master -> Levels) shows without leaving the screen. Never faster than 20 s (the
/// database has few connections); it only runs while the screen is open and the app is in front.
const Duration kMyLevelRefresh = Duration(seconds: 20);

/// The height a level's picture is drawn at inside its card.
const double kLevelArtSize = 56;

class MyLevelScreen extends StatefulWidget {
  const MyLevelScreen({
    super.key,
    @visibleForTesting this.loader,
    @visibleForTesting this.images,
    @visibleForTesting this.pictureLoader,
    @visibleForTesting this.refreshEvery = kMyLevelRefresh,
    @visibleForTesting this.onLevels,
  });

  /// Replaces the database read (tests).
  final Future<WealthCharmLevels?> Function()? loader;

  /// Replaces the shared level pictures (tests).
  final LevelImageStore? images;

  /// Replaces reading a level picture's file (tests).
  final Future<File?> Function(String url)? pictureLoader;
  final Duration refreshEvery;

  /// Replaces telling My Profile the levels that were just read (tests).
  final void Function(WealthCharmLevels levels)? onLevels;

  @override
  State<MyLevelScreen> createState() => _MyLevelScreenState();
}

/// Shows the person's Wealth and Charm levels with the pictures and XP the panel set. It reads again when it opens, every [kMyLevelRefresh] while it is open and the app is in
/// front, when the app comes back to the front, and on a pull down, and redraws only when something really changed. A read that fails keeps what is on screen.
class _MyLevelScreenState extends State<MyLevelScreen> with WidgetsBindingObserver {
  WealthCharmLevels? _data;
  bool _failed = false;
  bool _busy = false;
  Timer? _timer;
  int _tab = 0; // 0 = Charm, 1 = Wealth

  late final Future<WealthCharmLevels?> Function() _load = widget.loader ?? LevelsRepository().wealthAndCharm;
  LevelImageStore get _images => widget.images ?? LevelImageStore.instance;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _reload(pictures: true);
    _startTimer();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _reload(pictures: true);
      _startTimer();
    } else if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden || state == AppLifecycleState.detached) {
      _timer?.cancel();
      _timer = null;
    }
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(widget.refreshEvery, (_) => _reload());
  }

  /// One read at a time. [pictures] asks for the level pictures again right now (opening, returning, pulling down); a quiet read only renews them when they are 5 minutes old.
  Future<void> _reload({bool pictures = false}) async {
    if (_busy) return;
    _busy = true;
    try {
      unawaited(pictures ? _images.refresh() : _images.ensureLoaded());
      final next = await _load();
      if (!mounted) return;
      if (next != null) _shareLevels(next);
      if (next == null) {
        if (_data == null) setState(() => _failed = true);
      } else if (next != _data || _failed) {
        setState(() {
          _data = next;
          _failed = false;
        });
      }
    } catch (_) {
      if (mounted && _data == null) setState(() => _failed = true);
    } finally {
      _busy = false;
    }
  }

  /// What this screen just read is the truth about the person's levels, so My Profile's stars (read once at sign-in) take it too: the two screens never disagree.
  void _shareLevels(WealthCharmLevels data) {
    final handler = widget.onLevels;
    if (handler != null) return handler(data);
    try {
      context.read<AuthController>().applyLevels(wealth: data.wealth.level, charm: data.charm.level);
    } catch (_) {
      // nobody above to tell (a screen shown on its own)
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    return Scaffold(
      appBar: AppBar(title: const Text('My Level')),
      body: RefreshIndicator(
        onRefresh: () => _reload(pictures: true),
        child: ListenableBuilder(
          listenable: _images,
          builder: (context, _) => CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: data == null ? [_waiting()] : _content(data),
          ),
        ),
      ),
    );
  }

  Widget _waiting() => SliverFillRemaining(
        hasScrollBody: false,
        child: Center(
          child: _failed
              ? Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('Check your internet connection and try again.', textAlign: TextAlign.center, style: TextStyle(color: AppColors.textMuted)),
                      const SizedBox(height: 12),
                      TextButton(onPressed: () => _reload(pictures: true), child: const Text('Retry')),
                    ],
                  ),
                )
              : const CircularProgressIndicator(),
        ),
      );

  List<Widget> _content(WealthCharmLevels data) {
    final isCharm = _tab == 0;
    final selected = isCharm ? data.charm : data.wealth;
    final track = isCharm ? 'charm' : 'wealth';
    return [
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
        sliver: SliverList(
          delegate: SliverChildListDelegate([
            SegmentedTabs(tabs: const ['Charm', 'Wealth'], index: _tab, onChanged: (i) => setState(() => _tab = i)),
            const SizedBox(height: 20),
            _header(selected, isCharm: isCharm, track: track),
            const SizedBox(height: 24),
            Text('All ${isCharm ? 'Charm' : 'Wealth'} Levels', style: const TextStyle(fontFamily: 'Poppins', fontWeight: FontWeight.w600, fontSize: 15)),
            const SizedBox(height: 12),
          ]),
        ),
      ),
      // built as they scroll into view, so a hundred pictures are not all fetched at once
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 40),
        sliver: SliverGrid(
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, mainAxisSpacing: 12, crossAxisSpacing: 12, childAspectRatio: 1.3),
          delegate: SliverChildBuilderDelegate(
            (context, i) {
              final t = selected.thresholds[i];
              return _levelCard(t, track: track, current: t.level == selected.level, unlocked: levelUnlocked(t, selected));
            },
            childCount: selected.thresholds.length,
          ),
        ),
      ),
    ];
  }

  Widget _header(MyLevel data, {required bool isCharm, required String track}) {
    final next = data.next;
    final pictureUrl = _images.urlFor(track, data.level);
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: AppColors.brandGradient,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        children: [
          pictureUrl == null
              ? _levelCircle(data, isCharm: isCharm)
              : SizedBox(
                  height: 84,
                  child: LevelPicture(key: ValueKey('my-level-art-$pictureUrl'), url: pictureUrl, size: 84, fallback: _levelCircle(data, isCharm: isCharm), loader: widget.pictureLoader),
                ),
          const SizedBox(height: 12),
          Text('${isCharm ? 'Charm' : 'Wealth'} Level ${data.level}',
              style: const TextStyle(
                  fontFamily: 'Poppins',
                  fontWeight: FontWeight.w700,
                  fontSize: 20,
                  color: Colors.white)),
          const SizedBox(height: 12),
          Text(
            next == null ? 'Max level reached' : 'Progress to Level ${next.level}',
            style: TextStyle(color: Colors.white.withValues(alpha: 0.85), fontSize: 12.5),
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: data.progress,
              minHeight: 8,
              backgroundColor: Colors.white.withValues(alpha: 0.25),
              valueColor: const AlwaysStoppedAnimation(Colors.white),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('${withThousands(data.xp)} XP',
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.85), fontSize: 11.5)),
              if (next != null)
                Text('${withThousands(next.xpRequired)} XP',
                    style: TextStyle(color: Colors.white.withValues(alpha: 0.85), fontSize: 11.5)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _levelCircle(MyLevel data, {required bool isCharm}) {
    return Container(
      width: 84,
      height: 84,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.18),
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2),
      ),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(isCharm ? Icons.favorite_rounded : Icons.diamond_rounded, color: Colors.white, size: 22),
          Text('${data.level}', style: const TextStyle(fontFamily: 'Poppins', fontWeight: FontWeight.w700, fontSize: 20, color: Colors.white)),
        ],
      ),
    );
  }

  /// The level's picture from the panel, dimmed with a lock while it is not reached yet; the medal when the panel set none (or while it is read).
  Widget _levelArt(LevelThreshold t, {required String track, required bool unlocked}) {
    final medal = _medal(unlocked);
    final url = _images.urlFor(track, t.level);
    if (url == null) return medal;
    return SizedBox(
      height: kLevelArtSize,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Opacity(
            opacity: unlocked ? 1 : 0.4,
            child: LevelPicture(key: ValueKey('level-art-$track-${t.level}-$url'), url: url, size: kLevelArtSize, fallback: medal, loader: widget.pictureLoader),
          ),
          if (!unlocked)
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                key: ValueKey('level-lock-$track-${t.level}'),
                width: 20,
                height: 20,
                decoration: BoxDecoration(color: AppColors.card, shape: BoxShape.circle, border: Border.all(color: AppColors.stroke)),
                child: const Icon(Icons.lock_outline_rounded, size: 12, color: AppColors.textMuted),
              ),
            ),
        ],
      ),
    );
  }

  Widget _medal(bool unlocked) {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: unlocked ? AppColors.primary.withValues(alpha: 0.16) : Colors.white.withValues(alpha: 0.05),
        border: Border.all(color: unlocked ? AppColors.primaryBright : AppColors.stroke),
      ),
      alignment: Alignment.center,
      child: Icon(
        unlocked ? Icons.military_tech_rounded : Icons.lock_outline_rounded,
        size: 20,
        color: unlocked ? AppColors.primaryBright : AppColors.textMuted,
      ),
    );
  }

  Widget _levelCard(LevelThreshold t, {required String track, required bool current, required bool unlocked}) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
            color: current ? AppColors.primaryBright : AppColors.stroke,
            width: current ? 1.6 : 1),
      ),
      // scaled down rather than overflowing when the phone's text size is large
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _levelArt(t, track: track, unlocked: unlocked),
            const SizedBox(height: 8),
            Text('Level ${t.level}',
                style: TextStyle(
                    fontFamily: 'Poppins',
                    fontWeight: FontWeight.w600,
                    fontSize: 12.5,
                    color: current ? AppColors.primaryBright : AppColors.textPrimary)),
            Text('${withThousands(t.xpRequired)} XP', style: const TextStyle(fontSize: 10.5, color: AppColors.textMuted)),
          ],
        ),
      ),
    );
  }
}
