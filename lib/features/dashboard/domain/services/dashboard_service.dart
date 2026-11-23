import '../../../../core/network/dio_provider.dart';
import '../../../../core/network/api_endpoints.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';

class DashboardSummary {
  final double totalSales;
  final double totalPurchases;
  final double totalExpenses;
  final double netProfit;
  final List<double> monthlyRevenue;
  final List<double> monthlyExpenses;
  const DashboardSummary({
    this.totalSales = 0,
    this.totalPurchases = 0,
    this.totalExpenses = 0,
    this.netProfit = 0,
    this.monthlyRevenue = const [],
    this.monthlyExpenses = const [],
  });
}

class RecentActivityItem {
  final String id;
  final String type;
  final String description;
  final double amount;
  final DateTime date;
  final bool isPositive;
  const RecentActivityItem({
    required this.id,
    required this.type,
    required this.description,
    this.amount = 0,
    required this.date,
    this.isPositive = true,
  });
}

class DashboardStats {
  final int totalCustomers;
  final int totalProducts;
  final int totalInvoices;
  final double revenueGrowth;
  const DashboardStats({
    this.totalCustomers = 0,
    this.totalProducts = 0,
    this.totalInvoices = 0,
    this.revenueGrowth = 0,
  });
}

class DashboardService {
  final ApiClient apiClient;
  DashboardService({required this.apiClient});

  Future<DashboardSummary> getSummary() async {
    final resp = await apiClient.getSafe(ApiEndpoints.kpi);
    if (resp.data == null) return const DashboardSummary();
    final d = resp.data;
    if (d is Map) {
      List<double> toList(dynamic raw) => raw is List
          ? raw.map((v) => (v as num?)?.toDouble() ?? 0).toList()
          : <double>[];
      return DashboardSummary(
        totalSales: (d['total_sales_amount'] as num?)?.toDouble() ?? 0,
        totalPurchases: (d['total_purchases_amount'] as num?)?.toDouble() ?? 0,
        totalExpenses: (d['total_expenses'] as num?)?.toDouble() ?? 0,
        netProfit: (d['net_profit'] as num?)?.toDouble() ?? 0,
        monthlyRevenue: toList(d['monthly_revenue']),
        monthlyExpenses: toList(d['monthly_expenses']),
      );
    }
    return const DashboardSummary();
  }

  Future<DashboardStats> getStats() async {
    final resp = await apiClient.getSafe(ApiEndpoints.kpi);
    if (resp.data == null) return const DashboardStats();
    final d = resp.data;
    if (d is Map)
      return DashboardStats(
        totalCustomers: (d['total_customers'] as num?)?.toInt() ?? 0,
        totalProducts: (d['total_products'] as num?)?.toInt() ?? 0,
        revenueGrowth: _computeGrowth(d['monthly_revenue']),
        totalInvoices: (d['total_invoices'] as num?)?.toInt() ?? 0,
      );
    return const DashboardStats();
  }

  double _computeGrowth(dynamic raw) {
    if (raw is! List) return 0;
    final values = raw
        .map((v) => (v as num?)?.toDouble() ?? 0)
        .where((v) => v > 0)
        .toList();
    if (values.length < 2) return 0;
    final prev = values[values.length - 2];
    final last = values[values.length - 1];
    if (prev == 0) return 0;
    return (last - prev) / prev * 100;
  }

  Future<List<RecentActivityItem>> getRecentActivity([int limit = 10]) async {
    final items = <RecentActivityItem>[];
    try {
      final salesResp = await apiClient.getSafe<Map<String, dynamic>>(
        ApiEndpoints.salesOrders,
        queryParameters: {'page': 1, 'per_page': limit},
      );
      final salesData = salesResp.data;
      if (salesData != null) {
        final list = salesData['items'];
        if (list is List) {
          for (final raw in list) {
            if (raw is! Map) continue;
            items.add(
              RecentActivityItem(
                id: (raw['id'] ?? '').toString(),
                type: 'sale',
                description: AppLocalizations.t('dashboardBillOfSale', {
                  'orderNumber': raw['order_number'] ?? '',
                }),
                amount: (raw['total'] as num?)?.toDouble() ?? 0,
                date:
                    DateTime.tryParse((raw['order_date'] ?? '').toString()) ??
                    DateTime.now(),
                isPositive: true,
              ),
            );
          }
        }
      }

      final purchasesResp = await apiClient.getSafe<Map<String, dynamic>>(
        ApiEndpoints.purchaseOrders,
        queryParameters: {'page': 1, 'per_page': limit},
      );
      final pData = purchasesResp.data;
      if (pData != null) {
        final list = pData['items'];
        if (list is List) {
          for (final raw in list) {
            if (raw is! Map) continue;
            items.add(
              RecentActivityItem(
                id: (raw['id'] ?? '').toString(),
                type: 'purchase',
                description: AppLocalizations.t('dashboardPurchaseInvoice', {
                  'orderNumber': raw['order_number'] ?? '',
                }),
                amount: (raw['total'] as num?)?.toDouble() ?? 0,
                date:
                    DateTime.tryParse((raw['order_date'] ?? '').toString()) ??
                    DateTime.now(),
                isPositive: false,
              ),
            );
          }
        }
      }
    } catch (_) {
      return items;
    }
    items.sort((a, b) => b.date.compareTo(a.date));
    return items.take(limit).toList();
  }
}
