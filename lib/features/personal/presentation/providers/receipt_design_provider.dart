import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'receipt_design_models.dart';

class PersonalReceiptDesignNotifier extends StateNotifier<Map<String, ReceiptDesignPreset>> {
  PersonalReceiptDesignNotifier() : super(_initDefaults());

  static const String unifiedKey = 'receipt_design_unified';

  /// Stash of the per-section customs, taken when unified mode is enabled
  /// so disabling it restores the designs exactly as they were — nothing
  /// the user customized is ever lost by toggling.
  static const String stashKey = 'receipt_design_stash';

  /// Retired sections (removed from the hub): their stored customs are
  /// purged on load so they can never resurface anywhere.
  static const List<String> retiredSectionIds = [
    'report', 'wallet', 'bank', 'analytics', 'bank_report',
  ];

  bool _unified = false;
  bool get unified => _unified;

  static Map<String, ReceiptDesignPreset> _initDefaults() {
    final map = <String, ReceiptDesignPreset>{};
    for (final section in personalReceiptSections) {
      map[section.id] = ReceiptDesignPreset.defaults(section.id);
    }
    return map;
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    // One-time purge of retired sections' customs.
    for (final id in retiredSectionIds) {
      try {
        await prefs.remove('receipt_design_$id');
      } catch (_) {}
    }
    _unified = prefs.getBool(unifiedKey) ?? false;
    final loaded = <String, ReceiptDesignPreset>{};
    for (final section in personalReceiptSections) {
      final key = 'receipt_design_${section.id}';
      final jsonStr = prefs.getString(key);
      if (jsonStr != null) {
        try {
          final json = jsonDecode(jsonStr) as Map<String, dynamic>;
          loaded[section.id] = ReceiptDesignPreset.fromJson(json, section.id);
        } catch (_) {
          loaded[section.id] = ReceiptDesignPreset.defaults(section.id);
        }
      } else {
        loaded[section.id] = ReceiptDesignPreset.defaults(section.id);
      }
    }
    state = loaded;
  }

  Future<void> savePreset(ReceiptDesignPreset preset) async {
    final prefs = await SharedPreferences.getInstance();
    final key = 'receipt_design_${preset.sectionId}';
    await prefs.setString(key, jsonEncode(preset.toJson()));
    state = {...state, preset.sectionId: preset};
  }

  ReceiptDesignPreset getPreset(String sectionId) {
    // Unified mode: every section renders the Default customization (the
    // hub only exposes Default then, so this is the single source of truth).
    if (_unified && sectionId != 'default') {
      return state['default'] ?? ReceiptDesignPreset.defaults('default');
    }
    return state[sectionId] ?? ReceiptDesignPreset.defaults(sectionId);
  }

  /// Enables/disables the unified receipt. Enabling STASHES the current
  /// per-section customs, then wipes every stored customization (including
  /// retired sections') and keeps only Default; disabling RESTORES the
  /// stashed designs exactly as they were (or defaults when nothing was
  /// stashed). Toggling never loses a customization.
  Future<void> setUnified(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    if (value && !_unified) {
      // Snapshot current customs BEFORE wiping.
      try {
        final stash = <String, dynamic>{};
        for (final entry in state.entries) {
          stash[entry.key] = entry.value.toJson();
        }
        await prefs.setString(stashKey, jsonEncode(stash));
      } catch (_) {}
    }
    if (value) {
      for (final section in personalReceiptSections) {
        if (section.id == 'default') continue;
        final preset = ReceiptDesignPreset.defaults(section.id);
        try {
          await prefs.setString(
              'receipt_design_${section.id}', jsonEncode(preset.toJson()));
        } catch (_) {}
      }
      for (final id in retiredSectionIds) {
        try {
          await prefs.remove('receipt_design_$id');
        } catch (_) {}
      }
      state = {
        for (final section in personalReceiptSections)
          section.id: section.id == 'default'
              ? (state['default'] ??
                  ReceiptDesignPreset.defaults('default'))
              : ReceiptDesignPreset.defaults(section.id),
      };
    } else if (_unified) {
      // Restore the stashed customs (sections absent from the stash —
      // e.g. never customized — fall back to defaults).
      try {
        final raw = prefs.getString(stashKey);
        if (raw != null && raw.isNotEmpty) {
          final stash = jsonDecode(raw) as Map<String, dynamic>;
          final restored = Map<String, ReceiptDesignPreset>.from(state);
          for (final section in personalReceiptSections) {
            final node = stash[section.id];
            if (node is Map<String, dynamic>) {
              try {
                final preset =
                    ReceiptDesignPreset.fromJson(node, section.id);
                restored[section.id] = preset;
                await prefs.setString('receipt_design_${section.id}',
                    jsonEncode(preset.toJson()));
              } catch (_) {}
            }
          }
          state = restored;
        }
      } catch (_) {}
    }
    _unified = value;
    try {
      await prefs.setBool(unifiedKey, value);
    } catch (_) {}
    // Force listeners to rebuild (the toggle reads `unified` off the
    // notifier, whose identity never changes).
    state = {...state};
  }

  void updatePreset(ReceiptDesignPreset preset) {
    state = {...state, preset.sectionId: preset};
  }

  void resetToDefaults(String sectionId) {
    final preset = ReceiptDesignPreset.defaults(sectionId);
    state = {...state, sectionId: preset};
    savePreset(preset);
  }
}

final personalReceiptDesignProvider = StateNotifierProvider<PersonalReceiptDesignNotifier, Map<String, ReceiptDesignPreset>>((ref) {
  final notifier = PersonalReceiptDesignNotifier();
  notifier.load();
  return notifier;
});
