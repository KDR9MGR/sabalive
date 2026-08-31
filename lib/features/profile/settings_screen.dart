import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/auth_controller.dart';
import '../../theme/app_colors.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _push = true;
  bool _messages = true;
  bool _readReceipts = false;
  bool _privateAccount = false;
  String _language = 'English';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 40),
        children: [
          _section('Account'),
          _tile(Icons.lock_outline_rounded, 'Account & Security'),
          _tile(Icons.shield_outlined, 'Privacy Settings'),
          _tile(Icons.block_rounded, 'Blocked Users'),
          _tile(Icons.receipt_long_rounded, 'Transaction History'),
          _section('Preferences'),
          _switch('Push Notifications', _push, (v) => setState(() => _push = v)),
          _switch('Message Notifications', _messages,
              (v) => setState(() => _messages = v)),
          _switch('Read Receipts', _readReceipts,
              (v) => setState(() => _readReceipts = v)),
          _switch('Private Account', _privateAccount,
              (v) => setState(() => _privateAccount = v)),
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
            onTap: () async {
              final choice = await showModalBottomSheet<String>(
                context: context,
                backgroundColor: AppColors.bgElevated,
                builder: (_) => SafeArea(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final l in ['English', 'Hindi', 'Tamil', 'Telugu', 'Bengali'])
                        ListTile(
                          title: Text(l),
                          onTap: () => Navigator.pop(context, l),
                        ),
                    ],
                  ),
                ),
              );
              if (choice != null) setState(() => _language = choice);
            },
          ),
          _section('Support'),
          _tile(Icons.help_outline_rounded, 'Help & FAQ'),
          _tile(Icons.description_outlined, 'Terms of Service'),
          _tile(Icons.privacy_tip_outlined, 'Privacy Policy'),
          _tile(Icons.info_outline_rounded, 'About SABALIVE', trailing: 'v1.0.0'),
          const SizedBox(height: 20),
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

  Widget _section(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
        child: Text(t.toUpperCase(),
            style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 1,
                color: AppColors.textMuted)),
      );

  Widget _tile(IconData icon, String label, {String? trailing}) => ListTile(
        leading:
            Icon(icon, color: AppColors.primaryBright, size: 20),
        title: Text(label, style: const TextStyle(fontSize: 13.5)),
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
        onTap: () {},
      );

  Widget _switch(String label, bool value, ValueChanged<bool> onChanged) =>
      SwitchListTile(
        title: Text(label, style: const TextStyle(fontSize: 13.5)),
        value: value,
        onChanged: onChanged,
        activeThumbColor: AppColors.primary,
        contentPadding: const EdgeInsets.symmetric(horizontal: 20),
      );
}
