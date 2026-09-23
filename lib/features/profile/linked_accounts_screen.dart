import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../config/supabase_client.dart';
import '../../core/utils/errors.dart';
import '../../theme/app_colors.dart';

/// Real linked-identity view — Supabase Auth's own `currentUser.identities`,
/// no separate table needed (GoTrue already tracks this per user). Lets you
/// unlink a secondary provider; never the last one, or you'd lock yourself
/// out. Linking a *new* provider from here isn't wired up yet — that needs
/// `getLinkIdentityUrl` + an external browser redirect through the same
/// authRedirectUrl flow regular sign-in already uses; deferred rather than
/// rushed.
class LinkedAccountsScreen extends StatefulWidget {
  const LinkedAccountsScreen({super.key});

  @override
  State<LinkedAccountsScreen> createState() => _LinkedAccountsScreenState();
}

class _LinkedAccountsScreenState extends State<LinkedAccountsScreen> {
  bool _busy = false;

  static const _labels = {
    'email': ('Email', Icons.email_rounded),
    'phone': ('Phone', Icons.phone_rounded),
    'google': ('Google', Icons.g_mobiledata_rounded),
    'apple': ('Apple', Icons.apple_rounded),
    'facebook': ('Facebook', Icons.facebook_rounded),
  };

  Future<void> _unlink(UserIdentity identity, int totalLinked) async {
    if (_busy) return;
    if (totalLinked <= 1) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text("Can't unlink your only sign-in method"),
      ));
      return;
    }
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await supabase.auth.unlinkIdentity(identity);
      if (mounted) setState(() {});
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(friendlyError(e))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final identities = supabase.auth.currentUser?.identities ?? const [];
    return Scaffold(
      appBar: AppBar(title: const Text('Linked Accounts')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
        children: [
          for (final identity in identities)
            _tile(identity, identities.length),
          if (identities.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 40),
              child: Center(
                child: Text('No linked accounts found',
                    style: TextStyle(color: AppColors.textMuted, fontSize: 13)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _tile(UserIdentity identity, int total) {
    final (label, icon) = _labels[identity.provider] ?? (identity.provider, Icons.link_rounded);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.stroke),
      ),
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(icon, color: AppColors.primaryBright, size: 22),
        title: Text(label,
            style: const TextStyle(
                fontFamily: 'Poppins', fontWeight: FontWeight.w600, fontSize: 13.5)),
        subtitle: const Text('Linked',
            style: TextStyle(fontSize: 11, color: AppColors.success)),
        trailing: total > 1
            ? TextButton(
                onPressed: () => _unlink(identity, total),
                child: const Text('Unlink', style: TextStyle(color: AppColors.danger)),
              )
            : null,
      ),
    );
  }
}
