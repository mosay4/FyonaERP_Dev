import '../database_helper.dart';

class PersonalRepository {
  // ── Personal Wallet ──
  Future<int> upsertWallet(Map<String, dynamic> data) async {
    final existing = await DatabaseHelper.query('personal_wallets', where: 'user_id = ?', whereArgs: [data['user_id']]);
    if (existing.isNotEmpty) {
      await DatabaseHelper.update('personal_wallets', data, 'user_id = ?', [data['user_id']]);
      return existing.first['id'] as int;
    }
    return await DatabaseHelper.insert('personal_wallets', data);
  }

  Future<Map<String, dynamic>?> getWallet(int userId) async {
    final rows = await DatabaseHelper.query('personal_wallets', where: 'user_id = ?', whereArgs: [userId]);
    return rows.isNotEmpty ? rows.first : null;
  }

  Future<int> updateWalletBalance(int userId, double balance) async {
    return await DatabaseHelper.update('personal_wallets', {'balance': balance, 'updated_at': DateTime.now().toIso8601String()}, 'user_id = ?', [userId]);
  }

  // ── Personal Transactions ──
  Future<int> insertTransaction(Map<String, dynamic> data) async {
    return await DatabaseHelper.insert('personal_transactions', data);
  }

  Future<List<Map<String, dynamic>>> getTransactions(int userId, {int? limit, int? offset}) async {
    return await DatabaseHelper.query('personal_transactions', where: 'user_id = ?', whereArgs: [userId], orderBy: 'date DESC', limit: limit, offset: offset);
  }

  Future<List<Map<String, dynamic>>> getTransactionsByCategory(int userId, String category) async {
    return await DatabaseHelper.query('personal_transactions', where: 'user_id = ? AND category = ?', whereArgs: [userId, category], orderBy: 'date DESC');
  }

  Future<List<Map<String, dynamic>>> getTransactionsByType(int userId, String txType) async {
    return await DatabaseHelper.query('personal_transactions', where: 'user_id = ? AND tx_type = ?', whereArgs: [userId, txType], orderBy: 'date DESC');
  }

  Future<double> getTotalIncome(int userId) async {
    final result = await DatabaseHelper.rawQuery('SELECT COALESCE(SUM(amount), 0) as total FROM personal_transactions WHERE user_id = ? AND tx_type = ?', [userId, 'income']);
    return (result.first['total'] as num).toDouble();
  }

  Future<double> getTotalExpenses(int userId) async {
    final result = await DatabaseHelper.rawQuery('SELECT COALESCE(SUM(amount), 0) as total FROM personal_transactions WHERE user_id = ? AND tx_type = ?', [userId, 'expense']);
    return (result.first['total'] as num).toDouble();
  }

  Future<int> deleteTransaction(int id) async {
    return await DatabaseHelper.delete('personal_transactions', 'id = ?', [id]);
  }

  // ── Savings Goals ──
  Future<int> insertGoal(Map<String, dynamic> data) async {
    return await DatabaseHelper.insert('savings_goals', data);
  }

  Future<List<Map<String, dynamic>>> getGoals(int userId) async {
    return await DatabaseHelper.query('savings_goals', where: 'user_id = ?', whereArgs: [userId], orderBy: 'created_at DESC');
  }

  Future<Map<String, dynamic>?> getGoal(int id) async {
    final rows = await DatabaseHelper.query('savings_goals', where: 'id = ?', whereArgs: [id]);
    return rows.isNotEmpty ? rows.first : null;
  }

  Future<int> updateGoal(int id, Map<String, dynamic> data) async {
    data['updated_at'] = DateTime.now().toIso8601String();
    return await DatabaseHelper.update('savings_goals', data, 'id = ?', [id]);
  }

