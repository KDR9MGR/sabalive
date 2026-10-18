/// Does a viewer ask the host for a seat instead of sitting down at once?
///
/// Yes while the room is in a PK battle, or when the host switched "ask before someone sits" on (the setting is read from the server:
/// null = a server that does not have it, which means seats stay self-serve). A room admin or the host sits down without asking.
bool shouldAskForSeat({required bool pkFighting, required bool? roomAsks, required bool iAmModerator}) =>
    !iAmModerator && (pkFighting || roomAsks == true);
