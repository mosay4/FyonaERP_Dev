import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_radius.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../shared/widgets/confirm_dialog.dart';
import '../../presentation/providers/ai_providers.dart';
import '../../../../shared/widgets/two_tone_icon.dart';
import '../../../../shared/widgets/two_tone_icons.dart';

const _typeKeys = ['low_stock', 'reorder', 'top_product', 'debt_alert', 'sales_trend'];

String _typeLabel(BuildContext context, String type) {
  final l10n = AppLocalizations.of(context);
  switch (type) {
    case 'low_stock':
      return l10n.translate('aiTypeLowStock');
    case 'reorder':
      return l10n.translate('aiTypeReorder');
    case 'top_product':
      return l10n.translate('aiTypeTopProduct');
    case 'debt_alert':
      return l10n.translate('aiTypeDebt');
    case 'sales_trend':
      return l10n.translate('aiTypeSales');
    default:
      return type;
  }
}

const Map<String, IconData> _typeIcons = {
  'low_stock': Icons.inventory_2,
  'reorder': Icons.shopping_cart,
  'top_product': Icons.star,
  'debt_alert': Icons.error_outline,
  'sales_trend': Icons.trending_up,
};

const Map<String, Color> _typeColors = {
  'low_stock': AppColors.warning,
  'reorder': AppColors.primary,
  'top_product': AppColors.success,
  'debt_alert': AppColors.danger,
  'sales_trend': AppColors.info,
};

class AiSuggestionsPage extends ConsumerStatefulWidget {
  const AiSuggestionsPage({super.key});

  @override
  ConsumerState<AiSuggestionsPage> createState() => _AiSuggestionsPageState();
}

