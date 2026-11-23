import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../shared/widgets/two_tone_icon.dart';
import '../../../../shared/widgets/two_tone_icons.dart';
import '../../../../shared/widgets/dots_loader.dart';
import '../../../../core/help/information_clicker.dart';
import '../../data/models/personal_models.dart';
import '../providers/personal_providers.dart';
import '../providers/receipt_design_provider.dart';
import '../providers/receipt_design_models.dart';
import '../../../../shared/widgets/receipt/receipt_modal.dart';
import '../../../../shared/widgets/receipt/receipt_data.dart';
import '../../../../core/utils/currency_formatter.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';

String _catLabel(String category, AppLocalizations l10n) {
  final key = personalCategoryKey(category);
  if (key != null) return l10n.translate('cat_$key');
  if (category.startsWith('ادخار - ')) {
    final name = category.substring('ادخار - '.length);
    return '${l10n.translate('cat_saving')} - $name';
  }
  return category;
}

String _recurringFreqKey(String frequency) {
  switch (frequency) {
    case 'daily':
      return 'frequencyDaily';
    case 'weekly':
      return 'frequencyWeekly';
    case 'yearly':
      return 'frequencyYearly';
    case 'monthly':
    default:
      return 'frequencyMonthly';
  }
}



class PersonalTransactionsPage extends ConsumerStatefulWidget {
  final int initialTab;
  const PersonalTransactionsPage({super.key, this.initialTab = 0});
  @override
  ConsumerState<PersonalTransactionsPage> createState() => _PersonalTransactionsPageState();
}

class _PersonalTransactionsPageState extends ConsumerState<PersonalTransactionsPage> with TickerProviderStateMixin {
  late TabController _tabCtrl;
  late TabController _recurringTabCtrl;
  final _searchCtrl = TextEditingController();
  String _filter = 'all';
  DateTime? _dateFrom;
  DateTime? _dateTo;

  static const _filters = ['all', 'income', 'expense'];