  Future<int> addToGoal(int id, double amount) async {
    final goal = await getGoal(id);
    if (goal == null) return 0;
    final current = (goal['current_amount'] as num).toDouble();
    final target = (goal['target_amount'] as num).toDouble();
    final newCurrent = current + amount;
    final isCompleted = newCurrent >= target ? 1 : 0;
    return await DatabaseHelper.update('savings_goals', {
      'current_amount': newCurrent,
      'is_completed': isCompleted,
      'updated_at': DateTime.now().toIso8601String(),
    }, 'id = ?', [id]);
  }

  Future<int> deleteGoal(int id) async {
    return await DatabaseHelper.delete('savings_goals', 'id = ?', [id]);
  }

  // ── Personal Bank Accounts ──
  Future<int> insertBankAccount(Map<String, dynamic> data) async {
    return await DatabaseHelper.insert('personal_bank_accounts', data);
  }

  Future<List<Map<String, dynamic>>> getBankAccounts(int userId) async {
    return await DatabaseHelper.query('personal_bank_accounts', where: 'user_id = ?', whereArgs: [userId], orderBy: 'sort_order ASC');
  }

  Future<Map<String, dynamic>?> getBankAccount(int id) async {
    final rows = await DatabaseHelper.query('personal_bank_accounts', where: 'id = ?', whereArgs: [id]);
    return rows.isNotEmpty ? rows.first : null;
  }

  Future<int> updateBankAccount(int id, Map<String, dynamic> data) async {
    data['updated_at'] = DateTime.now().toIso8601String();
    return await DatabaseHelper.update('personal_bank_accounts', data, 'id = ?', [id]);
  }

  Future<int> deleteBankAccount(int id) async {
    return await DatabaseHelper.delete('personal_bank_accounts', 'id = ?', [id]);
  }

  // ── Personal Bank Transactions ──
  Future<int> insertBankTransaction(Map<String, dynamic> data) async {
    return await DatabaseHelper.insert('personal_bank_transactions', data);
  }

  Future<List<Map<String, dynamic>>> getBankTransactions(int accountId) async {
    return await DatabaseHelper.query('personal_bank_transactions', where: 'account_id = ?', whereArgs: [accountId], orderBy: 'date DESC');
  }

  Future<int> deleteBankTransaction(int id) async {
    return await DatabaseHelper.delete('personal_bank_transactions', 'id = ?', [id]);
  }

  // ── Personal Debts ──
  Future<int> insertDebt(Map<String, dynamic> data) async {
    return await DatabaseHelper.insert('personal_debts', data);
  }

  Future<List<Map<String, dynamic>>> getDebts(int userId) async {
    return await DatabaseHelper.query('personal_debts', where: 'user_id = ?', whereArgs: [userId], orderBy: 'created_at DESC');
  }

  Future<List<Map<String, dynamic>>> getDebtsByType(int userId, String debtType) async {
    return await DatabaseHelper.query('personal_debts', where: 'user_id = ? AND debt_type = ?', whereArgs: [userId, debtType], orderBy: 'due_date ASC');
  }

  Future<List<Map<String, dynamic>>> getDebtsByStatus(int userId, String status) async {
    return await DatabaseHelper.query('personal_debts', where: 'user_id = ? AND status = ?', whereArgs: [userId, status], orderBy: 'due_date ASC');
  }

  Future<Map<String, dynamic>?> getDebt(int id) async {
    final rows = await DatabaseHelper.query('personal_debts', where: 'id = ?', whereArgs: [id]);
    return rows.isNotEmpty ? rows.first : null;
  }

  Future<int> updateDebt(int id, Map<String, dynamic> data) async {
    data['updated_at'] = DateTime.now().toIso8601String();
    return await DatabaseHelper.update('personal_debts', data, 'id = ?', [id]);
  }

  Future<int> markDebtPaid(int id) async {
    return await DatabaseHelper.update('personal_debts', {
      'is_paid': 1, 'status': 'paid',
      'paid_date': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    }, 'id = ?', [id]);
  }

