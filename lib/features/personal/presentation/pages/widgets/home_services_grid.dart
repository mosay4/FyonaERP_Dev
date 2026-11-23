import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../../../core/theme/app_colors.dart';
import '../../../../../core/localization/app_localizations.dart';
import '../../../../../core/router/route_names.dart';
import '../../../../../shared/widgets/two_tone_icon.dart';
import '../../../../../shared/widgets/two_tone_icons.dart';
import '../../../../../shared/widgets/connectivity_widgets.dart';
import '../../../../../shared/services/notification_service.dart';
import '../../../../../shared/providers/platform_controls_provider.dart';
import '../../../../../core/services/connectivity_service.dart';
import '../../widgets/add_transaction_sheet.dart';
import '../../providers/merchant_unread_provider.dart';
import 'package:fyona_flutter/core/responsive/r_api.dart';

const _kPrefsKey = 'home_quick_actions_selected';

final allActionItems = [
  _ActionItem('homeServiceAddIncome', TwoToneIcons.deposit, RouteNames.personalTransactions, initialType: 'income'),
  _ActionItem('homeServiceAddExpense', TwoToneIcons.withdraw, RouteNames.personalTransactions, initialType: 'expense'),
  _ActionItem('homeServiceAccountTree', TwoToneIcons.layers, RouteNames.financialTree),
  _ActionItem('homeServiceAccounts', TwoToneIcons.bank, RouteNames.personalBanks),
  _ActionItem('homeServiceMerchantAccounts', TwoToneIcons.debt, RouteNames.personalMerchantAccounts),
  _ActionItem('homeServiceSara', TwoToneIcons.sara, RouteNames.personalAi),
  _ActionItem('homeServiceTransactions', TwoToneIcons.transfer, RouteNames.personalTransactions),
  _ActionItem('homeServiceDebts', TwoToneIcons.debt, RouteNames.personalDebts),
  _ActionItem('homeServiceBudget', TwoToneIcons.budget, RouteNames.personalBudget),
  _ActionItem('homeServiceBackup', TwoToneIcons.document, RouteNames.personalBackup),
];

/// Temporarily hidden quick actions — items stay in [allActionItems] so they
/// can be restored later by removing the key from this set.
/// - homeServiceAccountTree: tree button hidden everywhere on user request.
/// - homeServiceBackup: hidden from home quick actions (still in Settings/Profile).
const _hiddenQuickActionKeys = {'homeServiceAccountTree', 'homeServiceBackup'};

/// Actions shown in the grid and in the customize sheet.
List<_ActionItem> get visibleActionItems =>
    allActionItems.where((a) => !_hiddenQuickActionKeys.contains(a.key)).toList();

_ActionItem _actionByKey(String key) =>
    allActionItems.firstWhere((a) => a.key == key);

class HomeServicesGrid extends ConsumerStatefulWidget {
  HomeServicesGrid({super.key});

  @override
  ConsumerState<HomeServicesGrid> createState() => _HomeServicesGridState();
}

class _HomeServicesGridState extends ConsumerState<HomeServicesGrid> {
  List<_ActionItem> _selectedQuickActions = [];

  /// Default quick actions: add income, add expense, transactions.
  static final _defaultQuickActions = [
    _actionByKey('homeServiceAddIncome'),
    _actionByKey('homeServiceAddExpense'),
    _actionByKey('homeServiceTransactions'),
  ];

  final _row2 = [
    allActionItems[3],
    allActionItems[4],
    allActionItems[5],
  ];

  @override
  void initState() {
    super.initState();
    _loadSelected();
  }

