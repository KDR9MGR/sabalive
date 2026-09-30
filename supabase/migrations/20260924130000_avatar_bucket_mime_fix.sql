-- Root cause of the reported "profile picture upload issue": the client
-- was sending Content-Type 'image/jpg' (not a registered MIME type) for
-- JPEG uploads, which the bucket's allowed_mime_types correctly rejected
-- since only 'image/jpeg' was listed. Fixed client-side (avatar_picker.dart
-- now emits 'image/jpeg'); widening the allowlist here too as a defensive
-- backstop against any other client ever sending the common-but-invalid
-- 'image/jpg' variant.
update storage.buckets
set allowed_mime_types = array['image/jpeg', 'image/jpg', 'image/png', 'image/webp']
where id = 'avatars';
