import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fyona_flutter/core/utils/document_number.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/localization/app_localizations.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../sales/domain/sale_totals.dart' show parseMoney;
import '../../../core_business/data/local_commerce/local_commerce_api.dart';
import '../../../core_business/presentation/widgets/business_operation_error.dart';
import '../../data/returns_api.dart';
import '../providers/returns_providers.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';

/// Full-screen invoice picker for the returns wizard.
///
/// Opens as a complete page (not a half sheet) with a back arrow, a search
/// field that matches the invoice number / party name / product barcode, and
/// an optional camera scan button (only when barcode is enabled from
/// Inventory settings). A barcode search may return a DIFFERENT invoice type;
/// those rows are flagged so the caller can offer to switch to the right
/// returns section.
class InvoicePickerPage extends ConsumerStatefulWidget {
  final String kind; // 'sale_return' | 'purchase_return'
  const InvoicePickerPage({super.key, required this.kind});
  @override
  ConsumerState<InvoicePickerPage> createState() => _InvoicePickerPageState();
}

class _InvoicePickerPageState extends ConsumerState<InvoicePickerPage> {
  final _ctrl = TextEditingController();
  Timer? _debounce;
  List<Map<String, dynamic>> _results = [];
  bool _loading = true;
  Object? _error;
  int _reqId = 0;
  late final ReturnsApi _source;

  bool get _current =>
      mounted && identical(_source, ref.read(returnsApiProvider));

  bool get _isSale => widget.kind == 'sale_return';
  String get _invoiceType => _isSale ? 'sale' : 'purchase';
  String get _expectedType => _invoiceType;

  @override
  void initState() {
    super.initState();
    _source = ref.read(returnsApiProvider);
    _search('');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  void _onChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(
      const Duration(milliseconds: 300),
      () => _search(v.trim()),
    );
  }

  Future<void> _search(String q) async {
    if (!_current) return;
    final id = ++_reqId;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final raw = await _source.searchInvoices(_invoiceType, q);
      if (!_current || id != _reqId) return;
      setState(() {
        _results = [
          for (final m in raw.whereType<Map>()) Map<String, dynamic>.from(m),
        ];
        _loading = false;
      });
    } catch (e) {
      if (!_current || id != _reqId) return;
      setState(() {
        _loading = false;
        _error = e;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final error = _error;
    if (!identical(_source, ref.watch(returnsApiProvider))) {
      return Scaffold(
        body: Center(child: Text(l10n.translate('unauthorized'))),
      );
    }
    final hint = l10n.translate(
      _isSale ? 'retSearchInvoiceCustomer' : 'retSearchInvoiceSupplier',
    );
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        surfaceTintColor: Colors.transparent,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, size: 20),
          color: AppColors.textPrimary,
          onPressed: () => context.pop(),
        ),
        title: Text(
          l10n.translate('retChooseInvoice'),
          style: TextStyle(
            fontFamily: 'Cairo',
            fontSize: R.fontSize(context, 17),
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
          ),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: FyonaTextField(
                controller: _ctrl,
                autofocus: false,
                onChanged: _onChanged,
                textInputAction: TextInputAction.search,
                onSubmitted: (v) => _search(v.trim()),
                style: const TextStyle(fontFamily: 'Cairo'),
                decoration: InputDecoration(
                  hintText: hint,
                  hintStyle: TextStyle(
                    fontFamily: 'Cairo',
                    color: AppColors.textSecondary,
                  ),
                  prefixIcon: Icon(
                    Icons.search,
                    size: 20,
                    color: AppColors.textSecondary,
                  ),
                  filled: true,
                  fillColor: AppColors.surface,
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: AppColors.border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: AppColors.border),
                  ),
                ),
              ),
            ),
            Expanded(
              child: _loading
                  ? (_source is LocalReturnsApi
                        ? const SizedBox.shrink()
                        : const Center(child: CircularProgressIndicator()))
                  : error != null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          businessOperationError(l10n, error, fallback: 'errorOccurred'),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontFamily: 'Cairo',
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ),
                    )
                  : _results.isEmpty
                  ? Center(
                      child: Text(
                        l10n.translate('retNoInvoices'),
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          color: AppColors.textSecondary,
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                      itemCount: _results.length,
                      itemBuilder: (context, i) {
                        final inv = _results[i];
                        return _InvoiceResultTile(
                          invoice: inv,
                          isWrongType:
                              (inv['invoice_type'] ?? '').toString() !=
                              _expectedType,
                          onTap: () {
                            if (_current) context.pop(inv);
                          },
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InvoiceResultTile extends StatelessWidget {
  final Map<String, dynamic> invoice;
  final bool isWrongType;
  final VoidCallback onTap;
  const _InvoiceResultTile({
    required this.invoice,
    required this.isWrongType,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final type = (invoice['invoice_type'] ?? '').toString();
    final isSale = type == 'sale';
    final party = (invoice['customer_name'] ?? invoice['supplier_name'] ?? '')
        .toString();
    final currency = (invoice['currency'] ?? '').toString();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: AppColors.surface,
        shape: RoundedRectangleBorder(
          side: BorderSide(
            color: isWrongType ? AppColors.warning : AppColors.border,
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 4,
          ),
          leading: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: (isSale ? AppColors.success : AppColors.danger).withAlpha(
                22,
              ),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              isSale ? Icons.sell_outlined : Icons.shopping_bag_outlined,
              size: 20,
              color: isSale ? AppColors.success : AppColors.danger,
            ),
          ),
          title: Text(
            shortDocumentNumber(invoice['invoice_number']),
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: R.fontSize(context, 14),
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${party.isEmpty ? '' : '$party • '}'
                '${parseMoney(invoice['total'])} $currency',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: R.fontSize(context, 12),
                  color: AppColors.textSecondary,
                ),
              ),
              if (isWrongType)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    '${l10n.translate('retTypeLabel')}: '
                    '${l10n.translate(isSale ? 'retCustomerReturn' : 'retSupplierReturn')}',
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 11),
                      fontWeight: FontWeight.w700,
                      color: AppColors.warning,
                    ),
                  ),
                ),
            ],
          ),
          trailing: Icon(
            Icons.chevron_left_rounded,
            color: AppColors.textSecondary,
          ),
          onTap: onTap,
        ),
      ),
    );
  }
}
