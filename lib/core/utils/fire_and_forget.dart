/// Starts a Supabase call without waiting for it.
///
/// A Supabase request (`supabase.rpc(...)`, `.from(...).update(...)`) is a lazy Future: it only goes out when
/// something awaits it or chains on it. `unawaited(call)` does neither, so the request was NEVER sent. That is why
/// "leave_live_stream" and "release_seat" in `dispose()` never reached the server and people were only removed by the
/// 90 s background sweep. This chains an error handler, which starts the request, and swallows any failure.
void fireAndForget(Future<dynamic> call) {
  call.catchError((_) => null);
}
