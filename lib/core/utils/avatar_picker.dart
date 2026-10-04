import 'package:flutter/material.dart' hide Text;
import 'package:image_picker/image_picker.dart';
import 'package:image_picker_android/image_picker_android.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:provider/provider.dart';

import '../../state/auth_controller.dart';
import '../../theme/app_colors.dart';
import 'errors.dart';
import '../i18n/text.dart';

/// Shared source/gallery sheet → pick → upload flow for the profile photo,
/// used by both the Profile screen's avatar and Edit Profile's "Change
/// Photo". [onBusyChanged] lets the caller show its own loading indicator
/// while the upload is in flight.
Future<void> pickAndUploadAvatar(
  BuildContext context, {
  required ValueChanged<bool> onBusyChanged,
}) async {
  final source = await showModalBottomSheet<ImageSource>(
    context: context,
    backgroundColor: AppColors.bgElevated,
    builder: (_) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          ListTile(
            leading: const Icon(Icons.camera_alt_outlined),
            title: const Text('Take Photo'),
            onTap: () => Navigator.pop(context, ImageSource.camera),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('Choose from Gallery'),
            onTap: () => Navigator.pop(context, ImageSource.gallery),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
  if (source == null || !context.mounted) return;
  // Use the Android system Photo Picker (image_picker otherwise falls back to
  // a generic file chooser). It needs no storage permission, which is what
  // Play's Photo and Video Permissions policy requires.
  final platform = ImagePickerPlatform.instance;
  if (platform is ImagePickerAndroid) platform.useAndroidPhotoPicker = true;
  final picked = await ImagePicker().pickImage(
    source: source,
    maxWidth: 1024,
    maxHeight: 1024,
    imageQuality: 85,
  );
  if (picked == null || !context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  final auth = context.read<AuthController>();
  onBusyChanged(true);
  try {
    final bytes = await picked.readAsBytes();
    // Must match one of the `avatars` bucket's allowed_mime_types exactly
    // ('image/jpeg', not 'image/jpg' — that's not a registered MIME type
    // and the bucket rejects it) since this becomes the upload's Content-Type.
    final ext =
        picked.mimeType == 'image/png' || picked.path.toLowerCase().endsWith('.png')
            ? 'png'
            : 'jpeg';
    await auth.uploadAvatar(bytes, extension: ext);
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(friendlyError(e))));
  } finally {
    onBusyChanged(false);
  }
}
