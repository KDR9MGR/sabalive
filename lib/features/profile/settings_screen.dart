import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../config/supabase_client.dart';
import '../../router/app_nav.dart';
import '../../state/auth_controller.dart';
import '../../theme/app_colors.dart';
import 'blocked_users_screen.dart';
import 'legal_page_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _prefs = <String, bool>{
    'notif_push': true,
    'notif_messages': true,
    'read_receipts': false,
    'private_account': false,
  };
  String _language = 'English';
  SharedPreferences? _sp;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    final sp = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _sp = sp;
      for (final k in _prefs.keys.toList()) {
        _prefs[k] = sp.getBool('settings.$k') ?? _prefs[k]!;
      }
      _language = sp.getString('settings.language') ?? 'English';
    });
  }

  void _set(String key, bool value) {
    setState(() => _prefs[key] = value);
    _sp?.setBool('settings.$key', value);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 40),
        children: [
          _section('Account'),
          _tile(Icons.lock_outline_rounded, 'Account & Security',
              onTap: _accountSecurity),
          _tile(Icons.verified_user_outlined, 'Identity Verification',
              onTap: () => AppNav.kyc(context)),
          _tile(Icons.receipt_long_rounded, 'Wallet & Transactions',
              onTap: () => AppNav.wallet(context)),
          _tile(Icons.block_rounded, 'Blocked Users',
              onTap: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const BlockedUsersScreen()))),
          _section('Preferences'),
          _switch('Push Notifications', 'notif_push'),
          _switch('Message Notifications', 'notif_messages'),
          _switch('Read Receipts', 'read_receipts'),
          _switch('Private Account', 'private_account'),
          ListTile(
            leading: const Icon(Icons.language_rounded,
                color: AppColors.primaryBright, size: 20),
            title: const Text('Language', style: TextStyle(fontSize: 13.5)),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_language,
                    style: const TextStyle(
                        color: AppColors.textMuted, fontSize: 12.5)),
                const Icon(Icons.chevron_right_rounded,
                    color: AppColors.textMuted),
              ],
            ),
            onTap: _pickLanguage,
          ),
          _section('Support'),
          _tile(Icons.help_outline_rounded, 'Help & FAQ', onTap: _help),
          _tile(Icons.description_outlined, 'Terms of Service',
              onTap: () => _legal('terms', 'Terms of Service')),
          _tile(Icons.privacy_tip_outlined, 'Privacy Policy',
              onTap: () => _legal('privacy', 'Privacy Policy')),
          _tile(Icons.info_outline_rounded, 'About SABALIVE',
              trailing: 'v1.0.0-alpha', onTap: _about),
          _section('Danger zone'),
          _tile(Icons.delete_outline_rounded, 'Delete account',
              danger: true, onTap: _deleteAccount),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: OutlinedButton(
              onPressed: () {
                Navigator.pop(context);
                context.read<AuthController>().signOut();
              },
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.danger,
                side: const BorderSide(color: AppColors.danger),
                minimumSize: const Size.fromHeight(48),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
              child: const Text('Sign Out'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickLanguage() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.bgElevated,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final l in ['English', 'Hindi', 'Tamil', 'Telugu', 'Bengali'])
              ListTile(title: Text(l), onTap: () => Navigator.pop(context, l)),
          ],
        ),
      ),
    );
    if (choice != null) {
      setState(() => _language = choice);
      _sp?.setString('settings.language', choice);
    }
  }

  void _legal(String slug, String title) {
    Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) => LegalPageScreen(slug: slug, title: title)),
    );
  }

  void _about() {
    showAboutDialog(
      context: context,
      applicationName: 'SABALIVE',
      applicationVersion: 'v1.0.0-alpha',
      applicationLegalese: 'Live streaming, calls & virtual gifting.',
    );
  }

  void _help() {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.bgElevated,
        title: const Text('Help & Support'),
        content: const Text(
            'Need a hand during the alpha? Email support@sabalive.app and '
            'include your username and what you were doing.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK')),
        ],
      ),
    );
  }

  void _accountSecurity() {
    final auth = context.read<AuthController>();
    final email = supabase.auth.currentUser?.email ?? 'your account';
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.bgElevated,
        title: const Text('Account & Security'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Signed in as $email',
                style: const TextStyle(
                    fontSize: 12.5, color: AppColors.textMuted)),
            const SizedBox(height: 16),
            const Text(
                'To change your password we\'ll email you a reset link.',
                style: TextStyle(fontSize: 12.5)),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close')),
          TextButton(
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(context);
              Navigator.pop(context);
              final target = supabase.auth.currentUser?.email;
              if (target == null) return;
              try {
                await auth.resetPassword(target);
                messenger.showSnackBar(
                    const SnackBar(content: Text('Password reset email sent')));
              } catch (_) {
                messenger.showSnackBar(const SnackBar(
                    content: Text('Could not send reset email')));
              }
            },
            child: const Text('Send reset link'),
          ),
        ],
      ),
    );
  }

  void _deleteAccount() {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.bgElevated,
        title: const Text('Delete account'),
        content: const Text(
            'This permanently removes your profile, streams, chats, wallet '
            'and gift history. We process requests within 7 days. This '
            'can\'t be undone — are you sure?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(context);
              final navigator = Navigator.of(context);
              navigator.pop();
              try {
                await context.read<AuthController>().requestAccountDeletion();
                if (!mounted) return;
                messenger.showSnackBar(const SnackBar(
                    content: Text(
                        'Deletion request received — your account will be removed within 7 days')));
              } catch (_) {
                if (!mounted) return;
                messenger.showSnackBar(const SnackBar(
                    content: Text('Could not submit your request, please try again')));
              }
            },
            style: TextButton.styleFrom(foregroundColor: AppColors.danger),
            child: const Text('Delete my account'),
          ),
        ],
      ),
    );
  }

  Widget _section(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
        child: Text(t.toUpperCase(),
            style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 1,
                color: AppColors.textMuted)),
      );

  Widget _tile(IconData icon, String label,
          {String? trailing, VoidCallback? onTap, bool danger = false}) =>
      ListTile(
        leading: Icon(icon,
            color: danger ? AppColors.danger : AppColors.primaryBright,
            size: 20),
        title: Text(label,
            style: TextStyle(
                fontSize: 13.5,
                color: danger ? AppColors.danger : AppColors.textPrimary)),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (trailing != null)
              Text(trailing,
                  style: const TextStyle(
                      color: AppColors.textMuted, fontSize: 12)),
            const Icon(Icons.chevron_right_rounded, color: AppColors.textMuted),
          ],
        ),
        onTap: onTap,
      );

  Widget _switch(String label, String key) => SwitchListTile(
        title: Text(label, style: const TextStyle(fontSize: 13.5)),
        value: _prefs[key]!,
        onChanged: (v) => _set(key, v),
        activeThumbColor: AppColors.primary,
        contentPadding: const EdgeInsets.symmetric(horizontal: 20),
      );
}
