import 'package:flutter_riverpod/flutter_riverpod.dart';

final branchEpochProvider = StateProvider<int>((ref) => 0);

// Refreshing an expired token does not change the branch or remount screens.
// A cached employee copy nevertheless needs to recheck its grant revision.
final branchTokenRefreshProvider = StateProvider<int>((ref) => 0);
