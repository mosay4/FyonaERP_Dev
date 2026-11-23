import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/services/connectivity_service.dart';
import '../../../../shared/widgets/connectivity_widgets.dart';

/// Only for Business actions that cannot be performed locally.
Future<bool> ensureBusinessOnline(
  BuildContext context, {
  ConnectivityService? connectivity,
}) async {
  final ConnectivityService service =
      connectivity ??
      ProviderScope.containerOf(
        context,
        listen: false,
      ).read(connectivityServiceProvider);
  if (service.isOnline) return true;
  return await showOfflineDialog(context, connectivity: service);
}
