import '../../data/rankings_repository.dart' show RankPeriod;

/// The calendar the Rankings use: INDIA time (IST, UTC+5:30, no daylight saving).
///
/// The database starts every board's day, week (Monday) and month at 00:10 India time (sabalive migrations `20261101020000` and `20261101120000`),
/// whatever time zone the phone is set to, so this works out the same dates from the UTC clock and never from the phone's local time. It only decides
/// what the screen SAYS ("Since 1 Nov", when it resets) and WHEN to fetch again; the numbers themselves are always computed by the database.
const Duration _istOffset = Duration(hours: 5, minutes: 30);

/// The boards reset ten minutes after India midnight: until 00:10 the period that is ending is still the one shown, so the calendar day is read ten
/// minutes late.
const Duration _resetAfterMidnight = Duration(minutes: 10);

const List<String> _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

class RankingWindow {
  const RankingWindow._(this.period, this.startDay);

  final RankPeriod period;

  /// The first India calendar day of the current board (it starts at 00:10 that day). A date only: the year, month and day are the India date.
  final DateTime startDay;

  /// The window of [period] at [now] (default: the real clock). [now] may be in any time zone: it is an instant.
  factory RankingWindow.of(RankPeriod period, {DateTime? now}) {
    final ist = (now ?? DateTime.now()).toUtc().add(_istOffset).subtract(_resetAfterMidnight);
    final today = DateTime.utc(ist.year, ist.month, ist.day);
    final start = switch (period) {
      RankPeriod.daily => today,
      RankPeriod.weekly => today.subtract(
        Duration(days: today.weekday - DateTime.monday),
      ),
      RankPeriod.monthly => DateTime.utc(today.year, today.month, 1),
      // Lifetime has no start: today is only a placeholder, the label and the key never use it
      RankPeriod.lifetime => today,
    };
    return RankingWindow._(period, start);
  }

  /// Changes at exactly the moment (00:10 India time) the board rolls over to a new day / week / month, and not before. The screen compares it with the one it fetched with.
  String get key => period == RankPeriod.lifetime
      ? period.name // never rolls over
      : '${period.name}:${startDay.year}-${startDay.month}-${startDay.day}';

  /// "1 Nov": the start date as people read it.
  String get startLabel => '${startDay.day} ${_months[startDay.month - 1]}';

  /// What the board covers: "Today, 1 Nov" or "Since 26 Oct" (the Monday) or "Since 1 Nov". English; the screen translates the template.
  String get coverage => switch (period) {
    RankPeriod.daily => 'Today, $startLabel',
    RankPeriod.weekly || RankPeriod.monthly => 'Since $startLabel',
    RankPeriod.lifetime => 'All time, since day one',
  };

  /// When it starts again. English; the screen translates it.
  String get resets => switch (period) {
    RankPeriod.daily => 'Resets every day at 00:10 India time',
    RankPeriod.weekly => 'Resets every Monday at 00:10 India time',
    RankPeriod.monthly =>
      'Resets on the 1st of each month at 00:10 India time',
    RankPeriod.lifetime => 'Never resets',
  };
}