  Future<int> updateDebtPaidAmount(int id, double paid) async {
    return await DatabaseHelper.update('personal_debts', {
      'paid': paid,
      'updated_at': DateTime.now().toIso8601String(),
    }, 'id = ?', [id]);
  }

  Future<int> deleteDebt(int id) async {
    await DatabaseHelper.rawDelete('DELETE FROM personal_debt_payments WHERE debt_id = ?', [id]);
    return await DatabaseHelper.delete('personal_debts', 'id = ?', [id]);
  }

  // ── Personal Debt Payments ──
  Future<int> insertDebtPayment(Map<String, dynamic> data) async {
    return await DatabaseHelper.insert('personal_debt_payments', data);
  }

  Future<List<Map<String, dynamic>>> getDebtPayments(int debtId) async {
    return await DatabaseHelper.query('personal_debt_payments', where: 'debt_id = ?', whereArgs: [debtId], orderBy: 'payment_date DESC');
  }

  Future<double> getTotalDebtPayments(int debtId) async {
    final result = await DatabaseHelper.rawQuery('SELECT COALESCE(SUM(amount), 0) as total FROM personal_debt_payments WHERE debt_id = ?', [debtId]);
    return (result.first['total'] as num).toDouble();
  }

  Future<int> deleteDebtPayment(int id) async {
    return await DatabaseHelper.delete('personal_debt_payments', 'id = ?', [id]);
  }

  // ── Spending Categories ──
  Future<int> insertCategory(Map<String, dynamic> data) async {
    return await DatabaseHelper.insert('spending_categories', data);
  }

  Future<List<Map<String, dynamic>>> getCategories(int userId) async {
    return await DatabaseHelper.query('spending_categories', where: 'user_id = ?', whereArgs: [userId], orderBy: 'sort_order ASC');
  }

  Future<int> updateCategory(int id, Map<String, dynamic> data) async {
    return await DatabaseHelper.update('spending_categories', data, 'id = ?', [id]);
  }

  Future<int> deleteCategory(int id) async {
    return await DatabaseHelper.delete('spending_categories', 'id = ?', [id]);
  }

  // ── Personal Exchange Rates ──
  Future<int> insertExchangeRate(Map<String, dynamic> data) async {
    return await DatabaseHelper.insert('personal_exchange_rates', data);
  }

  Future<List<Map<String, dynamic>>> getExchangeRates(int userId) async {
    return await DatabaseHelper.query('personal_exchange_rates', where: 'user_id = ?', whereArgs: [userId]);
  }

  Future<Map<String, dynamic>?> getExchangeRate(int userId, String from, String to) async {
    final rows = await DatabaseHelper.query('personal_exchange_rates', where: 'user_id = ? AND from_currency = ? AND to_currency = ?', whereArgs: [userId, from, to]);
    return rows.isNotEmpty ? rows.first : null;
  }

  Future<int> updateExchangeRate(int id, double rate) async {
    return await DatabaseHelper.update('personal_exchange_rates', {'rate': rate, 'updated_at': DateTime.now().toIso8601String()}, 'id = ?', [id]);
  }

  Future<int> deleteExchangeRate(int id) async {
    return await DatabaseHelper.delete('personal_exchange_rates', 'id = ?', [id]);
  }

  // ── Recurring Transactions ──
  Future<int> insertRecurring(Map<String, dynamic> data) async {
    return await DatabaseHelper.insert('personal_recurring_transactions', data);
  }

  Future<List<Map<String, dynamic>>> getRecurring(int userId) async {
    return await DatabaseHelper.query('personal_recurring_transactions', where: 'user_id = ?', whereArgs: [userId], orderBy: 'next_date ASC');
  }

  Future<List<Map<String, dynamic>>> getActiveRecurring(int userId) async {
    return await DatabaseHelper.query('personal_recurring_transactions', where: 'user_id = ? AND is_active = 1', whereArgs: [userId], orderBy: 'next_date ASC');
  }

