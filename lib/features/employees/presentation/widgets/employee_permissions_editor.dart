import 'package:flutter/material.dart';
import 'package:hugeicons/hugeicons.dart';
import '../../../../core/theme/app_colors.dart';
import '../../data/employee_permissions.dart';

class EmployeePermissionsEditor extends StatefulWidget {
  const EmployeePermissionsEditor({
    super.key,
    required this.value,
    required this.onChanged,
  });
  final Map<String, bool> value;
  final ValueChanged<Map<String, bool>> onChanged;
  @override
  State<EmployeePermissionsEditor> createState() =>
      _EmployeePermissionsEditorState();
}

class _EmployeePermissionsEditorState extends State<EmployeePermissionsEditor> {
  late Map<String, bool> _value;

  static const icons = <String, List<List<dynamic>>>{
    'dashboard': HugeIcons.strokeRoundedHome01,
    'ai': HugeIcons.strokeRoundedMagicWand01,
    'reports': HugeIcons.strokeRoundedAnalytics01,
    'reconciliation': HugeIcons.strokeRoundedCheckmarkBadge01,
    'banks': HugeIcons.strokeRoundedBank,
    'sales': HugeIcons.strokeRoundedInvoice01,
    'purchases': HugeIcons.strokeRoundedShoppingBag01,
    'returns': HugeIcons.strokeRoundedArrowTurnBackward,
    'invoices': HugeIcons.strokeRoundedInvoice03,
    'inventory': HugeIcons.strokeRoundedPackage,
    'customers': HugeIcons.strokeRoundedUserGroup,
    'suppliers': HugeIcons.strokeRoundedTruckDelivery,
    'debts': HugeIcons.strokeRoundedHandCoins,
    'branches': HugeIcons.strokeRoundedBuilding03,
    'suggestions': HugeIcons.strokeRoundedIdea01,
    'notifications': HugeIcons.strokeRoundedNotification01,
    'chat': HugeIcons.strokeRoundedMessage01,
    'transfers': HugeIcons.strokeRoundedArrowDataTransferHorizontal,
  };

  @override
  void initState() {
    super.initState();
    _value = {...defaultEmployeePermissions(), ...widget.value};
  }

  void _emit() => widget.onChanged({..._value});

  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (final key in employeePermissionOrder)
        if (employeePermissionGroups.containsKey(key))
          _groupCard(key, employeePermissionGroups[key]!),
    ],
  );

  Widget _groupCard(String key, List<String> children) {
    final arabic = Localizations.localeOf(context).languageCode == 'ar';
    final enabled = _value[key] == true;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: enabled ? AppColors.primary.withAlpha(70) : AppColors.border,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 2,
            ),
            childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
            leading: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: enabled
                    ? AppColors.primary.withAlpha(20)
                    : AppColors.background,
                borderRadius: BorderRadius.circular(12),
              ),
              child: HugeIcon(
                icon: icons[key] ?? HugeIcons.strokeRoundedCircle,
                size: 22,
                color: enabled ? AppColors.primary : AppColors.textSecondary,
              ),
            ),
            title: Text(
              employeeGroupLabel(key, arabic: arabic),
              style: const TextStyle(
                fontFamily: 'Cairo',
                fontWeight: FontWeight.w800,
                fontSize: 14,
              ),
            ),
            subtitle: Text(
              employeeGroupDescription(key, arabic: arabic),
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: 10,
                color: AppColors.textSecondary,
              ),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Switch(
                  value: enabled,
                  onChanged: (v) {
                    setState(() {
                      _value[key] = v;
                      for (final c in children) _value['$key.$c'] = v;
                    });
                    _emit();
                  },
                ),
                const Icon(Icons.keyboard_arrow_down_rounded),
              ],
            ),
            children: [
              if (children.isEmpty)
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(
                    arabic
                        ? (enabled
                              ? 'الموظف يقدر يدخل هذا القسم'
                              : 'الموظف ما يقدر يدخل هذا القسم')
                        : (enabled
                              ? 'The employee can access this section'
                              : 'The employee cannot access this section'),
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 11,
                      color: AppColors.textSecondary,
                    ),
                  ),
                )
              else
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    for (final c in children)
                      FilterChip(
                        label: Text(
                          employeeChildLabel(c, arabic: arabic),
                          style: const TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 11,
                          ),
                        ),
                        selected: _value['$key.$c'] == true,
                        onSelected: (v) {
                          setState(() => _value['$key.$c'] = v);
                          _emit();
                        },
                      ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}
