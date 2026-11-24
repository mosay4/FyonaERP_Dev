import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../shared/services/scan_sfx.dart';
import '../../../inventory/presentation/widgets/business_product_image.dart';
import '../../../../shared/widgets/styled_snack.dart';
import '../../../core_business/data/local_directory/directory_scope.dart';
import '../../../core_business/data/local_commerce/local_commerce_api.dart';
import '../../../employees/presentation/providers/employee_providers.dart';
import '../../../inventory/data/inventory_api.dart';
import '../../../inventory/presentation/providers/inventory_providers.dart';
import '../../../purchases/presentation/pages/barcode_scan_page.dart';
import '../../data/reconciliation_api.dart';
import '../widgets/recon_widgets.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';

/// Inventory picker:
///  product  → all products with name/barcode search; tap = start counting it
///  category → squares of categories (image + name); tap = count its products
///  full     → starts immediately (all products)
class ReconInventoryPickPage extends ConsumerStatefulWidget {
  final String scope;
  const ReconInventoryPickPage({super.key, required this.scope});

  @override
  ConsumerState<ReconInventoryPickPage> createState() =>
      _ReconInventoryPickPageState();
}

class _ReconInventoryPickPageState
    extends ConsumerState<ReconInventoryPickPage> {
  final _searchCtrl = TextEditingController();
  List<Map<String, dynamic>> _products = [];
  List<Map<String, dynamic>> _categories = [];
  bool _loading = true;
  bool _busy = false;
  Object? _error;
  late final ReconciliationApi _source;
  late final InventoryApi _inventory;
  (String, String?, String?, String)? _pendingStart;
  int _searchRequest = 0;

  bool _mayRead(ReconciliationApi current) =>
      identical(_source, current) &&
      (!current.isDeviceLedger || current.canReadDeviceInventory);

  bool get _active => mounted && _mayRead(ref.read(reconciliationApiProvider)) &&
      _mayPick(ref.read(inventoryApiProvider));

  bool _mayPick(InventoryApi current) => widget.scope == 'full' ||
      (identical(_inventory, current) && _source.isDeviceLedger == (current is LocalInventoryApi) &&
          ref.read(employeeCanProvider('inventory')));

  @override
  void initState() {
    super.initState();
    _source = ref.read(reconciliationApiProvider);
    _inventory = ref.read(inventoryApiProvider);
    // NEVER push/await during initState (it throws and the next page opens
    // empty). Everything starts after the first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.scope == 'full') {
        _start(scope: 'full');
      } else if (widget.scope == 'category') {
        _loadCategories();
      } else {
        _search('');
      }
    });
  }

  Future<void> _loadCategories() async {
    if (!_active) return;
    try {
      final cats = await _inventory.categories();
      if (_active) {
        setState(() {
          _categories = [
            for (final c in cats.whereType<Map>())
              Map<String, dynamic>.from(c)
          ];
          _loading = false;
        });
      }
    } catch (e) {
      if (_active) setState(() {
        _loading = false;
        _error = e;
      });
    }
  }

  Future<void> _search(String q) async {
    if (!_active) return;
    final ticket = ++_searchRequest;
    setState(() => _loading = true);
    try {
      final raw = await _inventory.listProducts(search: q, perPage: 50);
      if (_active && ticket == _searchRequest) {
        setState(() {
          _products = [
            for (final p in raw.whereType<Map>())
              if (p['is_service'] != true) Map<String, dynamic>.from(p)
          ];
          _loading = false;
        });
      }
    } catch (_) {
      if (_active && ticket == _searchRequest) setState(() => _loading = false);
    }
  }

  Future<void> _scanBarcode() async {
    final code = await Navigator.of(context).push<String>(MaterialPageRoute(
      builder: (_) => const BarcodeScanPage(),
    ));
    if (code == null || code.isEmpty || !_active) return;
    try {
      final res = await _inventory.resolveBarcode(code);
      if (!_active) return;
      final product = res['product'] as Map?;
      if (product == null) {
        unawaited(ScanSfx.error());
        showFyonaSnack(context,
            AppLocalizations.of(context).translate('invBarcodeUnknown'),
            success: false);
        return;
      }
      unawaited(ScanSfx.success());
      await _start(scope: 'product', productId: '${product['id']}');
    } catch (_) {
      if (!_active) return;
      unawaited(ScanSfx.error());
      showFyonaSnack(context,
          AppLocalizations.of(context).translate('invBarcodeUnknown'),
          success: false);
    }
  }

  Future<void> _start({
    required String scope,
    String? productId,
    String? categoryId,
  }) async {
    if (_busy || !_active) return;
    final api = _source;
    if (_pendingStart case (final s, final p, final c, _) when
        s != scope || p != productId || c != categoryId) {
      _pendingStart = null;
    }
    final (_, _, _, command) = _pendingStart ??= (
      scope, productId, categoryId, ReconciliationApi.newOperationId(),
    );
    setState(() => _busy = true);
    try {
      final rec = await api.inventoryStart(
            scope: scope,
            productId: productId,
            categoryId: categoryId,
            idempotencyKey: command,
          );
      if (!mounted) return;
      setState(() => _busy = false);
      if (!_active) return;
      _pendingStart = null;
      unawaited(ScanSfx.success());
      context.push('/reconciliation/inventory/count',
        extra: api.isDeviceLedger
          ? {'record': rec, 'local': LocalReconciliationLink(
              api, '${rec['id']}', rtype: 'inventory',
            )}
          : rec,
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _loading = false;
          if (_source.isDeviceLedger && scope == 'full') _error = e;
        });
        if (_active) showReconError(context, e);
      }
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isProduct = widget.scope == 'product';
    final isCategory = widget.scope == 'category';
    final current = ref.watch(reconciliationApiProvider);
    final inventory = ref.watch(inventoryApiProvider);
    final local = current.isDeviceLedger;
    final allowed = (!local || ref.watch(localInventoryReconciliationAllowedProvider)) &&
        _mayRead(current) && (!(isProduct || isCategory) ||
          (ref.watch(employeeCanProvider('inventory')) && _mayPick(inventory)));
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, size: 20),
          color: AppColors.textPrimary,
          onPressed: () => reconBack(context),
        ),
        title: Text(
            l10n.translate(isCategory
                ? 'reconInvCategory'
                : isProduct
                    ? 'reconPickProductTitle'
                    : 'reconInvFull'),
            style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 15),
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary)),
      ),
      body: SafeArea(
        child: !allowed
            ? Center(child: Text(reconErrorMessage(l10n, const DirectoryAccessDenied())))
            : _error != null
            ? Center(child: Text(reconErrorMessage(l10n, _error!)))
            : Stack(children: [
          if (isProduct)
            Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
                child: Row(children: [
                  Expanded(
                    child: FyonaTextField(
                      controller: _searchCtrl,
                      onChanged: (v) => _search(v.trim()),
                      style: const TextStyle(fontFamily: 'Cairo'),
                      decoration: InputDecoration(
                        hintText: l10n.translate('reconSearchBarcodeHint'),
                        prefixIcon: const Icon(Icons.search, size: 20),
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  InkWell(
                    onTap: _scanBarcode,
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.primary.withAlpha(18),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                            color: AppColors.primary.withAlpha(90)),
                      ),
                      child: const Icon(Icons.qr_code_scanner_rounded,
                          color: AppColors.primary),
                    ),
                  ),
                ]),
              ),
              Expanded(child: _productsList(l10n, tapToCount: true)),
            ])
          else if (isCategory)
             _loading && !local
                ? const Center(
                    child: CircularProgressIndicator(color: AppColors.primary))
                 : _loading ? const SizedBox.shrink() : _categoryGrid(l10n)
          else
             _loading && !local
                ? const Center(
                    child: CircularProgressIndicator(color: AppColors.primary))
                : const SizedBox.shrink(),
           if (_busy && !local)
            Container(
              color: Colors.black26,
              child: const Center(
                  child: CircularProgressIndicator(color: AppColors.primary)),
            ),
        ]),
      ),
    );
  }

  Widget _productsList(AppLocalizations l10n, {bool tapToCount = false}) {
    if (_loading && !_source.isDeviceLedger) {
      return const Center(
          child: CircularProgressIndicator(color: AppColors.primary));
    }
    if (_products.isEmpty) {
      return Center(
        child: Text(l10n.translate('invNoProducts'),
            style: const TextStyle(fontFamily: 'Cairo')),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      itemCount: _products.length,
      itemBuilder: (_, i) {
        final p = _products[i];
        return Container(
          margin: const EdgeInsets.only(bottom: 10),
          // Material ancestor → the tap ripple paints INSIDE this card only
          // (without it the splash covers the whole page).
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(14),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: tapToCount
                  ? () => _start(scope: 'product', productId: '${p['id']}')
                  : null,
              child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppColors.border),
              ),
              child: Row(children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: SizedBox(
                    width: 46,
                    height: 46,
                    child: (p['image']?.toString().isNotEmpty ?? false)
                         ? BusinessProductImage(url: '${p['image']}',
                            fit: BoxFit.cover)
                        : Container(
                            color: AppColors.surfaceVariant.withAlpha(80),
                            child: Icon(Icons.inventory_2_outlined,
                                size: 20,
                                color: AppColors.textSecondary)),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text('${p['name'] ?? ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: R.fontSize(context, 13),
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary)),
                ),
                const Icon(Icons.chevron_right_rounded,
                    color: AppColors.primary),
              ]),
            ),
            ),
          ),
        );
      },
    );
  }

  Widget _categoryGrid(AppLocalizations l10n) {
    // (name shown in the squares below)
    if (_categories.isEmpty) {
      return Center(
        child: Text(l10n.translate('reconNoCategories'),
            style: const TextStyle(fontFamily: 'Cairo')),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 1.05,
      ),
      itemCount: _categories.length,
      itemBuilder: (_, i) {
        final c = _categories[i];
        return GestureDetector(
          onTap: () =>
              _start(scope: 'category', categoryId: '${c['id']}'),
          child: Container(
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.primary.withAlpha(50)),
            ),
            child: Column(children: [
              Expanded(
                child: ClipRRect(
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(16)),
                  child: SizedBox(
                    width: double.infinity,
                    child: (c['image']?.toString().isNotEmpty ?? false)
                         ? BusinessProductImage(url: '${c['image']}',
                            fit: BoxFit.cover)
                        : Container(
                            color: AppColors.surfaceVariant.withAlpha(70),
                            child: Icon(Icons.category_outlined,
                                size: 34,
                                color: AppColors.textSecondary)),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text('${c['name'] ?? ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 12),
                        fontWeight: FontWeight.w800,
                        color: AppColors.textPrimary)),
              ),
            ]),
          ),
        );
      },
    );
  }
}
