import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../shared/providers/current_user_provider.dart';

/// A measurable unit. `group` is the measurement family used to prevent
/// incompatible pairings (you cannot attach a «لتر» to a «قطعة» product):
///   count   → العدد والتغليف (قطعة، درزن، باكيت، علبة، كرتون، كرتونة)
///   weight  → الوزن           (كيلو، جرام، طن)
///   volume  → الحجم           (لتر)
///   length  → الطول           (متر)
///   area    → المساحة         (متر مربع)
///   time    → الزمن           (ساعة، يوم)
///   service → الخدمات         (خدمة، خدمة إلكترونية)
/// `weight` is kept for the existing "بدون وزن/بالوزن" subtitle.
typedef UnitDef = ({
  String name,
  String en,
  double factor,
  bool weight,
  String group,
});

/// The standard units. Packaging units (باكيت/علبة/كرتون/كرتونة) intentionally
/// default to factor 1 — their real factor is set PER PRODUCT and must never be
/// treated as a mandatory list value.
const defaultUnits = <UnitDef>[
  (name: 'قطعة', en: 'Piece', factor: 1, weight: false, group: 'count'),
  (name: 'درزن', en: 'Dozen', factor: 12, weight: false, group: 'count'),
  (name: 'باكيت', en: 'Pack', factor: 1, weight: false, group: 'count'),
  (name: 'علبة', en: 'Box', factor: 1, weight: false, group: 'count'),
  (name: 'كرتون', en: 'Carton', factor: 1, weight: false, group: 'count'),
  (name: 'كرتونة', en: 'Carton', factor: 1, weight: false, group: 'count'),
  (name: 'كيلو', en: 'Kilo', factor: 1, weight: true, group: 'weight'),
  (name: 'جرام', en: 'Gram', factor: 1, weight: true, group: 'weight'),
  (name: 'طن', en: 'Ton', factor: 1000, weight: true, group: 'weight'),
  (name: 'لتر', en: 'Liter', factor: 1, weight: false, group: 'volume'),
  (name: 'متر', en: 'Meter', factor: 1, weight: false, group: 'length'),
  (name: 'متر مربع', en: 'Square meter', factor: 1, weight: false, group: 'area'),
  (name: 'ساعة', en: 'Hour', factor: 1, weight: false, group: 'time'),
  (name: 'يوم', en: 'Day', factor: 1, weight: false, group: 'time'),
  (name: 'خدمة', en: 'Service', factor: 1, weight: false, group: 'service'),
  (name: 'خدمة إلكترونية',
      en: 'E-service', factor: 1, weight: false, group: 'service'),
];

/// The measurement family of a known unit NAME (canonical units only).
String? unitGroupOfName(String? name) {
  final n = (name ?? '').trim();
  for (final u in defaultUnits) {
    if (u.name == n) return u.group;
  }
  return null;
}

/// All measurement groups, in display order.
const unitGroups = <String>[
  'count',
  'weight',
  'volume',
  'length',
  'area',
  'time',
  'service',
];

/// Arabic label of a measurement group (for the picker subtitles/warnings).
String unitGroupLabel(String group, {bool isAr = true}) {
  const ar = {
    'count': 'العدد والتغليف',
    'weight': 'الوزن',
    'volume': 'الحجم',
    'length': 'الطول',
    'area': 'المساحة',
    'time': 'الزمن',
    'service': 'الخدمات',
  };
  const en = {
    'count': 'Count / packaging',
    'weight': 'Weight',
    'volume': 'Volume',
    'length': 'Length',
    'area': 'Area',
    'time': 'Time',
    'service': 'Services',
  };
  final map = isAr ? ar : en;
  return map[group] ?? (isAr ? 'غير محدد' : 'Unspecified');
}

/// The merchant's own units, added manually and persisted per user. Names are
/// kept in the historical plain-list format; their measurement GROUP is stored
/// in a separate map so existing installs keep working (a legacy custom unit
/// with no stored group is treated as "unknown" = allowed, never broken).
class CustomUnitsNotifier extends StateNotifier<List<String>> {
  CustomUnitsNotifier(this._ref)
      : super(const []) {
    _load();
  }
  final Ref _ref;
  Map<String, String> _groups = {};

  String get _key => 'custom_units_${_ref.read(currentUserIdProvider)}';
  String get _groupsKey => 'custom_unit_groups_${_ref.read(currentUserIdProvider)}';

  Future<void> _load() async {
    try {
      final sp = await SharedPreferences.getInstance();
      state = sp.getStringList(_key) ?? const [];
      final raw = sp.getString(_groupsKey);
      if (raw != null && raw.isNotEmpty) {
        _groups = {
          for (final part in raw.split(';;'))
            if (part.contains('='))
              part.split('=').first: part.split('=').last,
        };
      }
    } catch (_) {}
  }

  /// The stored measurement group of a custom unit (null = legacy/unknown).
  String? groupFor(String name) => _groups[name.trim()];

  Future<void> add(String name, {String? group}) async {
    final n = name.trim();
    if (n.isEmpty) return;
    if (!state.contains(n)) {
      state = [...state, n];
    }
    if (group != null && group.isNotEmpty) {
      _groups[n] = group;
    }
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setStringList(_key, state);
      await sp.setString(
          _groupsKey,
          _groups.entries.map((e) => '${e.key}=${e.value}').join(';;'));
    } catch (_) {}
  }
}

final customUnitsProvider =
    StateNotifierProvider<CustomUnitsNotifier, List<String>>(
        (ref) => CustomUnitsNotifier(ref));