  Future<void> _loadSelected() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kPrefsKey);
    if (raw != null) {
      final List<dynamic> keys = jsonDecode(raw);
      final items = keys
          .map((k) => allActionItems.where((a) => a.key == k).firstOrNull)
          .whereType<_ActionItem>()
          .where((a) => !_hiddenQuickActionKeys.contains(a.key))
          .toList();
      if (items.length == 3) {
        setState(() => _selectedQuickActions = items);
        return;
      }
    }
    setState(() => _selectedQuickActions = List.from(_defaultQuickActions));
  }

  Future<void> _saveSelected(List<_ActionItem> items) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kPrefsKey, jsonEncode(items.map((i) => i.key).toList()));
    setState(() => _selectedQuickActions = items);
  }

  void _showEditSheet() {
    final l10n = AppLocalizations.of(context);
    List<_ActionItem> tempSelected = List.from(_selectedQuickActions);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, MediaQuery.of(ctx).viewInsets.bottom + 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Text(l10n.translate('homeCustomizeQuickActions'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 16), fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
                  const Spacer(),
                  Text('${tempSelected.length}/3', style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), color: AppColors.textSecondary)),
                ]),
                const SizedBox(height: 8),
                Text(l10n.translate('homeChoose3QuickActions'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 12), color: AppColors.textDisabled)),
                const SizedBox(height: 12),
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: visibleActionItems.length,
                    itemBuilder: (_, i) {
                      final item = visibleActionItems[i];
                      final selected = tempSelected.any((s) => s.key == item.key);
                      return ListTile(
                        leading: TwoToneIcon(
                          data: item.icon,
                          size: 24,
                          outlineColor: selected ? AppColors.primary : AppColors.textSecondary,
                          detailColor: selected ? AppColors.primary : AppColors.textSecondary,
                        ),
                        title: Text(l10n.translate(item.key), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), fontWeight: selected ? FontWeight.w700 : FontWeight.w500, color: AppColors.textPrimary)),
                        trailing: Checkbox(
                          value: selected,
                          activeColor: AppColors.primary,
                          onChanged: (v) {
                            setSheetState(() {
                              if (v == true && tempSelected.length < 3) {
                                tempSelected.add(item);
                              } else if (v == false) {
                                tempSelected.removeWhere((s) => s.key == item.key);
                              }
                            });
                          },
                        ),
                        onTap: () {
                          setSheetState(() {
                            if (selected) {
                              tempSelected.removeWhere((s) => s.key == item.key);
                            } else if (tempSelected.length < 3) {
                              tempSelected.add(item);
                            }
                          });
                        },
                      );
                    },
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton(
                    onPressed: tempSelected.length == 3
                        ? () { _saveSelected(tempSelected); Navigator.pop(ctx); }
                        : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      disabledBackgroundColor: AppColors.primary.withAlpha(80),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(l10n.translate('saveChanges'), maxLines: 1, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 14), fontWeight: FontWeight.w700, color: Colors.white)),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final badgeCount = ref.watch(saraBadgeCountProvider);
    final l10n = AppLocalizations.of(context);
    final q = _selectedQuickActions.isNotEmpty ? _selectedQuickActions : _defaultQuickActions;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        children: [
          Row(children: [
            Text(
              l10n.translate('quickActions'),
              style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 15), fontWeight: FontWeight.w700, color: AppColors.textPrimary),
            ),
            const Spacer(),
            GestureDetector(
              onTap: _showEditSheet,
              child: Container(
                padding: EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: AppColors.primary.withAlpha(16),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.primary.withAlpha(40)),
                ),
                child: Icon(Icons.edit_outlined, size: 16, color: AppColors.primary),
              ),
            ),
          ]),
          const SizedBox(height: 10),
          Row(
            children: q.map((item) => Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: _ActionCard(item: item),
              ),
            )).toList(),
          ),
          SizedBox(height: 12),
          Text(
            l10n.translate('financialManagement'),
            style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 15), fontWeight: FontWeight.w700, color: AppColors.textPrimary),
          ),
          const SizedBox(height: 10),
          Row(
            children: _row2.map((item) => Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: item.key == 'homeServiceSara' && badgeCount > 0
                    ? _SaraActionCard(item: item, badgeCount: badgeCount)
                    : _ActionCard(item: item),
              ),
            )).toList(),
          ),
        ],
      ),
    );
  }
}

String _featureKeyForItem(_ActionItem item) {
  if (item.initialType == 'income') return 'personal/transactions/add-income';
  if (item.initialType == 'expense') return 'personal/transactions/add-expense';
  final r = item.route;
  return r.startsWith('/') ? r.substring(1) : r;
}

bool _isFeatureUnderMaintenance(WidgetRef ref, _ActionItem item) {
  final ctrl = ref.read(platformControlsProvider).valueOrNull;
  if (ctrl == null) return false;
  return ctrl.isRouteUnderMaintenance('/${_featureKeyForItem(item)}') || ctrl.isFeatureDisabled(_featureKeyForItem(item));
}

