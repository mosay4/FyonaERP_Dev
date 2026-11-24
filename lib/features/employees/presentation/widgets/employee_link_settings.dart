import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../shared/widgets/styled_snack.dart';
import '../../../branches/data/branch_api.dart';
import '../../../branches/data/branch_scope.dart';
import '../../data/employee_api.dart';
import '../../data/employee_permissions.dart';
import '../pages/employee_custom_permissions_page.dart';
import '../providers/employee_providers.dart';
import 'employee_avatar.dart';
import '../../../../core/services/connectivity_service.dart'
    show connectivityServiceProvider;
import '../../../../core/utils/country_phone_data.dart';
import '../../../../core/utils/mobile_numbering.dart';
import '../../../../shared/widgets/connectivity_widgets.dart';
import '../../../subscription/presentation/pages/phone_entry_page.dart'
    show showPhoneCountryPicker, phoneCountryFlag;

class EmployeeLinkDraft {
  const EmployeeLinkDraft({
    this.code,
    required this.permissions,
    this.branchIds,
    this.ready = false,
    this.blocked = false,
  });
  final String? code;
  final Map<String, bool> permissions;
  final List<String>? branchIds;
  final bool ready;
  final bool blocked;
}

/// The same identity confirmation and access controls in add, edit and link.
class EmployeeLinkSettings extends ConsumerStatefulWidget {
  const EmployeeLinkSettings({
    super.key,
    required this.onChanged,
    this.linked = false,
    this.permissions = const {},
    this.branchIds,
    this.employeeId,
    this.initialCode,
  });
  final ValueChanged<EmployeeLinkDraft> onChanged;
  final bool linked;
  final Map<String, bool> permissions;
  final List<String>? branchIds;
  final String? employeeId;
  final String? initialCode;
  @override
  ConsumerState<EmployeeLinkSettings> createState() =>
      _EmployeeLinkSettingsState();
}

class _EmployeeLinkSettingsState extends ConsumerState<EmployeeLinkSettings> {
  final _input = TextEditingController();

  /// Search by the 6-digit public code, or by phone with its country code.
  bool _byPhone = false;
  PhoneCountry _country = kPhoneCountries.first;
  late Map<String, bool> _permissions = {
    ...defaultEmployeePermissions(),
    ...widget.permissions,
  };
  late bool _full = _permissions.values.every((v) => v);
  List<Map<String, dynamic>> _branches = [];
  final Set<String> _selected = {};
  bool _loading = true;
  bool _branchError = false;
  bool _searching = false;
  String? _confirmedCode;
  String? _confirmedName;
  String? _warning;
  bool get _confirmed => widget.linked || _confirmedCode != null;
  bool get _ar => Localizations.localeOf(context).languageCode == 'ar';
  String _t(String ar, String en) => _ar ? ar : en;

