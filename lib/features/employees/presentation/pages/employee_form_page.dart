import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import '../../../../core/services/currency/business_currency_scope.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../shared/widgets/styled_snack.dart';
import '../../data/employee_api.dart';
import '../../data/employee_permissions.dart';
import '../providers/employee_providers.dart';
import '../widgets/employee_avatar.dart';
import '../widgets/employee_link_settings.dart';
import '../../../branches/data/branch_api.dart';
import '../../../branches/data/branch_scope.dart';
import '../../../../shared/providers/current_user_provider.dart';

class EmployeeFormPage extends ConsumerWidget {
  const EmployeeFormPage({super.key, this.id});
  final String? id;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (id == null) return const _EmployeeFormBody(initial: {});
    return ref
        .watch(employeesProvider)
        .when(
          loading: () =>
              const Scaffold(body: Center(child: CircularProgressIndicator())),
          error: (e, _) =>
              Scaffold(body: Center(child: Text(EmployeeApi.message(e)))),
          data: (rows) {
            final found = rows.where((e) => '${e['id']}' == id).firstOrNull;
            if (found == null)
              return const Scaffold(
                body: Center(child: Text('الموظف غير موجود')),
              );
            return _EmployeeFormBody(key: ValueKey(id), initial: found);
          },
        );
  }
}

class _EmployeeFormBody extends ConsumerStatefulWidget {
  const _EmployeeFormBody({super.key, required this.initial});
  final Map<String, dynamic> initial;
  @override
  ConsumerState<_EmployeeFormBody> createState() => _EmployeeFormBodyState();
}

