import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../providers/inventory_providers.dart';
import 'business_product_image.dart';

/// The picture a unit row shows: the unit's own photo (e.g. a carton),
/// otherwise its product's photo — the same rule as the product page.
/// [units] is a `productUnits` response (its `product_image`), [product] a
/// product row (its `image`).
String? businessUnitDisplayImage(
  Map? unit, {
  Map? units,
  Map? product,
}) {
  for (final candidate in [
    unit?['image'],
    units?['product_image'],
    product?['image'],
  ]) {
    if (BusinessUnitImage.has(candidate)) return '$candidate';
  }
  return null;
}

/// A unit's own photo (e.g. a carton) from the device ledger, or the unit
/// icon when it has none. Used wherever a unit is picked or shown.
class BusinessUnitImage extends StatelessWidget {
  const BusinessUnitImage({
    super.key,
    this.image,
    this.size = 42,
    this.radius = 10,
  });

  final String? image;
  final double size;
  final double radius;

  static bool has(Object? image) => '${image ?? ''}'.isNotEmpty && image != null;

  @override
  Widget build(BuildContext context) {
    final icon = Icon(Icons.straighten_outlined,
        size: size * 0.5, color: AppColors.primary);
    return Container(
      width: size,
      height: size,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: AppColors.primary.withAlpha(20),
        borderRadius: BorderRadius.circular(radius),
      ),
      child: has(image)
          ? BusinessProductImage(
              url: image,
              width: size,
              height: size,
              fit: BoxFit.cover,
              placeholder: Center(child: icon),
            )
          : Center(child: icon),
    );
  }
}

/// The photo of an invoice line's unit (returns): the line's unit by id, else
/// by name, else the product's photo; nothing for a line without a product.
class BusinessLineUnitImage extends ConsumerWidget {
  const BusinessLineUnitImage({
    super.key,
    required this.productId,
    this.unitId,
    this.unitName,
    this.size = 38,
  });

  final String? productId;
  final String? unitId;
  final String? unitName;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = productId;
    if (id == null || id.isEmpty) return const SizedBox.shrink();
    final data = ref
        .watch(productUnitsProvider((id: id, target: null)))
        .asData
        ?.value;
    if (data == null) return SizedBox.square(dimension: size);
    final units = (data['units'] as List? ?? const []).whereType<Map>();
    final unit =
        units.where((u) => unitId != null && '${u['id']}' == unitId).firstOrNull ??
        units
            .where((u) =>
                (unitName ?? '').isNotEmpty && '${u['name']}' == unitName)
            .firstOrNull;
    return BusinessUnitImage(
      image: businessUnitDisplayImage(unit, units: data),
      size: size,
      radius: 8,
    );
  }
}
