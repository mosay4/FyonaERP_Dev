import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/services/section_scope.dart';
import '../../../../shared/providers/current_user_provider.dart';

/// Per-section profile override (name + avatar). Empty means "no override" →
/// the caller falls back to the account/Google values. Editing in one section
/// never touches the other.
class SectionProfile {
  final String? name;
  final Uint8List? avatar;
  const SectionProfile({this.name, this.avatar});
}

class SectionProfileNotifier extends StateNotifier<SectionProfile> {
  SectionProfileNotifier(this._ref) : super(const SectionProfile()) {
    reload();
  }

  final Ref _ref;

  AppSection get _section => _ref.read(activeSectionProvider);
  String get _uid => _ref.read(currentUserIdProvider);
  String get _nameKey => 'profile_name_${_section.name}_$_uid';
  String get _pathKey => 'profile_avatar_${_section.name}_$_uid';

  Future<void> reload() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final name = sp.getString(_nameKey);
      Uint8List? avatar;
      final path = sp.getString(_pathKey);
      if (path != null && path.isNotEmpty) {
        final f = File(path);
        if (await f.exists()) avatar = await f.readAsBytes();
      }
      if (!mounted) return;
      state = SectionProfile(
        name: (name == null || name.trim().isEmpty) ? null : name,
        avatar: avatar,
      );
    } catch (_) {
      if (mounted) state = const SectionProfile();
    }
  }

  Future<void> setName(String value) async {
    final v = value.trim();
    try {
      final sp = await SharedPreferences.getInstance();
      if (v.isEmpty) {
        await sp.remove(_nameKey);
      } else {
        await sp.setString(_nameKey, v);
      }
    } catch (_) {}
    if (mounted) {
      state = SectionProfile(name: v.isEmpty ? null : v, avatar: state.avatar);
    }
  }

  /// Global rename: both sections + the server account (the caller updates
  /// the server) so every screen and every linked party sees the new name.
  Future<void> setNameAll(String value) async {
    final v = value.trim();
    try {
      final sp = await SharedPreferences.getInstance();
      for (final sec in AppSection.values) {
        final key = 'profile_name_${sec.name}_$_uid';
        if (v.isEmpty) {
          await sp.remove(key);
        } else {
          await sp.setString(key, v);
        }
      }
    } catch (_) {}
    if (mounted) {
      state = SectionProfile(name: v.isEmpty ? null : v, avatar: state.avatar);
    }
  }

  Future<void> setAvatarAll(Uint8List bytes) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final sp = await SharedPreferences.getInstance();
      for (final sec in AppSection.values) {
        final file =
            File('${dir.path}/section_avatar_${sec.name}_$_uid.png');
        await file.writeAsBytes(bytes);
        await sp.setString('profile_avatar_${sec.name}_$_uid', file.path);
      }
    } catch (_) {}
    if (mounted) {
      state = SectionProfile(name: state.name, avatar: bytes);
    }
  }

  Future<void> setAvatar(Uint8List bytes) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file =
          File('${dir.path}/section_avatar_${_section.name}_$_uid.png');
      await file.writeAsBytes(bytes);
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_pathKey, file.path);
      if (mounted) {
        state = SectionProfile(name: state.name, avatar: bytes);
      }
    } catch (_) {}
  }

  Future<void> clearAvatar() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final path = sp.getString(_pathKey);
      if (path != null) {
        final f = File(path);
        if (await f.exists()) await f.delete();
      }
      await sp.remove(_pathKey);
    } catch (_) {}
    if (mounted) state = SectionProfile(name: state.name, avatar: null);
  }
}

final sectionProfileProvider =
    StateNotifierProvider<SectionProfileNotifier, SectionProfile>((ref) {
  final n = SectionProfileNotifier(ref);
  ref.listen(activeSectionProvider, (_, __) => n.reload());
  ref.listen(currentUserIdProvider, (_, __) => n.reload());
  return n;
});
