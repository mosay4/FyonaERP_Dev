import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import 'business_product_image.dart';

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
