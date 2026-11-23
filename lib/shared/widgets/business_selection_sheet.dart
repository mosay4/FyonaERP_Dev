import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/localization/app_localizations.dart';
import '../../core/responsive/r_api.dart';
import '../../core/theme/app_colors.dart';
import '../../features/dashboard/presentation/pages/widgets/business_icon_theme.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';

/// One row in [showBusinessSelectionSheet].
class BizSheetItem<T> {
  final T value;
  final String title;
  final String? subtitle;
  final IconData? icon;
  final String? balance;
  final String? group;
  const BizSheetItem({
    required this.value,
    required this.title,
    this.subtitle,
    this.icon,
    this.balance,
    this.group,
  });
}

/// The single selection component for the whole Business section.
///
/// Title + optional search + touch-sized rows (56px+) with optional icon,
/// subtitle, balance pill and group headers; the selected row shows a clear
/// crimson check. Honours Dark/Light via [AppColors], RTL via direction
/// inheritance, rounded 24 top. Returns the chosen value (or null).
Future<T?> showBusinessSelectionSheet<T>({
  required BuildContext context,
  required String title,
  List<BizSheetItem<T>> items = const [],
  T? selected,
  bool showSearch = false,
  String? searchHint,
  Future<List<BizSheetItem<T>>> Function(String query)? onSearch,
  String? emptyText,
  String? addNewLabel,
  Future<T?> Function()? onAddNew,
  Widget Function(BuildContext, Widget)? guard,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) {
      final sheet = _BizSheet<T>(
        title: title,
        items: items,
        selected: selected,
        showSearch: showSearch,
        searchHint: searchHint,
        onSearch: onSearch,
        emptyText: emptyText,
        addNewLabel: addNewLabel,
        onAddNew: onAddNew,
      );
      return guard?.call(context, sheet) ?? sheet;
    },
  );
}

class _BizSheet<T> extends StatefulWidget {
  final String title;
  final List<BizSheetItem<T>> items;
  final T? selected;
  final bool showSearch;
  final String? searchHint;
  final Future<List<BizSheetItem<T>>> Function(String query)? onSearch;
  final String? emptyText;
  final String? addNewLabel;
  final Future<T?> Function()? onAddNew;
  const _BizSheet({
    required this.title,
    required this.items,
    this.selected,
    this.showSearch = false,
    this.searchHint,
    this.onSearch,
    this.emptyText,
    this.addNewLabel,
    this.onAddNew,
  });
  @override
  State<_BizSheet<T>> createState() => _BizSheetState<T>();
}

class _BizSheetState<T> extends State<_BizSheet<T>> {
  final _ctrl = TextEditingController();
  Timer? _debounce;
  List<BizSheetItem<T>> _visible = [];
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _visible = widget.items;
    if (widget.onSearch != null) _reload('');
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _onQuery(String q) {
    _debounce?.cancel();
    if (widget.onSearch != null) {
      _debounce = Timer(const Duration(milliseconds: 350), () => _reload(q));
      return;
    }
    final query = q.trim();
    setState(() {
      _visible = query.isEmpty
          ? widget.items
          : widget.items
              .where((e) =>
                  e.title.contains(query) ||
                  (e.subtitle ?? '').contains(query))
              .toList();
    });
  }