class _SaraActionCard extends ConsumerWidget {
  final _ActionItem item;
  final int badgeCount;
  const _SaraActionCard({required this.item, required this.badgeCount});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final isMaintenance = _isFeatureUnderMaintenance(ref, item);
    return GestureDetector(
      onTap: () {
        // صيانة الميزة تُدار مركزيًا في الـ router guard: التنقل يفتح صفحة
        // الصيانة تلقائيًا (لا حجب هنا حتى لا تتعارض الضوابط).
        ref.read(saraBadgeCountProvider.notifier).state = 0;
        HapticFeedback.lightImpact();
        // Sara (AI) requires a network connection to talk to the cloud.
        final connectivity = ref.read(connectivityServiceProvider);
        if (!connectivity.isOnline) {
          showOfflineDialog(context, connectivity: connectivity).then((retryOk) {
            if (retryOk) context.push(item.route);
          });
          return;
        }
        context.push(item.route);
      },
      child: Container(
        padding: EdgeInsets.symmetric(vertical: 14, horizontal: 4),
        decoration: BoxDecoration(
          color: isMaintenance ? AppColors.danger.withAlpha(15) : AppColors.surface,
          border: Border.all(color: isMaintenance ? AppColors.danger.withAlpha(80) : AppColors.primary.withAlpha(80)),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                TwoToneIcon(
                  data: item.icon,
                  size: 32,
                  outlineColor: isMaintenance ? AppColors.danger.withAlpha(150) : AppColors.textSecondary,
                  detailColor: isMaintenance ? AppColors.danger : AppColors.primary,
                ),
                if (!isMaintenance && badgeCount > 0)
                  Positioned(
                    top: -4, left: -4,
                    child: Container(
                      padding: EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: AppColors.primary,
                        shape: BoxShape.circle,
                        border: Border.all(color: AppColors.surface, width: 2),
                      ),
                      child: Text(
                        '$badgeCount',
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                if (isMaintenance)
                  Positioned(
                    top: -4, right: -4,
                    child: Container(
                      width: 18, height: 18,
                      decoration: BoxDecoration(
                        color: AppColors.danger,
                        shape: BoxShape.circle,
                        border: Border.all(color: AppColors.surface, width: 1.5),
                      ),
                      child: const Icon(Icons.build_rounded, size: 10, color: Colors.white),
                    ),
                  ),
              ],
            ),
            SizedBox(height: 8),
            Text(
              l10n.translate(item.key),
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 11),
                fontWeight: FontWeight.w600,
                color: isMaintenance ? AppColors.danger : AppColors.primary,
              ),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionCard extends StatefulWidget {
  final _ActionItem item;
  const _ActionCard({required this.item});

  @override
  State<_ActionCard> createState() => _ActionCardState();
}

class _ActionCardState extends State<_ActionCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _scaleAnim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      duration: Duration(milliseconds: 120),
      vsync: this,
    );
    _scaleAnim = Tween<double>(begin: 1.0, end: 0.96).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Consumer(
      builder: (context, ref, _) {
        final isMaintenance = _isFeatureUnderMaintenance(ref, widget.item);
        final unread = widget.item.key == 'homeServiceMerchantAccounts'
            ? (ref.watch(debtUnreadProvider('personal')).valueOrNull ?? 0)
            : 0;
        return Stack(fit: StackFit.passthrough, clipBehavior: Clip.none, children: [
          GestureDetector(
        onTapDown: (_) => _ctrl.forward(),
        onTapUp: (_) {
        _ctrl.reverse();
        final item = widget.item;
        HapticFeedback.lightImpact();
        if (item.initialType != null) {
          showAddTransactionSheet(context, initialType: item.initialType!);
        } else {
          context.push(item.route);
        }
      },
      onTapCancel: () => _ctrl.reverse(),
      child: ScaleTransition(
        scale: _scaleAnim,
        child: Container(
          padding: EdgeInsets.symmetric(vertical: 14, horizontal: 4),
          decoration: BoxDecoration(
            color: isMaintenance ? AppColors.danger.withAlpha(15) : AppColors.surface,
            border: Border.all(
              color: isMaintenance ? AppColors.danger.withAlpha(80) : AppColors.border,
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  TwoToneIcon(
                    data: widget.item.icon,
                    size: 32,
                    outlineColor: isMaintenance ? AppColors.danger.withAlpha(150) : AppColors.textSecondary,
                    detailColor: isMaintenance ? AppColors.danger : AppColors.primary,
                  ),
                  if (isMaintenance)
                    Positioned(
                      top: -4, right: -4,
                      child: Container(
                        width: 18, height: 18,
                        decoration: BoxDecoration(
                          color: AppColors.danger,
                          shape: BoxShape.circle,
                          border: Border.all(color: AppColors.surface, width: 1.5),
                        ),
                        child: const Icon(Icons.build_rounded, size: 10, color: Colors.white),
                      ),
                    ),
                ],
              ),
                SizedBox(height: 8),
              Text(
                l10n.translate(widget.item.key),
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: R.fontSize(context, 11),
                  fontWeight: FontWeight.w600,
                  color: isMaintenance ? AppColors.danger : AppColors.textPrimary,
                ),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    ),
          if (unread > 0)
            PositionedDirectional(
              top: 3,
              end: 3,
              child: Container(
                width: 11,
                height: 11,
                decoration: BoxDecoration(
                  color: AppColors.danger,
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.surface, width: 1.5),
                ),
              ),
            ),
        ]);
      },
    );
  }
}

class _ActionItem {
  final String key;
  final TwoToneIconData icon;
  final String route;
  final String? initialType;
  const _ActionItem(this.key, this.icon, this.route, {this.initialType});
}
