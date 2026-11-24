import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../shared/widgets/two_tone_icon.dart';
import '../../../../shared/widgets/two_tone_icons.dart';
import '../../../../shared/widgets/dots_loader.dart';
import '../../data/models/personal_models.dart';
import '../providers/personal_providers.dart';
import 'package:fyona_flutter/shared/widgets/fyona_refresh.dart';

class PersonalCategoriesPage extends ConsumerStatefulWidget {
  const PersonalCategoriesPage({super.key});
  @override
  ConsumerState<PersonalCategoriesPage> createState() => _PersonalCategoriesPageState();
}

class _PersonalCategoriesPageState extends ConsumerState<PersonalCategoriesPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => ref.read(categoryProvider.notifier).load());
  }

  void _confirmDelete(SpendingCategory c) {
    final l10n = AppLocalizations.of(context);
    HapticFeedback.lightImpact();
    showDialog(context: context, builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text(l10n.translate('deleteCategory'), style: TextStyle(fontFamily: 'Cairo', color: AppColors.textPrimary, fontWeight: FontWeight.w700)),
      content: Text(l10n.translate('confirmDeleteCategory', params: {'name': c.nameAr}), style: TextStyle(fontFamily: 'Cairo', color: AppColors.textSecondary)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l10n.translate('cancel'), style: TextStyle(fontFamily: 'Cairo', color: AppColors.textSecondary))),
        TextButton(onPressed: () { Navigator.pop(ctx); ref.read(categoryProvider.notifier).delete(c.id); }, child: Text(l10n.translate('delete'), style: TextStyle(fontFamily: 'Cairo', color: AppColors.danger, fontWeight: FontWeight.w700))),
      ],
    ));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final st = ref.watch(categoryProvider);
    return FyonaRefresh(
      onRefresh: () => ref.read(categoryProvider.notifier).load(),
      child: CustomScrollView(
        slivers: [
          if (st.isLoading)
            SliverFillRemaining(child: Center(child: DotsLoader())),

          if (!st.isLoading && st.categories.isEmpty)
            SliverFillRemaining(
              child: Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                TwoToneIcon(data: TwoToneIcons.tag, size: 64, outlineColor: AppColors.textSecondary.withOpacity(0.3), detailColor: AppColors.textSecondary.withOpacity(0.3)),
                SizedBox(height: R.spacing(context, 12)),
                Text(l10n.translate('noCategories'), style: TextStyle(fontFamily: 'Cairo', color: AppColors.textSecondary, fontSize: R.fontSize(context, 15))),
                SizedBox(height: R.spacing(context, 8)),
                TextButton.icon(
                  onPressed: () async { await context.push(RouteNames.personalCategoryAdd); ref.read(categoryProvider.notifier).load(); },
                  icon: TwoToneIcon(data: TwoToneIcons.plus, size: 18, outlineColor: AppColors.primary, detailColor: AppColors.primary),
                  label: Text(l10n.translate('addCategory'), style: TextStyle(fontFamily: 'Cairo', color: AppColors.primary)),
                ),
              ])),
            ),

          if (!st.isLoading)
            SliverPadding(
              padding: EdgeInsets.all(R.spacing(context, 12)),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate((context, index) {
                  final c = st.categories[index];
                  return Container(
                    margin: EdgeInsets.only(bottom: R.spacing(context, 10)),
                    padding: EdgeInsets.all(R.spacing(context, 12)),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(14),
                      boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 8, offset: Offset(0, 2))],
                    ),
                    child: Row(children: [
                      Container(
                        padding: EdgeInsets.all(R.spacing(context, 10)),
                        decoration: BoxDecoration(color: AppColors.primary.withOpacity(0.1), borderRadius: BorderRadius.circular(12)),
                        child: TwoToneIcon(data: TwoToneIcons.tag, size: 20, outlineColor: AppColors.primary, detailColor: AppColors.primary),
                      ),
                      SizedBox(width: R.spacing(context, 12)),
                      Expanded(child: Text(c.nameAr, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 14), fontWeight: FontWeight.w700, color: AppColors.textPrimary))),
                      PopupMenuButton<String>(
                        color: AppColors.surface,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        onSelected: (v) {
                          if (v == 'edit') context.push(RouteNames.personalCategoryEdit, extra: {'category': c});
                          if (v == 'delete') _confirmDelete(c);
                        },
                        itemBuilder: (_) => [
                          PopupMenuItem(value: 'edit', child: Row(children: [TwoToneIcon(data: TwoToneIcons.edit, size: 18, outlineColor: AppColors.textSecondary, detailColor: AppColors.textSecondary), SizedBox(width: 8), Text(l10n.translate('editLabel'), style: TextStyle(fontFamily: 'Cairo'))])),
                          PopupMenuItem(value: 'delete', child: Row(children: [TwoToneIcon(data: TwoToneIcons.delete, size: 18, outlineColor: AppColors.danger, detailColor: AppColors.danger), SizedBox(width: 8), Text(l10n.translate('delete'), style: TextStyle(fontFamily: 'Cairo', color: AppColors.danger))])),
                        ],
                      ),
                    ]),
                  );
                }, childCount: st.categories.length),
              ),
            ),
        ],
      ),
    );
  }
}