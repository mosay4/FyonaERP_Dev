import 'package:flutter/material.dart';
import '../../../employees/presentation/providers/employee_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../branches/data/branch_scope.dart';
import '../../../../shared/widgets/styled_snack.dart';
import '../../../core_business/data/local_commerce/local_commerce_api.dart';
import '../../../core_business/presentation/providers/local_commerce_navigation.dart';
import '../../../core_business/presentation/widgets/business_operation_error.dart';
import '../../data/inventory_api.dart';
import '../providers/inventory_providers.dart';
import '../widgets/business_product_image.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';

/// Simple category management (create / rename / delete). Only shown when the
/// «التصنيفات» warehouse setting is ON.
class CategoriesPage extends ConsumerStatefulWidget {
  const CategoriesPage({super.key});
  @override
  ConsumerState<CategoriesPage> createState() => _CategoriesPageState();
}

class _CategoriesPageState extends ConsumerState<CategoriesPage> {
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;
  bool _adding = false;
  Object? _error;
  late final InventoryApi _source;

  bool get _active =>
      mounted &&
      identical(_source, ref.read(inventoryApiProvider)) &&
      ref.read(employeeCanProvider('inventory'));

  @override
  void initState() {
    super.initState();
    _source = ref.read(inventoryApiProvider);
    _load();
  }

  Future<void> _load() async {
    if (!_active) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final raw = await _source.categories();
      if (_active) setState(() => _items = raw);
    } catch (e) {
      if (_active) setState(() => _error = e);
    }
    if (_active) setState(() => _loading = false);
  }

  Future<void> _add() async {
    if (!_active || _adding) return;
    final l10n = AppLocalizations.of(context);
    _adding = true;
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          l10n.translate('invCategories'),
          style: const TextStyle(fontFamily: 'Cairo'),
        ),
        content: FyonaTextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(
            labelText: l10n.translate('invCategoryName'),
          ),
          style: const TextStyle(fontFamily: 'Cairo'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              l10n.translate('cancel'),
              style: const TextStyle(fontFamily: 'Cairo'),
            ),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              l10n.translate('save'),
              style: const TextStyle(fontFamily: 'Cairo'),
            ),
          ),
        ],
      ),
    );
    final name = ctrl.text.trim();
    ctrl.dispose();
    if (_active && ok == true && name.isNotEmpty) {
      try {
        await _source.createCategory(name);
        if (_active) {
          ref.invalidate(inventoryCategoriesProvider);
          await _load();
        }
      } catch (e) {
        if (_active)
          showFyonaSnack(
            context,
            businessOperationError(l10n, e, fallback: 'invActionFailed'),
            success: false,
          );
      }
    }
    _adding = false;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final source = ref.watch(inventoryApiProvider);
    final allowed =
        identical(source, _source) &&
        ref.watch(employeeCanProvider('inventory'));
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        surfaceTintColor: Colors.transparent,
        centerTitle: true,
        title: Text(
          l10n.translate('invCategories'),
          style: const TextStyle(
            fontFamily: 'Cairo',
            fontWeight: FontWeight.w700,
          ),
        ),
        actions: [
          if (!BranchScope.readOnly &&
              ref.watch(employeeCanProvider('inventory.add')))
            IconButton(onPressed: _add, icon: const Icon(Icons.add)),
        ],
      ),
      body: !allowed
          ? Center(child: Text(l10n.translate('unauthorized')))
          : _loading
          ? source is LocalInventoryApi
                ? const SizedBox.shrink()
                : const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Text(
                businessOperationError(l10n, _error!, fallback: 'invLoadError'),
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                for (final c in _items)
                  Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      border: Border.all(color: AppColors.border),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Material(
                      color: Colors.transparent,
                      child: ListTile(
                        leading: _CatThumb(
                          url: (c['image'] ?? '').toString().isEmpty
                              ? null
                              : (c['image'] ?? '').toString(),
                        ),
                        title: Text(
                          (c['name'] ?? '').toString(),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: 'Cairo',
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        trailing: Icon(
                          Icons.chevron_left,
                          color: AppColors.textSecondary,
                        ),
                        onTap: () async {
                          if (!_active) return;
                          await openCommerceRecord(
                            context,
                            RouteNames.inventoryCategoryDetail,
                            '${c['id']}',
                          );
                          if (_active) await _load();
                        },
                      ),
                    ),
                  ),
                if (_items.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 72),
                    child: Column(
                      children: [
                        Icon(
                          Icons.category_outlined,
                          size: 56,
                          color: AppColors.textSecondary,
                        ),
                        const SizedBox(height: 10),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 32),
                          child: Text(
                            l10n.translate(
                              'invNoCategoriesHint',
                            ),
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        if (!BranchScope.readOnly &&
                            ref.watch(employeeCanProvider('inventory.add')))
                          OutlinedButton.icon(
                            onPressed: _add,
                            icon: const Icon(Icons.add, size: 18),
                            label: Text(
                              l10n.translate('invAddCategory'),
                              style: const TextStyle(
                                fontFamily: 'Cairo',
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: AppColors.danger,
                              side: const BorderSide(
                                color: AppColors.danger,
                                width: 1.5,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 24,
                                vertical: 12,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}

class _CatThumb extends StatelessWidget {
  final String? url;
  const _CatThumb({this.url});
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 44,
      height: 44,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: AppColors.surfaceVariant.withAlpha(90),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border),
      ),
      child: (url != null && url!.isNotEmpty)
          ? BusinessProductImage(
              url: url,
              width: 44,
              height: 44,
              fit: BoxFit.cover,
            )
          : Icon(
              Icons.category_outlined,
              size: 22,
              color: AppColors.textSecondary,
            ),
    );
  }
}