class _AiSuggestionsPageState extends ConsumerState<AiSuggestionsPage> {
  String? _filterType;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) { ref.read(aiSuggestionsProvider.notifier).load(); });
  }

  void _setFilter(String? type) {
    setState(() => _filterType = type);
  }

  void _generateSuggestions() {
    ref.read(aiSuggestionsProvider.notifier).generate();
    showSnackbar(context, message: AppLocalizations.of(context).translate('aiGeneratedOk'));
  }

  void _markRead(int id) {
    ref.read(aiSuggestionsProvider.notifier).markRead(id);
  }

  void _deleteOne(int id) {
    final l10n = AppLocalizations.of(context);
    showConfirmDialog(
      context,
      title: l10n.translate('aiDeleteTitle'),
      message: l10n.translate('aiDeleteConfirm'),
      danger: true,
    ).then((confirmed) {
      if (!mounted) return;
      if (confirmed == true) {
        ref.read(aiSuggestionsProvider.notifier).deleteOne(id);
        showSnackbar(context, message: AppLocalizations.of(context).translate('aiDeletedOk'));
      }
    });
  }

  void _markAllRead() {
    final l10n = AppLocalizations.of(context);
    showConfirmDialog(
      context,
      title: l10n.translate('aiMarkAllTitle'),
      message: l10n.translate('aiMarkAllConfirm'),
      danger: false,
    ).then((confirmed) {
      if (!mounted) return;
      if (confirmed == true) {
        ref.read(aiSuggestionsProvider.notifier).markAllRead();
        showSnackbar(context, message: AppLocalizations.of(context).translate('aiMarkedAllOk'));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(aiSuggestionsProvider);
    final suggestions = state.suggestions;
    final filtered = suggestions
        .where((s) => _filterType == null || s.type == _filterType)
        .toList();

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          title: Text(AppLocalizations.of(context).translate('aiSuggestionsTitle')),
          backgroundColor: AppColors.background,
          actions: [
            IconButton(
              icon: const Icon(Icons.star, color: AppColors.primary),
              tooltip: AppLocalizations.of(context).translate('aiGenerateTooltip'),
              onPressed: _generateSuggestions,
            ),
            IconButton(
              icon: const Icon(Icons.check_circle, color: AppColors.success),
              tooltip: AppLocalizations.of(context).translate('aiMarkAllTitle'),
              onPressed: _markAllRead,
            ),
          ],
        ),
        body: Padding(
          padding: EdgeInsets.symmetric(horizontal: R.spacing(context, 16)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(height: R.spacing(context, AppSpacing.xs)),
              // Summary row
              SizedBox(
                height: 36,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    _buildSummaryChip(AppLocalizations.of(context).translate('debtAllFilter'), AppColors.primary, null),
                    for (final type in _typeKeys)
                      _buildSummaryChip(
                        AppLocalizations.of(context).translate('aiSummaryCount', params: {'label': _typeLabel(context, type), 'count': suggestions.where((s) => s.type == type).length}),
                        _typeColors[type] ?? AppColors.textSecondary,
                        type,
                      ),
                  ],
                ),
              ),
              SizedBox(height: R.spacing(context, AppSpacing.xs)),
              // Filter row
              SizedBox(
                height: 32,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    _buildFilterChip(AppLocalizations.of(context).translate('debtAllFilter'), null),
                    for (final type in _typeKeys)
                      _buildFilterChip(_typeLabel(context, type), type),
                  ],
                ),
              ),
               Divider(height: 1, color: AppColors.border),
              SizedBox(height: R.spacing(context, AppSpacing.sm)),
              // List
              Expanded(
                child: filtered.isEmpty
                    ? Center(
                        child: Text(
                          suggestions.isEmpty
                              ? AppLocalizations.of(context).translate('aiEmptyAll')
                              : AppLocalizations.of(context).translate('aiEmptyFilter'),
                          style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: R.fontSize(context, 13),
                            color: AppColors.textDisabled,
                          ),
                        ),
                      )
                    : ListView.separated(
                        itemCount: filtered.length,
                        separatorBuilder: (_, _) => SizedBox(height: R.spacing(context, AppSpacing.xs)),
                        itemBuilder: (context, index) {
                          final s = filtered[index];
                          final icon = _typeIcons[s.type] ?? Icons.star;
                          final iconColor = _typeColors[s.type] ?? AppColors.primary;
                          final color = s.isRead ? AppColors.textSecondary : iconColor;

                          return Container(
                            padding: EdgeInsets.all(R.spacing(context, AppSpacing.md)),
                            decoration: BoxDecoration(
                              color: AppColors.surface,
                              border: Border.all(color: AppColors.border),
                              borderRadius: BorderRadius.circular(R.spacing(context, AppRadius.cardRadius)),
                            ),
                            child: Opacity(
                              opacity: s.isRead ? 0.7 : 1.0,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Icon(icon, size: 20, color: color),
                                       SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          s.title,
                                          style: TextStyle(
                                            fontFamily: 'Cairo',
                                            fontSize: R.fontSize(context, 13),
                                            fontWeight: FontWeight.bold,
                                            color: AppColors.textPrimary,
                                          ),
                                        ),
                                      ),
                                      IconButton(
                                        icon: Icon(
                                          s.isRead ? Icons.check_circle : Icons.check_circle,
                                          size: 18,
                                          color: s.isRead ? AppColors.textDisabled : AppColors.success,
                                        ),
                                        onPressed: () => _markRead(s.id),
                                        visualDensity: VisualDensity.compact,
                                      ),
                                      IconButton(
                                        icon: TwoToneIcon(data: TwoToneIcons.delete, size: 18, outlineColor: AppColors.textDisabled),
                                        onPressed: () => _deleteOne(s.id),
                                        visualDensity: VisualDensity.compact,
                                      ),
                                    ],
                                  ),
                                  SizedBox(height: R.spacing(context, AppSpacing.xs)),
                                  Text(
                                    s.description,
                                    style: TextStyle(
                                      fontFamily: 'Cairo',
                                      fontSize: R.fontSize(context, 11),
                                      color: AppColors.textSecondary,
                                    ),
                                  ),
                                  SizedBox(height: R.spacing(context, AppSpacing.xs)),
                                  Row(
                                    children: [
                                      Text(
                                        _typeLabel(context, s.type),
                                        style: TextStyle(
                                          fontFamily: 'Cairo',
                                          fontSize: R.fontSize(context, 10),
                                          color: AppColors.info,
                                        ),
                                      ),
                                       SizedBox(width: 12),
                                      Text(
                                        s.createdAt,
                                        style: TextStyle(
                                          fontFamily: 'Cairo',
                                          fontSize: R.fontSize(context, 10),
                                          color: AppColors.textDisabled,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSummaryChip(String label, Color color, String? type) {
    return Padding(
      padding: EdgeInsets.only(left: R.spacing(context, AppSpacing.xs)),
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: R.spacing(context, AppSpacing.sm),
          vertical: R.spacing(context, AppSpacing.xs),
        ),
        decoration: BoxDecoration(
          color: type == null ? AppColors.primary.withAlpha(30) : AppColors.surface,
          borderRadius: BorderRadius.circular(R.spacing(context, 12)),
        ),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: R.fontSize(context, 12),
              fontWeight: FontWeight.w500,
              color: color,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFilterChip(String label, String? type) {
    final isActive = type == _filterType;
    return Padding(
      padding: EdgeInsets.only(left: R.spacing(context, AppSpacing.xs)),
      child: GestureDetector(
        onTap: () => _setFilter(type),
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: R.spacing(context, 10),
            vertical: R.spacing(context, AppSpacing.xs),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: R.fontSize(context, 11),
              fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
              color: isActive ? AppColors.primary : AppColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

