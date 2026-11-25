import 'package:flutter/material.dart';
import '../../../../shared/widgets/fyona_text_field.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../core_business/data/local_directory/directory_scope.dart';
import 'business_product_image.dart';

/// Shared, compact building blocks of the inventory home and the category
/// page: one search field (optional barcode button), one row of small pill
/// filters and one product tile (image + name + status badges only).

/// Brand accent readable on both themes (the deep brand red is too dark
/// as text/icon color on the dark surfaces).
Color get inventoryAccent =>
    AppColors.isLightMode ? AppColors.primary : const Color(0xFFE8687F);

/// Soft accent tint for icon tiles / tonal buttons.
Color get inventoryAccentTint =>
    inventoryAccent.withAlpha(AppColors.isLightMode ? 22 : 34);

/// Stock / expiry state of one product row, computed exactly like the
/// badges: the status filters inside a category use the same rules so a
/// filtered product always carries the matching badge.
typedef InventoryRowStatus = ({bool low, bool out, bool expired, bool soon});

InventoryRowStatus inventoryRowStatus(
  Map<String, dynamic> product, {
  required DirectoryAccess? sourceScope,
  bool showLow = true,
  int warnDays = 30,
}) {
  final stock = (product['stock'] as num?)?.toDouble() ?? 0;
  final minStock = (product['min_stock'] as num?)?.toDouble() ?? 0;
  final isService = product['is_service'] == true;
  final low = showLow && !isService && stock > 0 && stock <= minStock;
  final exStr = (product['expiry_date'] ?? '').toString();
  final exd = exStr.isNotEmpty ? DateTime.tryParse(exStr) : null;
  final now = DateTime.now();
  final day =
      sourceScope == null ? now : DateTime(now.year, now.month, now.day);
  final expired = exd != null && exd.isBefore(day);
  final soon =
      exd != null && !expired && exd.difference(day).inDays <= warnDays;
  final out = !isService && stock <= 0;
  return (low: low, out: out, expired: expired, soon: soon);
}

/// Inventory search field; shows a barcode-scan button inside the field
/// only when [onScan] is given (barcode feature ON).
class InventorySearchField extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback? onScan;
  const InventorySearchField({
    super.key,
    required this.controller,
    required this.onChanged,
    this.onScan,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return FyonaTextField(
      controller: controller,
      onChanged: onChanged,
      decoration: InputDecoration(
        hintText: l10n.translate('invSearchHint'),
        isDense: true,
        prefixIcon: const Icon(Icons.search, size: 20),
        suffixIcon: onScan == null
            ? null
            : IconButton(
                tooltip: l10n.translate('invScanBarcode'),
                onPressed: onScan,
                icon: Icon(
                  Icons.qr_code_scanner,
                  size: 20,
                  color: inventoryAccent,
                ),
              ),
      ),
      style: const TextStyle(fontFamily: 'Cairo'),
    );
  }
}

