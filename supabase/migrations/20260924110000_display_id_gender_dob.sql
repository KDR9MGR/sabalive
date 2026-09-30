-- Real, server-generated, stable short id for every profile.
--
-- The app previously showed users a "short id" computed client-side as
-- `id.hashCode.abs() % 900000 + 100000` (lib/core/utils/ids.dart). Dart's
-- String.hashCode is explicitly NOT guaranteed stable across VM/web
-- compilation targets or SDK versions, and a 900k-bucket reduction of a
-- UUID collides between different users at realistic user counts. Since
-- this id is becoming the primary way users identify and search for each
-- other (replacing username), it needs to be a real, unique, stable value
-- from the database instead.
create sequence if not exists public.profiles_display_id_seq start 100000 increment 1;

alter table public.profiles add column display_id bigint;
alter table public.profiles alter column display_id set default nextval('public.profiles_display_id_seq');
update public.profiles set display_id = nextval('public.profiles_display_id_seq') where display_id is null;
alter table public.profiles alter column display_id set not null;
alter table public.profiles add constraint profiles_display_id_key unique (display_id);

-- Fields for the simplified Edit Profile form (full name, gender, DOB,
-- location, bio). Location/name/bio already existed.
alter table public.profiles add column gender text check (gender in ('female', 'male', 'other'));
alter table public.profiles add column date_of_birth date;
