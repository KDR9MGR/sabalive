import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/utils/avatar_picker.dart';
import '../../core/utils/errors.dart';
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

const _genders = ['female', 'male', 'other'];
const _genderLabels = ['Female', 'Male', 'Other'];

class _EditProfileScreenState extends State<EditProfileScreen> {
  late final _user = context.read<AuthController>().user ?? Mock.me;
  late final _name = TextEditingController(text: _user.name);
  late final _bio = TextEditingController(text: _user.bio);
  late final _location = TextEditingController(text: _user.location);
  late int? _genderIndex =
      _user.gender == null ? null : _genders.indexOf(_user.gender!);
  late DateTime? _dob = _user.dateOfBirth;
  bool _uploadingPhoto = false;

  @override
  void dispose() {
    _name.dispose();
    _bio.dispose();
    _location.dispose();
    super.dispose();
  }

  Future<void> _pickDob() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _dob ?? DateTime(now.year - 18, now.month, now.day),
      firstDate: DateTime(now.year - 100),
      lastDate: DateTime(now.year - 13, now.month, now.day),
    );
    if (picked != null) setState(() => _dob = picked);
  }

  Future<void> _save() async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      await context.read<AuthController>().updateProfile(
            name: _name.text.trim(),
            bio: _bio.text.trim(),
            location: _location.text.trim(),
            gender: _genderIndex == null ? null : _genders[_genderIndex!],
            dateOfBirth: _dob,
          );
      navigator.pop();
      messenger.showSnackBar(const SnackBar(content: Text('Profile updated')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(friendlyError(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final avatarUrl = context.watch<AuthController>().user?.avatarUrl;
    return Scaffold(
      appBar: AppBar(title: const Text('Edit Profile')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
        children: [
          Center(
            child: GestureDetector(
              onTap: _uploadingPhoto
                  ? null
                  : () => pickAndUploadAvatar(context,
                      onBusyChanged: (busy) {
                        if (mounted) setState(() => _uploadingPhoto = busy);
                      }),
              child: Stack(
                alignment: Alignment.bottomRight,
                children: [
                  AppAvatar(name: _name.text, imageUrl: avatarUrl, size: 96, ring: true),
                  if (_uploadingPhoto)
                    Positioned.fill(
                      child: Container(
                        decoration: const BoxDecoration(
                            shape: BoxShape.circle, color: Colors.black54),
                        alignment: Alignment.center,
                        child: const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        ),
                      ),
                    ),
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
              for (final (i, g) in _genderLabels.indexed)
                Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: ChoiceChip(
                    label: Text(g),
                    selected: _genderIndex == i,
                    onSelected: (_) => setState(() => _genderIndex = i),
                    selectedColor: AppColors.primary,
                    labelStyle: TextStyle(
                      color: _genderIndex == i
                          ? Colors.white
                          : AppColors.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 20),
          _label('Date of Birth'),
          InkWell(
            onTap: _pickDob,
            borderRadius: BorderRadius.circular(10),
            child: InputDecorator(
              decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.cake_outlined)),
              child: Text(
                _dob == null
                    ? 'Select date of birth'
                    : '${_dob!.day.toString().padLeft(2, '0')}/'
                        '${_dob!.month.toString().padLeft(2, '0')}/'
                        '${_dob!.year}',
                style: TextStyle(
                    color: _dob == null
                        ? AppColors.textMuted
                        : AppColors.textPrimary),
              ),
            ),
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