  Future<void> _reload(String q) async {
    setState(() => _loading = true);
    try {
      final res = await widget.onSearch!(q);
      if (mounted) setState(() => _visible = res);
    } catch (_) {
      if (mounted) setState(() => _visible = []);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final screenH = MediaQuery.of(context).size.height;
    return Container(
      // Always take the full phone width edge-to-edge, even when the
      // content is tiny (e.g. an empty list), so the sheet never looks
      // like a small centered card.
      width: double.infinity,
      // Search pickers open at a FIXED height so they never grow/jump when
      // results arrive (which looked like a hang). Non-search pickers keep
      // their natural min height.
      height: widget.showSearch ? screenH * 0.8 : null,
      constraints: widget.showSearch
          ? null
          : BoxConstraints(minHeight: 200, maxHeight: screenH * 0.75),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 12),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.border,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            widget.title,
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: R.fontSize(context, 16),
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
          if (widget.showSearch) ...[
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: FyonaTextField(
                controller: _ctrl,
                onChanged: _onQuery,
                decoration: InputDecoration(
                  hintText: widget.searchHint ?? l10n.translate('saleSearch'),
                  prefixIcon: const Icon(Icons.search, size: 20),
                ),
                style: const TextStyle(fontFamily: 'Cairo'),
              ),
            ),
          ],
          const SizedBox(height: 8),
          Flexible(
            child: _loading
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: CircularProgressIndicator(),
                    ),
                  )
                : _visible.isEmpty
                    ? Container(
                        width: double.infinity,
                        padding:
                            const EdgeInsets.fromLTRB(24, 20, 24, 28),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.inbox_outlined,
                                size: 44,
                                color: AppColors.textSecondary),
                            const SizedBox(height: 10),
                            Text(
                              widget.emptyText ??
                                  l10n.translate('saleNoItems'),
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontFamily: 'Cairo',
                                fontSize: R.fontSize(context, 14),
                                fontWeight: FontWeight.w600,
                                color: AppColors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        shrinkWrap: true,
                        itemCount: _visible.length,
                        itemBuilder: (context, i) {
                          final item = _visible[i];
                          final showGroup = item.group != null &&
                              (i == 0 ||
                                  _visible[i - 1].group != item.group);
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (showGroup)
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                      16, 12, 16, 4),
                                  child: Text(
                                    item.group!,
                                    style: TextStyle(
                                      fontFamily: 'Cairo',
                                      fontSize:
                                          R.fontSize(context, 13),
                                      fontWeight: FontWeight.w800,
                                      color: AppColors.primary,
                                    ),
                                  ),
                                ),
                              _Row(
                                item: item,
                                selected: widget.selected != null &&
                                    widget.selected == item.value,
                                onTap: () =>
                                    Navigator.pop(context, item.value),
                              ),
                            ],
                          );
                        },
                      ),
          ),
          if (widget.onAddNew != null && widget.addNewLabel != null) ...[
            Padding(
              padding: EdgeInsets.fromLTRB(
                  16, 8, 16, 16 + MediaQuery.of(context).padding.bottom),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.tonalIcon(
                  onPressed: () async {
                    final v = await widget.onAddNew!();
                    if (context.mounted && v != null) {
                      Navigator.pop(context, v);
                    }
                  },
                  icon: const Icon(Icons.add, size: 18),
                  label: Text(widget.addNewLabel!,
                      style: const TextStyle(fontFamily: 'Cairo')),
                ),
              ),
            ),
          ] else
            SizedBox(height: MediaQuery.of(context).padding.bottom + 8),
        ],
      ),
    );
  }
}

class _Row<T> extends StatelessWidget {
  final BizSheetItem<T> item;
  final bool selected;
  final VoidCallback onTap;
  const _Row({required this.item, required this.selected, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 60),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color:
              selected ? AppColors.primary.withAlpha(14) : Colors.transparent,
          border: Border(
            bottom: BorderSide(color: AppColors.border.withAlpha(120)),
          ),
        ),
        child: Row(
          children: [
            if (item.icon != null) ...[
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: bizIconChip(context),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(item.icon, size: 22, color: bizIconRed(context)),
              ),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    item.title,
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 14),
                      fontWeight:
                          selected ? FontWeight.w800 : FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  if ((item.subtitle ?? '').isNotEmpty)
                    Text(
                      item.subtitle!,
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 12),
                        color: AppColors.textSecondary,
                      ),
                    ),
                ],
              ),
            ),
            if ((item.balance ?? '').isNotEmpty) ...[
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: AppColors.surfaceVariant.withAlpha(120),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.border),
                ),
                child: Text(
                  item.balance!,
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 12),
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
            ],
            const SizedBox(width: 8),
            Icon(
              selected
                  ? Icons.check_circle
                  : Icons.radio_button_unchecked,
              size: 22,
              color: selected ? bizIconRed(context) : AppColors.textDisabled,
            ),
          ],
        ),
      ),
    );
  }
}
