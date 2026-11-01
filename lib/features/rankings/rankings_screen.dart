import 'dart:async';

import '../profile/widgets/profile_labels.dart';
import 'package:flutter/material.dart' hide Text;

import '../../core/utils/errors.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/app_avatar.dart';
import '../../core/widgets/level_star.dart';
import '../../core/widgets/pills.dart';
import '../../data/models.dart';
import '../../data/rankings_repository.dart';
import '../../router/app_nav.dart';
import '../../theme/app_colors.dart';
import '../../core/i18n/text.dart';
import 'ranking_window.dart';

/// The level a Rankings row shows: Charm on the Hosts board (0), Wealth on the Gifters board (1). A level belongs to the person, so it is the same
/// in Daily, Weekly and Monthly. (The old combined `profiles.level` is not used: the panel's Levels page edits Wealth and Charm.)
Widget rankingLevelStar({required int board, required AppUser user, double size = 20}) => board == 0
    ? LevelStar.charm(level: user.charmLevel, size: size)
    : LevelStar.wealth(level: user.wealthLevel, size: size);

/// The icon next to a Rankings score. A host / agency score is DIAMONDS received (1 coin sent = 1 diamond received, so the board counts them as
/// they are credited); a gifter's score is COINS spent, so the Gifters board (1) gets the coin icon instead of the diamond.
Widget rankingScoreIcon({required int board, required double size}) => board == 1
    ? Icon(Icons.monetization_on_rounded, size: size, color: AppColors.coin)
    : Icon(Icons.diamond_rounded, size: size, color: AppColors.diamond);

class RankingsScreen extends StatefulWidget {
  const RankingsScreen({super.key});

  @override
  State<RankingsScreen> createState() => _RankingsScreenState();
}

class _RankingsScreenState extends State<RankingsScreen> with WidgetsBindingObserver {
  final _repo = RankingsRepository();

  int _board = 0; // 0 = Hosts, 1 = Gifters, 2 = Agency
  int _period = 1; // 0 = Daily, 1 = Weekly, 2 = Monthly

  bool _loading = true;
  String? _error;
  List<RankingEntry> _entries = const [];
  List<AgencyRankingEntry> _agencyEntries = const [];
  int _reqSeq = 0;