/// Small rounded pill used for every inventory filter.
class InventoryPill extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;
  const InventoryPill({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final fg = selected ? Colors.white : AppColors.textPrimary;
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected ? AppColors.primary : AppColors.surface,
        shape: StadiumBorder(
          side: BorderSide(
            color: selected ? AppColors.primary : AppColors.border,
          ),
        ),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: Container(
            height: 30,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            alignment: Alignment.center,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 14, color: fg),
                  const SizedBox(width: 4),
                ],
                Text(
                  label,
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 12,
                    height: 1.2,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                    color: fg,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One horizontally scrollable row of pills. A `null` entry draws a thin
/// divider between groups (section pills | status pills).
class InventoryPillBar extends StatelessWidget {
  final List<Widget?> pills;
  final EdgeInsetsGeometry padding;
  const InventoryPillBar({
    super.key,
    required this.pills,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 42,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: padding,
        itemCount: pills.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (_, i) =>
            pills[i] ??
            Center(
              child: Container(
                width: 1,
                height: 18,
                margin: const EdgeInsets.symmetric(horizontal: 2),
                color: AppColors.border,
              ),
            ),
      ),
    );
  }
}

/// Status pills (الكل / قرب يخلص / خلص / قرب تنتهي / منتهي) honoring the
/// warehouse switches.
List<Widget> inventoryStatusPills(
  AppLocalizations l10n, {
  required String current,
  required ValueChanged<String> onSelect,
  required bool lowStock,
  required bool expiry,
}) {
  Widget pill(String value, String key) => InventoryPill(
    key: ValueKey('inv-status-$value'),
    label: l10n.translate(key),
    selected: current == value,
    onTap: () => onSelect(value),
  );
  return [
    pill('all', 'invFilterAll'),
    if (lowStock) pill('low', 'invFilterLow'),
    pill('out', 'invFilterOut'),
    if (expiry) ...[
      pill('expiring', 'invExpiringSoon'),
      pill('expired', 'invExpired'),
    ],
  ];
}

/// Whether [filter] is one of the pills currently offered.
bool inventoryStatusAvailable(
  String filter, {
  required bool lowStock,
  required bool expiry,
}) => switch (filter) {
  'low' => lowStock,
  'expiring' || 'expired' => expiry,
  _ => true,
};

/// Product tile: picture + name only, status badges next to the name.
class InventoryProductTile extends StatelessWidget {
  final Map<String, dynamic> product;
  final InventoryRowStatus status;
  final bool showExpiry;
  final bool selected;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Fixed 40×40 trailing slot (chevron by default).
  final Widget? trailing;
  const InventoryProductTile({
    super.key,
    required this.product,
    required this.status,
    this.showExpiry = false,
    this.selected = false,
    this.onTap,
    this.onLongPress,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final img = (product['image'] ?? '').toString();
    return Material(
      color: selected
          ? Color.alphaBlend(AppColors.primary.withAlpha(22), AppColors.surface)
          : AppColors.surface,
      shape: RoundedRectangleBorder(
        side: BorderSide(
          color: selected ? AppColors.primary : AppColors.border,
        ),
        borderRadius: BorderRadius.circular(14),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(8, 8, 4, 8),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: AppColors.surfaceVariant,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: img.isNotEmpty
                    ? BusinessProductImage(
                        url: img,
                        width: 48,
                        height: 48,
                        fit: BoxFit.cover,
                      )
                    : Icon(
                        Icons.inventory_2_outlined,
                        size: 22,
                        color: AppColors.textSecondary,
                      ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      (product['name'] ?? '').toString(),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 14),
                        fontWeight: FontWeight.w700,
                        height: 1.35,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    // «جميع الفروع»: every product names its branch.
                    if ('${product['branch_name'] ?? ''}'.trim().isNotEmpty)
                      Text(
                        '${product['branch_name']}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: R.fontSize(context, 11),
                          color: AppColors.textSecondary,
                        ),
                      ),
                  ],
                ),
              ),
              if (status.low) _badge(l10n.translate('invLow'), AppColors.warning),
              if (status.out) _badge(l10n.translate('invOut'), AppColors.danger),
              if (showExpiry)
                if (status.expired)
                  _badge(l10n.translate('invExpired'), AppColors.danger)
                else if (status.soon)
                  _badge(l10n.translate('invExpiringSoon'), AppColors.warning),
              SizedBox(
                width: 40,
                height: 40,
                child: trailing ??
                    Icon(
                      Icons.chevron_left,
                      size: 20,
                      color: AppColors.textSecondary,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _badge(String text, Color color) => Container(
    margin: const EdgeInsetsDirectional.only(start: 6),
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: color.withAlpha(28),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      text,
      style: TextStyle(
        fontFamily: 'Cairo',
        fontSize: 10,
        fontWeight: FontWeight.w700,
        color: color,
      ),
    ),
  );
}

/// Compact tinted action button (empty states: add category / products).
class InventorySmallAction extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  const InventorySmallAction({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon = Icons.add,
  });

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 16),
      label: Text(
        label,
        style: const TextStyle(
          fontFamily: 'Cairo',
          fontSize: 13,
          fontWeight: FontWeight.w700,
        ),
      ),
      style: TextButton.styleFrom(
        foregroundColor: inventoryAccent,
        backgroundColor: inventoryAccentTint,
        minimumSize: const Size(0, 34),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }
}

/// Category square (image or icon + name + products count), shared by the
/// inventory categories grid and the invoice product picker.
class InventoryCategoryTile extends StatelessWidget {
  final String name;
  final String? imageUrl;
  final num? count;
  final VoidCallback onTap;
  const InventoryCategoryTile({
    super.key,
    required this.name,
    this.imageUrl,
    this.count,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Material(
      color: AppColors.surface,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: AppColors.border),
        borderRadius: BorderRadius.circular(14),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 10, 8, 8),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 52,
                height: 52,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: inventoryAccentTint,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: (imageUrl != null && imageUrl!.isNotEmpty)
                    ? BusinessProductImage(
                        url: imageUrl,
                        width: 52,
                        height: 52,
                        fit: BoxFit.cover,
                      )
                    : Icon(
                        Icons.category_outlined,
                        size: 24,
                        color: inventoryAccent,
                      ),
              ),
              const SizedBox(height: 8),
              Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 13,
                  height: 1.3,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
              if (count != null)
                Text(
                  l10n.translate(
                    'invCatProductsCount',
                    params: {'n': '${count!.toInt()}'},
                  ),
                  maxLines: 1,
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 11,
                    height: 1.3,
                    color: AppColors.textSecondary,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
