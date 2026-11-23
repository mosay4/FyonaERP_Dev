import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../di/dashboard_providers.dart';
import '../../domain/services/dashboard_service.dart';

class DashboardState {
  final DashboardSummary? summary;
  final DashboardStats? stats;
  final List<RecentActivityItem> recentActivity;
  final bool loading;
  final String? error;
  final bool isOfflineError;

  const DashboardState({
    this.summary,
    this.stats,
    this.recentActivity = const [],
    this.loading = false,
    this.error,
    this.isOfflineError = false,
  });

  DashboardState copyWith({
    DashboardSummary? summary,
    DashboardStats? stats,
    List<RecentActivityItem>? recentActivity,
    bool? loading,
    String? error,
    bool? isOfflineError,
  }) {
    return DashboardState(
      summary: summary ?? this.summary,
      stats: stats ?? this.stats,
      recentActivity: recentActivity ?? this.recentActivity,
      loading: loading ?? this.loading,
      error: error ?? this.error,
      isOfflineError: isOfflineError ?? false,
    );
  }
}

class DashboardNotifier extends StateNotifier<DashboardState> {
  final DashboardService _service;

  DashboardNotifier(this._service) : super(const DashboardState());

  Future<void> load() async {
    if (state.loading) return;
    state = state.copyWith(loading: true, error: null);
    try {
      final results = await Future.wait([
        _service.getSummary(),
        _service.getStats(),
        _service.getRecentActivity(5),
      ]);
      state = state.copyWith(
        summary: results[0] as DashboardSummary,
        stats: results[1] as DashboardStats,
        recentActivity: results[2] as List<RecentActivityItem>,
        loading: false,
      );
    } catch (e) {
      final isOffline =
          e is DioException &&
          (e.type == DioExceptionType.connectionError ||
              e.type == DioExceptionType.connectionTimeout ||
              e.type == DioExceptionType.sendTimeout ||
              e.type == DioExceptionType.receiveTimeout ||
              (e.message?.contains('SocketException') ?? false));
      state = state.copyWith(
        loading: false,
        error: e.toString(),
        isOfflineError: isOffline,
      );
    }
  }

  Future<void> refresh() async => load();
}

final dashboardProvider =
    StateNotifierProvider<DashboardNotifier, DashboardState>((ref) {
      final service = ref.watch(dashboardServiceProvider);
      return DashboardNotifier(service);
    });