class _EmployeeFormBodyState extends ConsumerState<_EmployeeFormBody> {
  late final _name = TextEditingController(
    text: '${widget.initial['full_name'] ?? ''}',
  );
  late final _phone = TextEditingController(
    text: '${widget.initial['phone'] ?? ''}',
  );
  late final _salary = TextEditingController(
    text: widget.initial['salary'] == null
        ? ''
        : fmtNum(widget.initial['salary']),
  );
  late String _currency = '${widget.initial['salary_currency'] ?? 'SAR'}';
  late String? _photo = widget.initial['photo_url'] as String?;
  late final Map<String, bool> _initialPermissions = {
    ...defaultEmployeePermissions(),
    ...((widget.initial['permissions'] as Map?) ?? {}).map(
      (k, v) => MapEntry('$k', v == true),
    ),
  };
  late EmployeeLinkDraft _draft = EmployeeLinkDraft(
    permissions: _initialPermissions,
    branchIds: (widget.initial['branch_ids'] as List?)
        ?.map((e) => '$e')
        .toList(),
  );
  bool _saving = false;
  bool get _editing => widget.initial.isNotEmpty;
  bool get _linked => widget.initial['status'] == 'linked';

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _salary.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto() async {
    final file = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 900,
      maxHeight: 900,
      imageQuality: 82,
    );
    if (file == null) return;
    final bytes = await file.readAsBytes();
    if (!mounted) return;
    if (bytes.length > 3 * 1024 * 1024) {
      showFyonaSnack(
        context,
        'الصورة كبيرة، خليها أقل من 3 ميجا',
        success: false,
      );
      return;
    }
    setState(() => _photo = 'data:image/jpeg;base64,${base64Encode(bytes)}');
  }

  Future<void> _pickCurrency() async {
    try {
      final codes = (await ref.read(
        bizEnabledCurrenciesProvider.future,
      )).toList()..sort();
      if (!mounted) return;
      final selected = await showModalBottomSheet<String>(
        context: context,
        backgroundColor: AppColors.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (ctx) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'عملة الراتب',
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              for (final code in codes)
                ListTile(
                  leading: Text(
                    currencyFlagEmoji(code),
                    style: const TextStyle(fontSize: 20),
                  ),
                  title: Text(
                    currencyLabel(
                      code,
                      locale: Localizations.localeOf(context).languageCode,
                    ),
                    style: const TextStyle(fontFamily: 'Cairo'),
                  ),
                  trailing: code == _currency
                      ? const Icon(
                          Icons.check_circle_rounded,
                          color: AppColors.primary,
                        )
                      : null,
                  onTap: () => Navigator.pop(ctx, code),
                ),
            ],
          ),
        ),
      );
      if (selected != null && mounted) setState(() => _currency = selected);
    } catch (e) {
      if (mounted)
        showFyonaSnack(context, EmployeeApi.message(e), success: false);
    }
  }

  Future<void> _save() async {
    if (_saving || _draft.blocked) return;
    if (_name.text.trim().length < 2) {
      showFyonaSnack(context, 'اكتب اسم الموظف', success: false);
      return;
    }
    final withAccess = _linked || _draft.code != null;
    if (withAccess && !_draft.ready) {
      showFyonaSnack(
        context,
        'تأكد من تحميل الفروع واختار فرع واحد على الأقل',
        success: false,
      );
      return;
    }
    setState(() => _saving = true);
    try {
      final body = <String, dynamic>{
        'full_name': _name.text.trim(),
        'phone': _phone.text.trim(),
        'salary': num.tryParse(_salary.text.replaceAll(',', '')) ?? 0,
        'salary_currency': _currency,
        'photo_base64': _photo,
        if (withAccess) 'permissions': _draft.permissions,
        if (withAccess && _draft.branchIds != null)
          'branch_ids': _draft.branchIds,
        if (!_editing && _draft.code != null) 'link_code': _draft.code,
      };
      final api = ref.read(employeeApiProvider);
      if (_editing) {
        await api.update('${widget.initial['id']}', body);
        if (!_linked && _draft.code != null)
          await api.invite(
            '${widget.initial['id']}',
            _draft.code!,
            _draft.permissions,
            branchIds: _draft.branchIds,
          );
      } else {
        await api.create(body);
      }
      ref.invalidate(employeesProvider);
      final org = BranchScope.organizationId ??
          ref.read(currentUserProvider)?.organizationId;
      if (org != null) ref.invalidate(myEmployeeProfileForProvider(org));
      ref.invalidate(branchAccessProvider);
      ref.invalidate(employeePermissionsProvider);
      if (!mounted) return;
      showFyonaSnack(
        context,
        _editing
            ? (!_linked && _draft.code != null
                ? 'تم حفظ التعديلات وإرسال طلب الربط'
                : 'تم حفظ التعديلات')
            : 'تم حفظ الموظف',
        success: true,
      );
      context.pop();
    } catch (e) {
      if (mounted)
        showFyonaSnack(context, EmployeeApi.message(e), success: false);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: AppColors.background,
    appBar: AppBar(
      backgroundColor: AppColors.background,
      title: Text(
        _editing ? 'تعديل الموظف' : 'إضافة موظف',
        style: const TextStyle(
          fontFamily: 'Cairo',
          fontWeight: FontWeight.w800,
        ),
      ),
    ),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Center(
          child: Column(
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  EmployeeAvatar(photo: _photo, size: 92),
                  Positioned(
                    bottom: -4,
                    left: -4,
                    child: IconButton.filled(
                      onPressed: _pickPhoto,
                      icon: const Icon(Icons.photo_camera_rounded, size: 18),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _optional('الصورة اختيارية'),
            ],
          ),
        ),
        const SizedBox(height: 18),
        _field(_name, 'اسم الموظف'),
        const SizedBox(height: 12),
        _field(_phone, 'رقم الهاتف', keyboard: TextInputType.phone),
        _optional('رقم الهاتف اختياري'),
        const SizedBox(height: 12),
        _field(
          _salary,
          'الراتب',
          keyboard: const TextInputType.numberWithOptions(decimal: true),
        ),
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerRight,
          child: OutlinedButton.icon(
            onPressed: _pickCurrency,
            icon: const Icon(Icons.currency_exchange_rounded, size: 16),
            label: Text(
              '${currencyFlagEmoji(_currency)} ${currencyLabel(_currency, locale: Localizations.localeOf(context).languageCode)}',
              style: const TextStyle(fontFamily: 'Cairo', fontSize: 11),
            ),
          ),
        ),
        _optional('الراتب وعملته اختياريين'),
        const SizedBox(height: 18),
        EmployeeLinkSettings(
          employeeId: widget.initial['id']?.toString(),
          linked: _linked,
          permissions: _initialPermissions,
          branchIds: _draft.branchIds,
          onChanged: (value) => setState(() => _draft = value),
        ),
        const SizedBox(height: 22),
        if (!_draft.blocked) FilledButton.icon(
          onPressed: _saving || _draft.blocked ? null : _save,
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.success,
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
          icon: const Icon(Icons.save_rounded),
          label: Text(
            _saving ? 'نحفظ…' : 'حفظ الموظف',
            style: const TextStyle(fontFamily: 'Cairo'),
          ),
        ),
        const SizedBox(height: 24),
      ],
    ),
  );

  Widget _optional(String text) => Padding(
    padding: const EdgeInsets.only(top: 4),
    child: Text(
      text,
      style: TextStyle(
        fontFamily: 'Cairo',
        fontSize: 9.5,
        color: AppColors.textSecondary,
      ),
    ),
  );
  Widget _field(
    TextEditingController c,
    String label, {
    TextInputType? keyboard,
  }) => TextField(
    controller: c,
    keyboardType: keyboard,
    decoration: InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(fontFamily: 'Cairo'),
      filled: true,
      fillColor: AppColors.surface,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
    ),
  );
}
