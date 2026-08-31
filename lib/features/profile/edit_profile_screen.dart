import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/widgets/app_avatar.dart';
import '../../core/widgets/gradient_button.dart';
import '../../data/mock_data.dart';
import '../../state/auth_controller.dart';
import '../../theme/app_colors.dart';

class EditProfileScreen extends StatefulWidget {
  const EditProfileScreen({super.key});

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  late final _user = context.read<AuthController>().user ?? Mock.me;
  late final _name = TextEditingController(text: _user.name);
  late final _username =
      TextEditingController(text: _user.username.replaceFirst('@', ''));
  late final _bio = TextEditingController(text: _user.bio);
  late final _location = TextEditingController(text: _user.location);
  int _gender = 0;

  @override
  void dispose() {
    _name.dispose();
    _username.dispose();
    _bio.dispose();
    _location.dispose();
    super.dispose();
  }

  void _save() {
    context.read<AuthController>().updateProfile(
          name: _name.text.trim(),
          username: '@${_username.text.trim()}',
          bio: _bio.text.trim(),
          location: _location.text.trim(),
        );
    final messenger = ScaffoldMessenger.of(context);
    Navigator.pop(context);
    messenger.showSnackBar(
      const SnackBar(content: Text('Profile updated')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Edit Profile')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
        children: [
          Center(
            child: Stack(
              alignment: Alignment.bottomRight,
              children: [
                AppAvatar(name: _name.text, size: 96, ring: true),
                Container(
                  padding: const EdgeInsets.all(7),
                  decoration: const BoxDecoration(
                    gradient: AppColors.primaryGradient,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.photo_camera_rounded,
                      size: 15, color: Colors.white),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          const Center(
            child: Text('Change Photo',
                style: TextStyle(
                    color: AppColors.primaryBright, fontSize: 12.5)),
          ),
          const SizedBox(height: 24),
          _label('Full Name'),
          TextField(
              controller: _name, onChanged: (_) => setState(() {})),
          const SizedBox(height: 16),
          _label('Username'),
          TextField(
            controller: _username,
            decoration: const InputDecoration(prefixText: '@ '),
          ),
          const SizedBox(height: 16),
          _label('Bio'),
          TextField(
            controller: _bio,
            maxLines: 3,
            maxLength: 150,
          ),
          const SizedBox(height: 8),
          _label('Location'),
          TextField(
            controller: _location,
            decoration: const InputDecoration(
                prefixIcon: Icon(Icons.location_on_outlined)),
          ),
          const SizedBox(height: 20),
          _label('Gender'),
          Row(
            children: [
              for (final (i, g) in ['Female', 'Male', 'Other'].indexed)
                Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: ChoiceChip(
                    label: Text(g),
                    selected: _gender == i,
                    onSelected: (_) => setState(() => _gender = i),
                    selectedColor: AppColors.primary,
                    labelStyle: TextStyle(
                      color: _gender == i
                          ? Colors.white
                          : AppColors.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 28),
          GradientButton(label: 'Save Changes', onPressed: _save),
        ],
      ),
    );
  }

  Widget _label(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(t,
            style: const TextStyle(
                color: AppColors.textSecondary, fontSize: 12.5)),
      );
}
