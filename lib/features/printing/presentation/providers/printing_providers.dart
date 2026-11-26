import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/print_service.dart';

final printServiceProvider = Provider<PrintService>((ref) {
  final service = PrintService();
  // Bluetooth / USB links stay open between jobs; closed with the app scope.
  ref.onDispose(service.engine.dispose);
  return service;
});