  @override
  void initState() {
    super.initState();
    _input.text = widget.initialCode ?? '';
    _loadBranches();
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _emit() => widget.onChanged(
    EmployeeLinkDraft(
      code: _confirmedCode,
      blocked: _warning != null,
      permissions: Map.of(_permissions),
      branchIds: !_loading && !_branchError
          ? (_branches.isEmpty ? null : (_selected.toList()..sort()))
          : widget.branchIds,
      ready:
          _warning == null &&
          !_loading &&
          !_branchError &&
          (_branches.isEmpty || _selected.isNotEmpty),
    ),
  );

  Future<void> _loadBranches() async {
    try {
      final rows = await ref.read(branchApiProvider).list();
      if (!mounted) return;
      setState(() {
        _branches = rows
            .where((b) => b['is_archived'] != true && b['is_active'] != false)
            .toList();
        final initial = widget.branchIds?.toSet();
        _selected.clear();
        for (final b in _branches) {
          final id = '${b['id']}';
          if (initial != null
              ? initial.contains(id)
              : BranchScope.branchId != null && !BranchScope.allMode
              ? id == BranchScope.branchId
              : true) {
            _selected.add(id);
          }
        }
        _loading = false;
        _branchError = false;
      });
      _emit();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _branchError = true;
      });
      _emit();
    }
  }

  String _digits(String input) => String.fromCharCodes(
    input.trim().runes.map(
      (c) => c >= 0x660 && c <= 0x669
          ? c - 0x660 + 48
          : c >= 0x6f0 && c <= 0x6f9
          ? c - 0x6f0 + 48
          : c,
    ),
  );

  String _query() {
    final digits = _digits(_input.text);
    if (!_byPhone || digits.isEmpty) return digits;
    // The country code in front of the national number (without its 0).
    return '${_country.cc}${digits.replaceFirst(RegExp(r'^0+'), '')}';
  }

  Future<void> _search() async {
    final query = _query();
    if (query.isEmpty || _searching) return;
    if (_byPhone) {
      // Exact length and a real operator start for the chosen country.
      final problem = mobileNumberProblem(_country, _input.text, arabic: _ar);
      if (problem != null) {
        showFyonaSnack(context, problem, success: false);
        return;
      }
    }
    if (!_byPhone && query.length != 6) {
      showFyonaSnack(
        context,
        _t(
          'الرقم المميز 6 أرقام بالضبط',
          'The public code is exactly 6 digits',
        ),
        success: false,
      );
      return;
    }
    FocusScope.of(context).unfocus();
    // Finding an account needs the internet: the same notice as every
    // internet-only button.
    final connectivity = ref.read(connectivityServiceProvider);
    if (!connectivity.isOnline) {
      final retry = await showOfflineDialog(
        context,
        connectivity: connectivity,
      );
      if (!retry || !mounted) return;
    }
    setState(() => _searching = true);
    try {
      final user = await ref.read(employeeApiProvider).lookup(query);
      if (!mounted || _query() != query) return;
      final warning = user['already_employee'] == true
          ? 'هذا الموظف مضاف عندك من قبل، ما ينفع تضيفه مرتين'
          : user['pending_invitation'] == true
          ? 'عندك طلب توظيف له لسه ما رد. اطلب منه يوافق على الطلب السابق.'
          : user['existing_employee'] == true &&
                user['existing_employee_id'] != widget.employeeId
          ? 'عندك ملف لهذا الموظف، افتح الملف الموجود واربطه.'
          : null;
      if (warning != null) {
        setState(() {
          _warning = warning;
          _confirmedCode = null;
          _confirmedName = null;
        });
        _emit();
        return;
      }
      setState(() => _warning = null);
      final accepted = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              EmployeeAvatar(photo: user['photo_url'] as String?, size: 76),
              const SizedBox(height: 12),
              Text(
                '${user['name'] ?? ''}',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                query,
                key: const ValueKey('lookup-identifier'),
                textDirection: TextDirection.ltr,
                style: TextStyle(
                  fontFamily: 'Cairo',
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                _t(
                  'هذا هو الموظف اللي تقصده؟',
                  'Is this the employee you mean?',
                ),
                textAlign: TextAlign.center,
                style: const TextStyle(fontFamily: 'Cairo'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(_t('لا، مو هو', 'No')),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppColors.success),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(_t('نعم، هذا هو', 'Yes, confirm')),
            ),
          ],
        ),
      );
      if (!mounted) return;
      setState(() {
        _confirmedCode = accepted == true ? query : null;
        _confirmedName = accepted == true ? '${user['name'] ?? ''}' : null;
        if (accepted != true) _input.clear();
      });
      _emit();
    } catch (e) {
      if (mounted && isConnectionError(e)) {
        setState(() => _searching = false);
        await showOfflineDialog(
          context,
          connectivity: ref.read(connectivityServiceProvider),
        );
      } else if (mounted) {
        showFyonaSnack(context, EmployeeApi.message(e), success: false);
      }
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  void _setMode(bool byPhone) {
    if (_byPhone == byPhone) return;
    setState(() {
      _byPhone = byPhone;
      _input.clear();
      _warning = null;
      _confirmedCode = null;
      _confirmedName = null;
    });
    _emit();
  }

  Widget _modeChip(String ar, String en, bool byPhone) => ChoiceChip(
    label: Text(
      _t(ar, en),
      style: const TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.w700),
    ),
    selected: _byPhone == byPhone,
    onSelected: (_) => _setMode(byPhone),
    selectedColor: AppColors.primary.withValues(alpha: 0.14),
  );

  Future<void> _custom() async {
    final value = await Navigator.of(context).push<Map<String, bool>>(
      MaterialPageRoute(
        builder: (_) => EmployeeCustomPermissionsPage(value: _permissions),
      ),
    );
    if (value == null || !mounted) return;
    setState(() => _permissions = Map.of(value));
    _emit();
  }

  Future<void> _setFull(bool full) async {
    setState(() {
      _full = full;
      // Custom starts from full access; explicit denials are then saved by
      // the editor, rather than forcing the merchant to enable every feature.
      _permissions = defaultEmployeePermissions();
    });
    _emit();
    if (!full) await _custom();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (!widget.linked) ...[
        Text(
          _t('ربط الموظف بحسابه', 'Link employee account'),
          style: const TextStyle(
            fontFamily: 'Cairo',
            fontSize: 15,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            _modeChip('الرقم المميز', 'Public code', false),
            _modeChip('رقم الهاتف', 'Phone number', true),
          ],
        ),
        const SizedBox(height: 8),
        // The phone reads left to right: «+967  7xxxxxxxx» — country key
        // first, then the number.
        Directionality(
          textDirection: _byPhone
              ? TextDirection.ltr
              : Directionality.of(context),
          child: TextField(
            controller: _input,
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.search,
            textDirection: TextDirection.ltr,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp('[0-9٠-٩۰-۹]')),
              if (_byPhone)
                // No leading 0 and never more digits than the country uses.
                TextInputFormatter.withFunction((old, next) {
                  final digits = nationalDigits(next.text);
                  final max = mobilePlanFor(_country).maxLength;
                  final text = digits.length > max
                      ? digits.substring(0, max)
                      : digits;
                  return TextEditingValue(
                    text: text,
                    selection: TextSelection.collapsed(offset: text.length),
                  );
                })
              else
                LengthLimitingTextInputFormatter(6),
            ],
            onSubmitted: (_) => _search(),
            onChanged: (_) {
              if (_byPhone) setState(() {}); // live check of the number
              if (_confirmedCode == null && _warning == null) return;
              setState(() {
                _warning = null;
                _confirmedCode = null;
                _confirmedName = null;
              });
              _emit();
            },
            decoration: InputDecoration(
              labelText: _byPhone
                  ? _t('رقم الهاتف', 'Phone number')
                  : _t('الرقم المميز (6 أرقام)', 'Public code (6 digits)'),
              hintText: _byPhone ? _country.example : null,
              // A start no operator of the country uses is flagged at once;
              // the length is checked when searching.
              errorText: _byPhone && _input.text.isNotEmpty
                  ? (() {
                      final problem = mobileNumberProblem(
                        _country,
                        _input.text,
                        arabic: _ar,
                      );
                      final digits = nationalDigits(_input.text);
                      final full = mobilePlanFor(
                        _country,
                      ).lengths.contains(digits.length);
                      final startOk =
                          !(problem?.contains(_ar ? 'تبدأ' : 'start') ?? false);
                      return !startOk || (full && problem != null)
                          ? problem
                          : null;
                    })()
                  : null,
              errorMaxLines: 2,
              counterText: _byPhone
                  ? '${nationalDigits(_input.text).length}/${mobilePlanFor(_country).maxLength}'
                  : null,
              // The country code sits in front of the number (left side).
              prefixIcon: !_byPhone
                  ? null
                  : InkWell(
                      onTap: () async {
                        final picked = await showPhoneCountryPicker(
                          context,
                          initial: _country.iso,
                        );
                        if (picked != null && mounted) {
                          setState(() {
                            _country = picked;
                            // Keep only what fits the new country's length.
                            final max = mobilePlanFor(picked).maxLength;
                            final digits = nationalDigits(_input.text);
                            if (digits.length > max) {
                              _input.text = digits.substring(0, max);
                            }
                          });
                        }
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              phoneCountryFlag(_country.iso),
                              style: const TextStyle(fontSize: 18),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              _country.cc,
                              textDirection: TextDirection.ltr,
                              style: const TextStyle(
                                fontFamily: 'Cairo',
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const Icon(
                              Icons.keyboard_arrow_down_rounded,
                              size: 18,
                            ),
                          ],
                        ),
                      ),
                    ),
              filled: true,
              fillColor: AppColors.surface,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: _searching ? null : _search,
          icon: const Icon(Icons.search_rounded),
          label: Text(
            _t(
              _searching ? 'نبحث…' : 'بحث عن الموظف',
              _searching ? 'Searching…' : 'Find employee',
            ),
          ),
        ),
        Text(
          _t(
            'الربط اختياري — تقدر تربطه بعدين',
            'Optional — you can link the account later',
          ),
          style: TextStyle(
            fontFamily: 'Cairo',
            fontSize: 9.5,
            color: AppColors.textSecondary,
          ),
        ),
      ],
      AnimatedSize(
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeInOut,
        child: _warning == null
            ? const SizedBox.shrink()
            : Container(
                key: const ValueKey('employee-duplicate-warning'),
                margin: const EdgeInsets.symmetric(vertical: 12),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.danger.withAlpha(18),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.danger.withAlpha(80)),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.warning_amber_rounded,
                      color: AppColors.danger,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _warning!,
                        style: const TextStyle(
                          fontFamily: 'Cairo',
                          color: AppColors.danger,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
      ),
      AnimatedSize(
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeInOut,
        child: !_confirmed
            ? const SizedBox.shrink()
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_confirmedName != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.verified_rounded,
                            color: AppColors.success,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _confirmedName!,
                              style: const TextStyle(
                                fontFamily: 'Cairo',
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      _t('صلاحيات كاملة', 'Full permissions'),
                      style: const TextStyle(
                        fontFamily: 'Cairo',
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    subtitle: Text(
                      _t(
                        'شغّلها لكل الصلاحيات، أو طفيها وحدد المسموح له.',
                        'Enable all permissions, or turn off to choose specific permissions.',
                      ),
                      style: const TextStyle(fontFamily: 'Cairo', fontSize: 10),
                    ),
                    value: _full,
                    onChanged: _setFull,
                  ),
                  if (!_full)
                    OutlinedButton.icon(
                      onPressed: _custom,
                      icon: const Icon(Icons.tune_rounded),
                      label: Text(_t('صلاحيات مخصصة', 'Custom permissions')),
                    ),
                  if (_loading) const LinearProgressIndicator(),
                  if (_branchError)
                    TextButton.icon(
                      onPressed: _loadBranches,
                      icon: const Icon(Icons.refresh_rounded),
                      label: Text(
                        _t(
                          'ما قدرنا نجيب الفروع، حاول مرة ثانية',
                          'Could not load branches. Retry',
                        ),
                      ),
                    ),
                  if (_branches.length > 1) ...[
                    const SizedBox(height: 14),
                    Text(
                      _t('الفروع اللي يديرها', 'Assigned branches'),
                      style: const TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      _t(
                        'حدد الفروع المسموحة له فقط.',
                        'Select only the branches this employee may access.',
                      ),
                      style: const TextStyle(fontFamily: 'Cairo', fontSize: 11),
                    ),
                    for (final branch in _branches)
                      CheckboxListTile.adaptive(
                        contentPadding: EdgeInsets.zero,
                        secondary: const Icon(Icons.storefront_rounded),
                        title: Text(
                          '${branch['name'] ?? ''}',
                          style: const TextStyle(fontFamily: 'Cairo'),
                        ),
                        value: _selected.contains('${branch['id']}'),
                        onChanged: (v) {
                          setState(() {
                            if (v == true) {
                              _selected.add('${branch['id']}');
                            } else {
                              _selected.remove('${branch['id']}');
                            }
                          });
                          _emit();
                        },
                      ),
                    if (_selected.isEmpty)
                      Text(
                        _t(
                          'اختر فرع واحد على الأقل',
                          'Select at least one branch',
                        ),
                        style: const TextStyle(
                          fontFamily: 'Cairo',
                          color: AppColors.danger,
                        ),
                      ),
                  ],
                ],
              ),
      ),
    ],
  );
}
