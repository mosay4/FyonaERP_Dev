import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/print_service.dart';

final printServiceProvider = Provider<PrintService>((ref) => PrintService());