  String _filterLabel(String key, AppLocalizations l10n) {
    switch (key) {
      case 'income': return l10n.translate('income');
      case 'expense': return l10n.translate('expense');
      default: return l10n.translate('all');
    }
  }


  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 2, vsync: this, initialIndex: widget.initialTab);
    _recurringTabCtrl = TabController(length: 3, vsync: this);
    _tabCtrl.addListener(() {
      if (!_tabCtrl.indexIsChanging) {
        if (_tabCtrl.index == 1) {
          ref.read(recurringProvider.notifier).load();
        }
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(personalFinanceProvider.notifier).load();
      if (widget.initialTab == 1) {
        ref.read(recurringProvider.notifier).load();
      }
    });
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    _recurringTabCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  List<PersonalTransaction> _filtered(List<PersonalTransaction> all) {
    var list = all;
    if (_filter == 'income') list = list.where((t) => t.type == 'income').toList();
    if (_filter == 'expense') list = list.where((t) => t.type == 'expense').toList();
    if (_dateFrom != null) {
      list = list.where((t) => t.date != null && !t.date!.isBefore(_dateFrom!)).toList();
    }
    if (_dateTo != null) {
      final endOfDay = DateTime(_dateTo!.year, _dateTo!.month, _dateTo!.day, 23, 59, 59);
      list = list.where((t) => t.date != null && !t.date!.isAfter(endOfDay)).toList();
    }
    final q = _searchCtrl.text.trim().toLowerCase();
    if (q.isNotEmpty) {
      list = list.where((t) => (t.description ?? '').toLowerCase().contains(q) || t.category.toLowerCase().contains(q)).toList();
    }
    list.sort((a, b) {
      if (a.date == null && b.date == null) return 0;
      if (a.date == null) return 1;
      if (b.date == null) return -1;
      return b.date!.compareTo(a.date!);
    });
    return list;
  }

  Future<void> _showDatePicker() async {
    DateTime? tempFrom = _dateFrom;
    DateTime? tempTo = _dateTo;
    final now = DateTime.now();
    final l10n = AppLocalizations.of(context);

    final picked = await showModalBottomSheet<DateTimeRange>(
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
                Text(l10n.translate('txFilterByDate'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 16), fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
                const SizedBox(height: 16),
                Row(children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: () async {
                        final d = await showDatePicker(
                          context: ctx,
                          initialDate: tempFrom ?? now,
                          firstDate: DateTime(2020),
                          lastDate: now,
                          builder: (c, child) => Theme(data: Theme.of(c).copyWith(colorScheme: ColorScheme.light(primary: AppColors.primary)), child: child!),
                        );
                        if (d != null) setSheetState(() => tempFrom = d);
                      },
                      child: Container(
                        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                        decoration: BoxDecoration(
                          color: AppColors.surfaceVariant,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: tempFrom != null ? AppColors.primary : AppColors.border),
                        ),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(l10n.translate('fromLabel'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 10), color: AppColors.textSecondary)),
                          SizedBox(height: 4),
                          Text(
                            tempFrom != null ? DateFormat('yyyy/MM/dd').format(tempFrom!) : l10n.translate('selectDate'),
                            style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), fontWeight: FontWeight.w600, color: tempFrom != null ? AppColors.textPrimary : AppColors.textDisabled),
                          ),
                        ]),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: GestureDetector(
                      onTap: () async {
                        final d = await showDatePicker(
                          context: ctx,
                          initialDate: tempTo ?? tempFrom ?? now,
                          firstDate: DateTime(2020),
                          lastDate: now,
                          builder: (c, child) => Theme(data: Theme.of(c).copyWith(colorScheme: ColorScheme.light(primary: AppColors.primary)), child: child!),
                        );
                        if (d != null) setSheetState(() => tempTo = d);
                      },
                      child: Container(
                        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                        decoration: BoxDecoration(
                          color: AppColors.surfaceVariant,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: tempTo != null ? AppColors.primary : AppColors.border),
                        ),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(l10n.translate('toLabel'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 10), color: AppColors.textSecondary)),
                          SizedBox(height: 4),
                          Text(
                            tempTo != null ? DateFormat('yyyy/MM/dd').format(tempTo!) : l10n.translate('selectDate'),
                            style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), fontWeight: FontWeight.w600, color: tempTo != null ? AppColors.textPrimary : AppColors.textDisabled),
                          ),
                        ]),
                      ),
                    ),
                  ),
                ]),
                const SizedBox(height: 16),
                Row(children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      style: TextButton.styleFrom(
                        backgroundColor: AppColors.surfaceVariant,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        padding: EdgeInsets.symmetric(vertical: 12),
                      ),
                      child: Text(l10n.translate('cancel'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), color: AppColors.textSecondary)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: (tempFrom != null || tempTo != null)
                          ? () {
                              Navigator.pop(ctx, DateTimeRange(
                                start: tempFrom ?? DateTime(2020),
                                end: tempTo ?? now,
                              ));
                            }
                          : null,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        disabledBackgroundColor: AppColors.primary.withAlpha(80),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        padding: EdgeInsets.symmetric(vertical: 12),
                      ),
                      child: Text(l10n.translate('txApplyFilter'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), fontWeight: FontWeight.w700, color: Colors.white)),
                    ),
                  ),
                ]),
              ],
            ),
          ),
        ),
      ),
    );
    if (picked != null) {
      setState(() {
        _dateFrom = picked.start;
        _dateTo = picked.end;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final st = ref.watch(personalFinanceProvider);
    final recSt = ref.watch(recurringProvider);
    final filtered = _filtered(st.transactions);

    return Column(
      children: [
        Material(
          color: AppColors.surface,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: kToolbarHeight,
                child: Center(
                  child: Text(l10n.translate('personalRecentTransactions'), style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                ),
              ),
              TabBar(
                controller: _tabCtrl,
                indicatorColor: AppColors.primary,
                indicatorWeight: 3,
                indicatorSize: TabBarIndicatorSize.tab,
                labelColor: AppColors.primary,
                unselectedLabelColor: AppColors.textSecondary,
                labelStyle: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), fontWeight: FontWeight.w700),
                unselectedLabelStyle: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13)),
                tabs: [
                  Tab(text: l10n.translate('transactionsTab')),
                  Tab(text: l10n.translate('recurring')),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: _tabCtrl,
            children: [
              _buildTransactionsTab(st, filtered),
              _buildRecurringTab(recSt),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTransactionsTab(PersonalFinanceState st, List<PersonalTransaction> filtered) {
    final l10n = AppLocalizations.of(context);
    return Column(children: [
      // ── Search ──
      Container(
        padding: EdgeInsets.symmetric(horizontal: R.spacing(context, 12)).copyWith(top: R.spacing(context, 10)),
        color: AppColors.surface,
        child: FyonaTextField(
          controller: _searchCtrl,
          textAlign: TextAlign.right,
          decoration: InputDecoration(
            hintText: l10n.translate('searchTransaction'), hintStyle: TextStyle(fontFamily: 'Cairo', color: AppColors.textSecondary),
            prefixIcon: TwoToneIcon(data: TwoToneIcons.search, size: 20, outlineColor: AppColors.textSecondary),
            suffixIcon: _searchCtrl.text.isNotEmpty
                ? IconButton(icon: TwoToneIcon(data: TwoToneIcons.close, size: 18, outlineColor: AppColors.textSecondary), onPressed: () { _searchCtrl.clear(); setState(() {}); })
                : null,
            filled: true, fillColor: AppColors.surfaceVariant,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
            contentPadding: EdgeInsets.symmetric(vertical: 10, horizontal: 12),
          ),
          style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), color: AppColors.textPrimary),
          onChanged: (_) => setState(() {}),
        ),
      ),

      // ── Filter Chips ──
      Container(
        padding: EdgeInsets.symmetric(horizontal: R.spacing(context, 12), vertical: R.spacing(context, 8)),
        color: AppColors.surface,
        child: Row(children: [
          ..._filters.map((f) {
            final active = _filter == f;
            return Padding(
              padding: EdgeInsetsDirectional.only(end: R.spacing(context, 8)),
              child: GestureDetector(
                onTap: () => setState(() => _filter = f),
                child: Container(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  decoration: BoxDecoration(
                    color: active ? AppColors.primary : AppColors.surfaceVariant,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: active ? AppColors.primary : AppColors.divider.withOpacity(0.3)),
                  ),
                  child: Text(_filterLabel(f, l10n), style: TextStyle(
                    fontFamily: 'Cairo', fontSize: R.fontSize(context, 12),
                    fontWeight: active ? FontWeight.w600 : FontWeight.normal,
                    color: active ? Colors.white : AppColors.textSecondary,
                  )),
                ),
              ),
            );
          }),
          const Spacer(),
          GestureDetector(
            onTap: _showDatePicker,
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: (_dateFrom != null || _dateTo != null) ? AppColors.primary.withAlpha(20) : AppColors.surfaceVariant,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: (_dateFrom != null || _dateTo != null) ? AppColors.primary : AppColors.divider.withOpacity(0.3)),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.date_range, size: 14, color: (_dateFrom != null || _dateTo != null) ? AppColors.primary : AppColors.textSecondary),
                if (_dateFrom != null || _dateTo != null) ...[
                  SizedBox(width: 4),
                  GestureDetector(
                    onTap: () => setState(() { _dateFrom = null; _dateTo = null; }),
                    child: Icon(Icons.close, size: 12, color: AppColors.danger),
                  ),
                ],
              ]),
            ),
          ),
        ]),
      ),

       Divider(height: 1, color: AppColors.divider),

      // ── Loading ──
      if (st.isLoading)
        Expanded(child: Center(child: DotsLoader())),

      // ── List ──
      if (!st.isLoading)
        Expanded(
          child: filtered.isEmpty
              ? Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  TwoToneIcon(data: TwoToneIcons.receipt, size: 48, outlineColor: AppColors.textDisabled, detailColor: AppColors.textDisabled),
                  SizedBox(height: 12),
                  Text(l10n.translate('noTransactions'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 15), color: AppColors.textSecondary)),
                ]))
              : ListView.builder(
                  padding: EdgeInsets.all(R.spacing(context, 12)),
                  itemCount: filtered.length,
                  itemBuilder: (_, i) => _TransactionCard(t: filtered[i]),
                ),
        ),
    ]);
  }

  Widget _buildRecurringTab(RecurringState st) {
    final l10n = AppLocalizations.of(context);
    if (st.isLoading) {
      return Center(child: DotsLoader());
    }
    if (st.recurring.isEmpty) {
      return _buildRecurringEmpty();
    }
    return Column(
      children: [
        Container(
          margin: const EdgeInsets.all(16),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF212121), Color(0xFF424242)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              _RecurringSummaryItem(label: l10n.translate('recurringActive'), value: '${st.activeCount}', color: const Color(0xFF66BB6A)),
              Container(width: 1, height: 36, color: Colors.white24),
              _RecurringSummaryItem(label: l10n.translate('recurringPaused'), value: '${st.pausedCount}', color: const Color(0xFFFFA726)),
              Container(width: 1, height: 36, color: Colors.white24),
              _RecurringSummaryItem(label: l10n.translate('all'), value: '${st.totalCount}', color: Colors.white),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () async { await context.push(RouteNames.personalRecurringAdd); ref.read(recurringProvider.notifier).load(); },
              icon: const Icon(Icons.add_rounded, size: 20),
              label: Text(l10n.translate('recurringCreateNew'), style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold)),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFD32F2F),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: AppColors.surfaceVariant,
            borderRadius: BorderRadius.circular(10),
          ),
          child: TabBar(
            controller: _recurringTabCtrl,
            labelColor: const Color(0xFFD32F2F),
            unselectedLabelColor: AppColors.textSecondary,
            indicatorColor: const Color(0xFFD32F2F),
            indicatorSize: TabBarIndicatorSize.tab,
            labelStyle: const TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold, fontSize: 13),
            dividerHeight: 0,
            tabs: [
              Tab(text: l10n.translate('all')),
              Tab(text: l10n.translate('recurringActive')),
              Tab(text: l10n.translate('recurringPaused')),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: TabBarView(
            controller: _recurringTabCtrl,
            children: [
              _buildRecurringList(st.recurring),
              _buildRecurringList(st.activeTransactions),
              _buildRecurringList(st.pausedTransactions),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildRecurringEmpty() {
    final l10n = AppLocalizations.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 80, height: 80,
              decoration: BoxDecoration(
                color: const Color(0xFFD32F2F).withAlpha(15),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.replay_rounded, size: 40, color: Color(0xFFD32F2F)),
            ),
            const SizedBox(height: 20),
            Text(l10n.translate('personalRecurringTransactions'), style: TextStyle(fontFamily: 'Cairo', fontSize: 20, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
            const SizedBox(height: 8),
            Text(
              l10n.translate('recurringEmptyHint'),
              style: TextStyle(fontFamily: 'Cairo', fontSize: 14, color: AppColors.textSecondary),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () async { await context.push(RouteNames.personalRecurringAdd); ref.read(recurringProvider.notifier).load(); },
              icon: const Icon(Icons.add_rounded, size: 20),
              label: Text(l10n.translate('recurringFormTitle'), style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold)),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFD32F2F),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRecurringList(List<RecurringTransaction> items) {
    final l10n = AppLocalizations.of(context);
    if (items.isEmpty) {
      return Center(
        child: Text(AppLocalizations.of(context).translate('noTransactions'), style: TextStyle(fontFamily: 'Cairo', color: AppColors.textSecondary)),
      );
    }
    return RefreshIndicator(
      onRefresh: () => ref.read(recurringProvider.notifier).load(),
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 80),
        itemCount: items.length,
        itemBuilder: (ctx, i) {
          final rt = items[i];
          final isIncome = rt.type == 'income';
          final typeColor = isIncome ? const Color(0xFF66BB6A) : const Color(0xFFD32F2F);
          return GestureDetector(
            onTap: () => context.push(RouteNames.personalRecurringDetail, extra: rt),
            child: Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: rt.isActive ? AppColors.border : AppColors.border.withAlpha(100),
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 44, height: 44,
                    decoration: BoxDecoration(
                      color: typeColor.withAlpha(15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      isIncome ? Icons.arrow_downward_rounded : Icons.arrow_upward_rounded,
                      color: typeColor, size: 22,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                rt.name.isNotEmpty ? rt.name : rt.category,
                                style: TextStyle(
                                  fontFamily: 'Cairo', fontSize: 14, fontWeight: FontWeight.bold,
                                  color: rt.isActive ? AppColors.textPrimary : AppColors.textSecondary,
                                ),
                                maxLines: 1, overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (!rt.isActive)
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFFFA726).withAlpha(15),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(l10n.translate('recurringPausedOne'), style: TextStyle(fontFamily: 'Cairo', fontSize: 10, color: Color(0xFFFFA726))),
                              ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            _InfoChip(label: l10n.translate(_recurringFreqKey(rt.frequency))),
                            const SizedBox(width: 6),
                            _InfoChip(label: rt.category),
                            if (rt.executionType == 'reminder') ...[
                              const SizedBox(width: 6),
                              _InfoChip(label: l10n.translate('recurringReminder')),
                            ],
                          ],
                        ),
                        if (rt.nextDate != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            l10n.translate('recurringNextDate', params: {'date': DateFormat('dd/MM/yyyy').format(rt.nextDate!)}),
                            style: TextStyle(fontFamily: 'Cairo', fontSize: 11, color: AppColors.textSecondary),
                          ),
                        ],
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        '${isIncome ? '+' : '-'}${fmtNum(rt.amount)}',
                        style: TextStyle(
                          fontFamily: 'Cairo', fontSize: 15, fontWeight: FontWeight.bold,
                          color: typeColor,
                        ),
                      ),
                      Text(rt.currency, style:  TextStyle(fontFamily: 'Cairo', fontSize: 11, color: AppColors.textSecondary)),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _QuickBtn extends StatelessWidget {
  final String label;
  final TwoToneIconData icon;
  final Color color;
  final VoidCallback onTap;
  const _QuickBtn({required this.label, required this.icon, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () { HapticFeedback.lightImpact(); onTap(); },
      child: Container(
        padding: EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(color: color.withAlpha(20), border: Border.all(color: color.withAlpha(60)), borderRadius: BorderRadius.circular(12)),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          TwoToneIcon(data: icon, size: 20, outlineColor: color, detailColor: color),
          SizedBox(width: 8),
          Text(label, style: TextStyle(fontFamily: 'Cairo', fontSize: 13, fontWeight: FontWeight.w700, color: color)),
        ]),
      ),
    );
  }
}

class _TransactionCard extends ConsumerWidget {
  final PersonalTransaction t;
  const _TransactionCard({required this.t});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isIncome = t.type == 'income';
    final color = isIncome ? AppColors.success : AppColors.danger;
    // Quiet under the Information Clicker: long-press belongs to the native
    // receipt/delete sheet, tap to the receipt — never a help card.
    return ClickerQuiet(
      child: GestureDetector(
      onLongPress: () => _showOptions(context, ref, t),
      onTap: () => _showReceipt(context, ref, t),
      child: Container(
      margin: EdgeInsets.only(bottom: 8),
      padding: EdgeInsets.all(R.spacing(context, 12)),
      decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(14),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 8, offset: Offset(0, 2))],
      ),
      child: Row(children: [
        Container(padding: EdgeInsets.all(10),
          decoration: BoxDecoration(color: color.withAlpha(15), borderRadius: BorderRadius.circular(12)),
          child: TwoToneIcon(data: isIncome ? TwoToneIcons.income : TwoToneIcons.expense, size: 20, outlineColor: color, detailColor: color),
        ),
        SizedBox(width: R.spacing(context, 12)),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t.description ?? _catLabel(t.category, AppLocalizations.of(context)), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
          SizedBox(height: 2),
          Row(children: [
            Flexible(child: Text(_catLabel(t.category, AppLocalizations.of(context)), overflow: TextOverflow.ellipsis, maxLines: 1, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 10), color: AppColors.textSecondary))),
            SizedBox(width: 8),
            if (t.date != null) Text(DateFormat('yyyy/MM/dd').format(t.date!), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 10), color: AppColors.textDisabled)),
          ]),
        ])),
        Flexible(child: FittedBox(fit: BoxFit.scaleDown, alignment: AlignmentDirectional.centerEnd, child: Text.rich(TextSpan(text: '${isIncome ? '+' : '-'}${fmtNum(t.amount)}', children: [if (currencySymbol(t.currency).isNotEmpty) TextSpan(text: '  ${currencySymbol(t.currency)}', style: TextStyle(fontSize: R.fontSize(context, 9), fontWeight: FontWeight.w600, color: AppColors.textSecondary))]), maxLines: 1, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 14), fontWeight: FontWeight.w700, color: color)))),
      ]),
    ),
      ),
    );
  }

  static void _showOptions(BuildContext context, WidgetRef ref, PersonalTransaction t) {
    final l10n = AppLocalizations.of(context);
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Icons.receipt_long, color: AppColors.primary),
              title: Text(l10n.translate('txViewReceipt'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(ctx, 14), fontWeight: FontWeight.w600)),
              onTap: () { Navigator.pop(ctx); _showReceipt(context, ref, t); },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: AppColors.danger),
              title: Text(l10n.translate('delete'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(ctx, 14), fontWeight: FontWeight.w600, color: AppColors.danger)),
              onTap: () async {
                Navigator.pop(ctx);
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (dCtx) => AlertDialog(
                    backgroundColor: AppColors.surface,
                    title: Text(l10n.translate('txConfirmDeleteTitle'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 16), fontWeight: FontWeight.bold)),
                    content: Text(l10n.translate('txConfirmDeleteTx'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13))),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(dCtx, false), child: Text(l10n.translate('cancel'), style: TextStyle(fontFamily: 'Cairo'))),
                      TextButton(onPressed: () => Navigator.pop(dCtx, true), child: Text(l10n.translate('delete'), style: TextStyle(fontFamily: 'Cairo', color: AppColors.danger))),
                    ],
                  ),
                );
                if (confirmed == true) {
                  final ok = await ref.read(personalFinanceProvider.notifier).deleteTransaction(t.id);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text(
                        ok ? l10n.translate('txDeleted') : l10n.translate('personalErrDeleteTx'),
                        style: TextStyle(fontFamily: 'Cairo'),
                      ),
                      backgroundColor: ok ? AppColors.success : AppColors.danger,
                    ));
                  }
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  static void _showReceipt(
      BuildContext context, WidgetRef ref, PersonalTransaction t) {
    final isIncome = t.type == 'income';
    final l10n = AppLocalizations.of(context);
    final preset = ref
        .read(personalReceiptDesignProvider.notifier)
        .getPreset(receiptSectionForTransaction(
          debtId: t.debtId,
          goalId: t.goalId,
          budgetId: t.budgetId,
          txType: t.type,
          category: t.category,
        ));
    ReceiptModal.show(
      context,
      ReceiptData(
        title: isIncome ? l10n.translate('deposit') : l10n.translate('withdrawal'),
        amount: t.amount,
        currencySymbol: currencySymbol(t.currency),
        dateTime: t.date != null ? DateFormat('yyyy/MM/dd HH:mm').format(t.date!) : '-',
        referenceNumber: '#TX-${t.id}',
        senderName: isIncome ? (t.description ?? '-') : null,
        receiverName: !isIncome ? (t.description ?? '-') : null,
        details: [
          ReceiptDetail(label: l10n.translate('txDetailCategory'), value: _catLabel(t.category, AppLocalizations.of(context))),
          ReceiptDetail(label: l10n.translate('txDetailType'), value: isIncome ? l10n.translate('deposit') : l10n.translate('withdrawal')),
          if (t.description != null && t.description!.isNotEmpty)
            ReceiptDetail(label: l10n.translate('description'), value: t.description!),
        ],
      ),
      preset: preset,
    );
  }
}

class _RecurringSummaryItem extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _RecurringSummaryItem({required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: const TextStyle(fontFamily: 'Cairo', fontSize: 12, color: Colors.white70)),
          const SizedBox(height: 4),
          Text(value, style: TextStyle(fontFamily: 'Cairo', fontSize: 20, fontWeight: FontWeight.bold, color: color)),
        ],
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  final String label;
  const _InfoChip({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(label, style: TextStyle(fontFamily: 'Cairo', fontSize: 10, color: AppColors.textSecondary)),
    );
  }
}