import 'package:flutter/material.dart';

import '../../config/supabase_client.dart';
import '../../core/utils/errors.dart';
import '../../theme/app_colors.dart';

/// Renders a row from the `legal_pages` table by slug (terms / privacy /
/// community / refund …). Content is authored in the admin panel.
class LegalPageScreen extends StatefulWidget {
  const LegalPageScreen({super.key, required this.slug, required this.title});
  final String slug;
  final String title;

  @override
  State<LegalPageScreen> createState() => _LegalPageScreenState();
}

class _LegalPageScreenState extends State<LegalPageScreen> {
  bool _loading = true;
  String? _error;
  String _body = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final row = await supabase
          .from('legal_pages')
          .select('body, title')
          .eq('slug', widget.slug)
          .maybeSingle();
      if (!mounted) return;
      setState(() {
        _body = (row?['body'] as String?)?.trim() ?? '';
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = friendlyError(e);
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Text(
                _error ?? (_body.isEmpty ? 'This page has not been published yet.' : _body),
                style: const TextStyle(
                    fontSize: 13.5, height: 1.6, color: AppColors.textSecondary),
              ),
            ),
    );
  }
}