  Future<Map<String, dynamic>?> getRecurringById(int id) async {
    final rows = await DatabaseHelper.query('personal_recurring_transactions', where: 'id = ?', whereArgs: [id]);
    return rows.isNotEmpty ? rows.first : null;
  }

  Future<int> updateRecurring(int id, Map<String, dynamic> data) async {
    data['updated_at'] = DateTime.now().toIso8601String();
    return await DatabaseHelper.update('personal_recurring_transactions', data, 'id = ?', [id]);
  }

  Future<int> deleteRecurring(int id) async {
    return await DatabaseHelper.delete('personal_recurring_transactions', 'id = ?', [id]);
  }

  // ── Personal Budgets ──
  Future<int> insertBudget(Map<String, dynamic> data) async {
    return await DatabaseHelper.insert('personal_budgets', data);
  }

  Future<List<Map<String, dynamic>>> getBudgets(int userId, int month, int year) async {
    return await DatabaseHelper.query('personal_budgets', where: 'user_id = ? AND month = ? AND year = ?', whereArgs: [userId, month, year], orderBy: 'category ASC');
  }

  Future<List<Map<String, dynamic>>> getAllBudgets(int userId) async {
    return await DatabaseHelper.query('personal_budgets', where: 'user_id = ?', whereArgs: [userId], orderBy: 'year DESC, month DESC, category ASC');
  }

  Future<Map<String, dynamic>?> getBudget(int id) async {
    final rows = await DatabaseHelper.query('personal_budgets', where: 'id = ?', whereArgs: [id]);
    return rows.isNotEmpty ? rows.first : null;
  }

  Future<int> updateBudget(int id, Map<String, dynamic> data) async {
    data['updated_at'] = DateTime.now().toIso8601String();
    return await DatabaseHelper.update('personal_budgets', data, 'id = ?', [id]);
  }

  Future<int> deleteBudget(int id) async {
    return await DatabaseHelper.delete('personal_budgets', 'id = ?', [id]);
  }

  /// Deterministic personal wipe for ONE user namespace: children before
  /// parents inside a single transaction (all-or-nothing), strictly
  /// user-scoped. Never touches sync engine tables, other users, backup
  /// files, or auth/session state.
  Future<void> resetAllData(int userId) async {
    await DatabaseHelper.transaction((tx) async {
      // Children / link tables first (parents still present for subselects).
      await tx.rawDelete(
          'DELETE FROM personal_bank_transactions WHERE account_id IN (SELECT id FROM personal_bank_accounts WHERE user_id = ?)',
          [userId]);
      await tx.rawDelete(
          'DELETE FROM budget_categories WHERE budget_id IN (SELECT id FROM personal_budgets WHERE user_id = ?)',
          [userId]);
      await tx.rawDelete('DELETE FROM personal_debt_payments WHERE user_id = ?', [userId]);
      await tx.rawDelete('DELETE FROM personal_transactions WHERE user_id = ?', [userId]);
      await tx.rawDelete('DELETE FROM savings_goals WHERE user_id = ?', [userId]);
      await tx.rawDelete('DELETE FROM personal_debts WHERE user_id = ?', [userId]);
      await tx.rawDelete('DELETE FROM personal_exchange_rates WHERE user_id = ?', [userId]);
      await tx.rawDelete('DELETE FROM spending_categories WHERE user_id = ?', [userId]);
      await tx.rawDelete('DELETE FROM personal_budgets WHERE user_id = ?', [userId]);
      await tx.rawDelete('DELETE FROM personal_recurring_transactions WHERE user_id = ?', [userId]);
      await tx.rawDelete('DELETE FROM personal_wallets WHERE user_id = ?', [userId]);
      await tx.rawDelete('DELETE FROM personal_bank_accounts WHERE user_id = ?', [userId]);
    });
  }
}
