import 'dart:core';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../features/personal/di/personal_providers.dart';
import '../../../features/ai/domain/agent/sara_money.dart';
import '../utils/currency_formatter.dart';

/// OfflineSara: rule-based local assistant used when the Cloud AI endpoint is
/// unreachable. It reads the SAME repositories/services the UI uses
/// (PersonalFinanceServiceProvider), never its own business logic, so the data
/// it sees and the writes it makes go through the exact same offline-first
/// paths (mirror + outbox) as the real UI.
class OfflineSara {
  /// Returns a local answer for [query], or null when it can't be answered
  /// locally. Answering "offline" never fakes persistence success — the
  /// service layer still routes any write through the outbox.
  static Future<String?> answer({
    required Ref ref,
    required String query,
    String accountType = 'personal',
  }) async {
    final q = query.toLowerCase().trim();
    if (q.isEmpty) return null;
    try {
      if (_matchesBalance(q)) return await _localStats(ref, accountType);
      if (_matchesAccounts(q)) return await _localAccounts(ref);
      if (_matchesAnalytics(q)) return await _localAnalytics(ref);
      if (_matchesSalary(q) || _matchesExpenses(q)) {
        return await _localTransactionSummary(ref, accountType);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  static bool _matchesBalance(String q) =>
      q.contains('رصيد') || q.contains('الرصيد') || q.contains('balance') ||
      q.contains('كم معي') || q.contains('كم عندي') || q.contains('كم لدي') ||
      q.contains('كم رصيد');

  static bool _matchesAccounts(String q) =>
      q.contains('حسابات') || q.contains('البنوك') || q.contains('accounts') ||
      q.contains('wallets') || q.contains('محافظ') || q.contains('الحسابات');

  static bool _matchesSalary(String q) =>
      q.contains('مصروف') || q.contains('دخل') || q.contains('expense') ||
      q.contains('income') || q.contains('ايراد') || q.contains('إيراد');

  static bool _matchesExpenses(String q) =>
      q.contains('عمليات') || q.contains('transactions') || q.contains('معاملات');

  static bool _matchesAnalytics(String q) =>
      q.contains('تحليل') || q.contains('حلل') || q.contains('تقرير') ||
      q.contains('تقارير') || q.contains('ملخص') || q.contains('مقارنة') ||
      q.contains('قارن') || q.contains('وضع') || q.contains('احصائ') ||
      q.contains('إحصائ') || q.contains('أعلى') ||
      q.contains('analytics') || q.contains('report') || q.contains('summary') ||
      q.contains('compare') || q.contains('analysis');

  static Future<String?> _localStats(Ref ref, String accountType) async {
    final service = ref.read(personalFinanceServiceProvider);
    final accounts = await service.getBankAccounts();
    if (accounts.isEmpty) {
      return 'لا توجد حسابات محفوظة حتى الآن — يمكنك إضافة حسابك الأول من الشاشة الرئيسية بسهولة.';
    }
    // Per-currency only: different currencies are never added together.
    final totals = groupAmounts(
      accounts, (a) => a.balance, (a) => a.currency);
    final scope = accountType == 'business' ? 'نظام الأعمال' : 'حسابك الشخصي';
    return 'رصيدك الحالي في $scope حسب العملة:\n'
        '${formatBreakdown(totals, arabic: true)}\n'
        'عبر ${accounts.length.toString()} حساب.';
  }

  static Future<String?> _localAccounts(Ref ref) async {
    final service = ref.read(personalFinanceServiceProvider);
    final accounts = await service.getBankAccounts();
    if (accounts.isEmpty) return 'لا توجد حسابات محفوظة.';
    final sb = StringBuffer();
    sb.write('حساباتك المحفوظة:\n');
    var i = 1;
    for (final a in accounts) {
      sb.write('${i.toString()}. ${a.bankName.isEmpty ? 'حساب' : a.bankName} — ${_fmt(a.balance)} ${a.currency.isEmpty ? 'SAR' : a.currency}\n');
      i++;
    }
    return sb.toString();
  }

  static Future<String?> _localTransactionSummary(Ref ref, String accountType) async {
    final service = ref.read(personalFinanceServiceProvider);
    final txs = await service.getTransactions();
    if (txs.isEmpty) return 'لا توجد معاملات محفوظة حتى الآن.';
    final inc = groupAmounts(
      txs.where((t) => t.type == 'income'), (t) => t.amount, (t) => t.currency);
    final exp = groupAmounts(
      txs.where((t) => t.type != 'income'), (t) => t.amount, (t) => t.currency);
    return 'آخر ملخص محلي (عدد العمليات: ${txs.length.toString()}):\n'
        'إيرادات ${formatBreakdown(inc, arabic: true)}\n'
        'مصروفات ${formatBreakdown(exp, arabic: true)}';
  }

  /// Compact month analytics from LOCAL data only (offline).
  /// Read-only: same services the UI uses, per-currency buckets, real names.
  /// Never presented as server-confirmed (caller adds the offline note).
  static Future<String?> _localAnalytics(Ref ref) async {
    final service = ref.read(personalFinanceServiceProvider);
    final now = DateTime.now();
    final txs = await service.getTransactions(month: now.month, year: now.year);
    final sb = StringBuffer('تحليلك المحلي لهذا الشهر (من بياناتك المحلية):\n');
    if (txs.isEmpty) {
      sb.write('لا توجد معاملات هذا الشهر بعد — أضف أول عملية من الشاشة الرئيسية.');
    } else {
      final inc = groupAmounts(
        txs.where((t) => t.type == 'income'), (t) => t.amount, (t) => t.currency);
      final exp = groupAmounts(
        txs.where((t) => t.type != 'income'), (t) => t.amount, (t) => t.currency);
      sb.write('إيرادات ${formatBreakdown(inc, arabic: true)}\n');
      sb.write('مصروفات ${formatBreakdown(exp, arabic: true)}\n');
      // Top expense categories per currency (real names, bounded to 3).
      final byCat = <String, double>{};
      for (final t in txs.where((t) => t.type != 'income')) {
        final key = '${t.category}|${saraCurrencyId(t.currency)}';
        byCat[key] = (byCat[key] ?? 0) + t.amount;
      }
      final top = byCat.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      var shown = 0;
      for (final e in top) {
        if (shown >= 3) break;
        final parts = e.key.split('|');
        sb.write('• ${parts[0]}: ${_fmt(e.value)} ${parts[1]}\n');
        shown++;
      }
    }
    // Budgets progress (stored totals — same values the UI shows).
    try {
      final budgets = await service.getBudgets(now.month, now.year);
      for (final b in budgets.take(3)) {
        if (b.totalAmount <= 0) continue;
        final pct = (b.totalSpent / b.totalAmount * 100).toStringAsFixed(1);
        sb.write('ميزانية ${b.name}: ${b.totalSpent} من ${b.totalAmount} ${b.currency} ($pct%)\n');
      }
    } catch (_) {}
    // Goals + active debts (real names, bounded).
    try {
      final goals = await service.getSavingsGoals();
      for (final g in goals.where((g) => !g.isCompleted).take(2)) {
        final pct = g.targetAmount > 0
            ? (g.currentAmount / g.targetAmount * 100).toStringAsFixed(0)
            : '0';
        sb.write('هدف ${g.name}: ${g.currentAmount} من ${g.targetAmount} ${g.currency} ($pct%)\n');
      }
      final debts = await service.getDebts();
      for (final d in debts.where((d) => !d.isPaid).take(2)) {
        sb.write('دين ${d.personName}: المتبقي ${d.remaining} ${d.currency}\n');
      }
    } catch (_) {}
    return sb.toString();
  }

  static String _fmt(double v) => fmtNum(v);
}