  // The boards start their day / week / month at 00:10 INDIA time (the database does it). A board left open across that moment would keep showing the
  // old period, so the screen remembers which period it fetched and fetches again when the period has changed: when the app comes back, and by a
  // once-a-minute look at the clock (no network unless the period really changed).
  Timer? _tick;
  String? _fetchedKey;
  RankingWindow get _window => RankingWindow.of(RankPeriod.values[_period]);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tick = Timer.periodic(const Duration(minutes: 1), (_) => _fetchIfPeriodChanged());
    _fetch();
  }

  @override
  void dispose() {
    _tick?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _fetchIfPeriodChanged();
  }

  void _fetchIfPeriodChanged() {
    if (!mounted || _loading) return;
    if (_window.key != _fetchedKey) _fetch();
  }

  Future<void> _fetch() async {
    _fetchedKey = _window.key;
    final seq = ++_reqSeq;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (_board == 2) {
        final entries = await _repo.fetchAgencies(RankPeriod.values[_period]);
        if (!mounted || seq != _reqSeq) return;
        setState(() {
          _agencyEntries = entries;
          _loading = false;
        });
        return;
      }
      final entries = await _repo.fetch(
        _board == 0 ? RankBoard.hosts : RankBoard.gifters,
        RankPeriod.values[_period],
      );
      if (!mounted || seq != _reqSeq) return;
      setState(() {
        _entries = entries;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || seq != _reqSeq) return;
      setState(() {
        _error = friendlyError(e);
        _loading = false;
      });
    }
  }

  void _setBoard(int i) {
    if (i == _board) return;
    setState(() => _board = i);
    _fetch();
  }

  void _setPeriod(int i) {
    if (i == _period) return;
    setState(() => _period = i);
    _fetch();
  }

  @override
  Widget build(BuildContext context) {
    final top3 = _entries.take(3).toList();
    final rest = _entries.skip(3).toList();
    final resultSlivers =
        _board == 2 ? _agencyResultSlivers() : _resultSlivers(top3, rest);

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: _fetch,
          child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 10, 12, 6),
                  child: Row(
                    children: [
                      Text('Rankings',
                          style: Theme.of(context).textTheme.headlineSmall),
                    ],
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: SegmentedTabs(
                    tabs: const ['Hosts', 'Gifters', 'Agency'],
                    index: _board,
                    onChanged: _setBoard,
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 14)),
              SliverToBoxAdapter(
                child: ChipRow(
                  items: const ['Daily', 'Weekly', 'Monthly'],
                  index: _period,
                  onChanged: _setPeriod,
                ),
              ),
              SliverToBoxAdapter(child: _periodCaption()),
              const SliverToBoxAdapter(child: SizedBox(height: 14)),
              ...resultSlivers,
            ],
          ),
        ),
      ),
    );
  }

  /// What the board covers and when it starts again, in India time ("Since 1 Nov" / "Resets on the 1st of each month at 00:10 India time").
  Widget _periodCaption() {
    final win = _window;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(win.coverage,
              style: const TextStyle(fontFamily: 'Poppins', fontWeight: FontWeight.w600, fontSize: 12.5)),
          const SizedBox(height: 2),
          Text(win.resets, style: const TextStyle(fontSize: 11.5, color: AppColors.textMuted)),
        ],
      ),
    );
  }

  List<Widget> _resultSlivers(
      List<RankingEntry> top3, List<RankingEntry> rest) {
    if (_loading) {
      return const [
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.only(top: 80),
            child: Center(child: CircularProgressIndicator()),
          ),
        ),
      ];
    }
    if (_error != null) {
      return [_messageSliver(_error!, retry: true)];
    }
    if (_entries.isEmpty) {
      return [
        _messageSliver(
          _board == 0
              ? 'No host rankings for this period yet.'
              : 'No gifter rankings for this period yet.',
        ),
      ];
    }
    return [
      if (top3.length == 3) ...[
        SliverToBoxAdapter(child: _podium(top3)),
        const SliverToBoxAdapter(child: SizedBox(height: 12)),
      ],
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 120),
        sliver: SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, i) => top3.length < 3
                ? _row(_entries[i], i + 1)
                : _row(rest[i], i + 4),
            childCount: top3.length < 3 ? _entries.length : rest.length,
          ),
        ),
      ),
    ];
  }

  List<Widget> _agencyResultSlivers() {
    if (_loading) {
      return const [
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.only(top: 80),
            child: Center(child: CircularProgressIndicator()),
          ),
        ),
      ];
    }
    if (_error != null) {
      return [_messageSliver(_error!, retry: true)];
    }
    if (_agencyEntries.isEmpty) {
      return [_messageSliver('No agency rankings for this period yet.')];
    }
    return [
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 120),
        sliver: SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, i) => _agencyRow(_agencyEntries[i], i + 1),
            childCount: _agencyEntries.length,
          ),
        ),
      ),
    ];
  }

  Widget _agencyRow(AgencyRankingEntry e, int rank) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 26,
            child: Text('$rank',
                style: const TextStyle(
                    fontFamily: 'Poppins',
                    fontWeight: FontWeight.w700,
                    color: AppColors.textMuted)),
          ),
          AppAvatar(name: e.name, size: 40),
          const SizedBox(width: 12),
          Expanded(
            child: Text(e.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontFamily: 'Poppins',
                    fontWeight: FontWeight.w600,
                    fontSize: 13.5)),
          ),
          Row(
            children: [
              const Icon(Icons.diamond_rounded,
                  size: 12, color: AppColors.diamond),
              const SizedBox(width: 3),
              Text(compactCount(e.score),
                  style: const TextStyle(
                      fontFamily: 'Poppins',
                      fontWeight: FontWeight.w600,
                      fontSize: 12.5)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _messageSliver(String text, {bool retry = false}) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(40, 80, 40, 0),
        child: Column(
          children: [
            Icon(Icons.leaderboard_outlined,
                size: 44, color: AppColors.textMuted.withValues(alpha: 0.6)),
            const SizedBox(height: 12),
            Text(text,
                textAlign: TextAlign.center,
                style:
                    const TextStyle(fontSize: 13, color: AppColors.textMuted)),
            if (retry) ...[
              const SizedBox(height: 10),
              TextButton(onPressed: _fetch, child: const Text('Retry')),
            ],
          ],
        ),
      ),
    );
  }

  Widget _row(RankingEntry e, int rank) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => AppNav.userProfile(context, e.user),
      child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 26,
            child: Text('$rank',
                style: const TextStyle(
                    fontFamily: 'Poppins',
                    fontWeight: FontWeight.w700,
                    color: AppColors.textMuted)),
          ),
          AppAvatar(name: e.user.name, imageUrl: e.user.avatarUrl, size: 40),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(e.user.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontFamily: 'Poppins',
                        fontWeight: FontWeight.w600,
                        fontSize: 13.5)),
                const SizedBox(height: 2),
                rankingLevelStar(board: _board, user: e.user),
                ProfileLabelsRow(profileId: e.user.id, compact: true),
              ],
            ),
          ),
          Row(
            children: [
              rankingScoreIcon(board: _board, size: 12),
              const SizedBox(width: 3),
              Text(compactCount(e.score),
                  style: const TextStyle(
                      fontFamily: 'Poppins',
                      fontWeight: FontWeight.w600,
                      fontSize: 12.5)),
            ],
          ),
        ],
      ),
      ),
    );
  }

  Widget _podium(List<RankingEntry> top3) {
    Widget col(int place) {
      final e = top3[place == 1 ? 0 : (place == 2 ? 1 : 2)];
      final height = place == 1 ? 120.0 : (place == 2 ? 92.0 : 76.0);
      final medal = place == 1
          ? AppColors.gold
          : (place == 2 ? const Color(0xFFC0C7D1) : const Color(0xFFCD7F32));
      return Expanded(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => AppNav.userProfile(context, e.user),
          child: Column(
          children: [
            if (place == 1)
              const Icon(Icons.workspace_premium_rounded,
                  color: AppColors.gold, size: 22),
            AppAvatar(
              name: e.user.name,
              imageUrl: e.user.avatarUrl,
              size: place == 1 ? 64 : 52,
              ring: true,
              ringColor: medal,
            ),
            const SizedBox(height: 6),
            Text(e.user.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontFamily: 'Poppins',
                    fontWeight: FontWeight.w600,
                    fontSize: 12)),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                rankingScoreIcon(board: _board, size: 11),
                const SizedBox(width: 3),
                Text(compactCount(e.score),
                    style: const TextStyle(
                        fontSize: 11, color: AppColors.textSecondary)),
              ],
            ),
            const SizedBox(height: 6),
            Container(
              height: height,
              margin: const EdgeInsets.symmetric(horizontal: 6),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    medal.withValues(alpha: 0.5),
                    AppColors.surface,
                  ],
                ),
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(14)),
                border: Border.all(color: AppColors.stroke),
              ),
              alignment: Alignment.topCenter,
              child: Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('$place',
                    style: const TextStyle(
                        fontFamily: 'Poppins',
                        fontWeight: FontWeight.w700,
                        fontSize: 20,
                        color: Colors.white)),
              ),
            ),
          ],
        ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [col(2), col(1), col(3)],
      ),
    );
  }
}
