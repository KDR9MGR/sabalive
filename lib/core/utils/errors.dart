import 'package:supabase_flutter/supabase_flutter.dart';

/// Unwraps Supabase's exception types to their plain message instead of the
/// verbose `PostgrestException(message: ..., code: ...)` toString().
String friendlyError(Object error) => switch (error) {
      AuthException(:final message) => message,
      PostgrestException(:final message) => message,
      Exception() => error.toString().replaceFirst('Exception: ', ''),
      _ => error.toString(),
    };
