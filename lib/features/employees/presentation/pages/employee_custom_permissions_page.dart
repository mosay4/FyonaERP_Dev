import 'package:flutter/material.dart';
import '../../../../core/theme/app_colors.dart';
import '../../data/employee_permissions.dart';
import '../widgets/employee_permissions_editor.dart';
import '../providers/employee_navigation_guard.dart';

class EmployeeCustomPermissionsPage extends StatefulWidget {
  const EmployeeCustomPermissionsPage({super.key, required this.value});
  final Map<String, bool> value;
  @override
  State<EmployeeCustomPermissionsPage> createState() => _State();
}

class _State extends State<EmployeeCustomPermissionsPage> {
  late Map<String, bool> _value = {...widget.value};
  bool _dirty = false;
  bool _leaving = false;
  late final Future<bool> Function() _guard = _leave;
  @override
  void initState() {
    super.initState();
    employeePermissionsLeaveGuard = _guard;
  }

  @override
  void dispose() {
    if (identical(employeePermissionsLeaveGuard, _guard))
      employeePermissionsLeaveGuard = null;
    super.dispose();
  }

  Future<bool?> _confirm() => showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.surface,
      title: const Text(
        'تبغى تحفظ قبل ما تطلع؟',
        style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.w800),
      ),
      content: const Text(
        'لو طلعت بدون حفظ، أي تعديل سويته على الصلاحيات بيضيع.',
        style: TextStyle(fontFamily: 'Cairo'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('إلغاء', style: TextStyle(fontFamily: 'Cairo')),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text(
            'اطلع بدون حفظ',
            style: TextStyle(fontFamily: 'Cairo', color: AppColors.danger),
          ),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text(
            'احفظ واطلع',
            style: TextStyle(fontFamily: 'Cairo'),
          ),
        ),
      ],
    ),
  );

  Future<bool> _leave() async {
    if (_leaving) return false;
    _leaving = true;
    try {
      if (!_dirty) {
        Navigator.pop(context);
        return true;
      }
      final save = await _confirm();
      if (!mounted || save == null) return false;
      Navigator.pop(context, save ? Map<String, bool>.of(_value) : null);
      await WidgetsBinding.instance.endOfFrame;
      return true;
    } finally {
      _leaving = false;
    }
  }

  void _save() => Navigator.pop(context, Map<String, bool>.of(_value));

  Future<void> _back() async {
    await _leave();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          backgroundColor: AppColors.background,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_rounded),
            onPressed: _back,
          ),
          title: const Text('صلاحيات مخصصة',
              style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.w800)),
          actions: [
            Padding(padding: const EdgeInsetsDirectional.only(start: 16, end: 8),
              child: IconButton(key: const ValueKey('save-custom-permissions-header'),
               tooltip: 'حفظ الصلاحيات', onPressed: _save,
              icon: const Icon(Icons.check_rounded, color: AppColors.success))),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.primary.withAlpha(12),
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Text(
                'اختار بالضبط إيش تبغى الموظف يقدر يسوي. أي شيء مقفول ما راح يشوفه ولا يقدر يدخله.',
                style: TextStyle(fontFamily: 'Cairo', fontSize: 12),
              ),
            ),
            const SizedBox(height: 12),
            EmployeePermissionsEditor(
              value: _value,
              onChanged: (v) {
                setState(() {
                  _value = v;
                  _dirty = true;
                });
              },
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.save_rounded),
              label: const Text(
                'حفظ الصلاحيات',
                style: TextStyle(fontFamily: 'Cairo'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
