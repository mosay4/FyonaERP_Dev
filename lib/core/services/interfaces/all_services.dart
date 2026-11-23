// Service Interfaces Layer
// These abstract services define the contract for all business operations.
// Implementations will connect to the backend API via ApiClient.

import 'dart:typed_data';
import 'package:flutter/widgets.dart';
import '../../receipt_engine/models.dart';

// ── Accounting ──
abstract class AccountingService {
  Future<List> getChartOfAccounts();
  Future<Map?> getAccount(int id);
  Future<Map> createAccount(Map account);
  Future<Map> updateAccount(int id, Map account);
  Future<void> deleteAccount(int id);
  Future<List> getJournalEntries({int? page, int? pageSize, DateTime? from, DateTime? to});
  Future<Map> createJournalEntry(Map entry, List lines);
  Future<void> reverseJournalEntry(int id);
  Future<List> getTrialBalance({DateTime? asOf});
  Future<List> getBalanceSheet({DateTime? asOf});
  Future<List> getProfitLoss({DateTime? from, DateTime? to});
  Future<Map<String, double>> getCashFlow({DateTime? from, DateTime? to});
}

abstract class CustomerService {
  Future<List> getAll({String? search, int page = 1, int pageSize = 20});
  Future<Map?> getById(int id);
  Future<Map> create(Map customer);
  Future<Map> update(int id, Map customer);
  Future<void> delete(int id);
  Future<int> getCount({String? search});
  Future<Map<String, dynamic>> getStats();
}

abstract class SupplierService {
  Future<List> getAll({String? search, int page = 1, int pageSize = 20});
  Future<Map?> getById(int id);
  Future<Map> create(Map supplier);
  Future<Map> update(int id, Map supplier);
  Future<void> delete(int id);
}

abstract class ProductService {
  Future<List> getAll({String? search, int? categoryId, int page = 1, int pageSize = 20});
  Future<Map?> getById(int id);
  Future<Map> create(Map product);
  Future<Map> update(int id, Map product);
  Future<void> delete(int id);
  Future<List> getCategories();
  Future<Map> createCategory(Map category);
  Future<void> deleteCategory(int id);
  Future<List> getLowStock();
}

abstract class SalesService {
  Future<List> getAll({String? search, String? status, int page = 1, int pageSize = 20});
  Future<Map?> getById(int id);
  Future<Map> create(Map invoice, List lines);
  Future<Map> updateStatus(int id, String status);
  Future<void> delete(int id);
  Future<double> getTotalRevenue({DateTime? from, DateTime? to});
  Future<List> getRecent(int limit);
}

abstract class PurchaseService {
  Future<List> getAll({String? search, String? status, int page = 1, int pageSize = 20});
  Future<Map?> getById(int id);
  Future<Map> create(Map invoice, List lines);
  Future<Map> updateStatus(int id, String status);
  Future<void> delete(int id);
}

// ── Banking & Finance ──
abstract class BankingService {
  Future<List> getBankAccounts();
  Future<Map?> getBankAccount(int id);
  Future<Map> createBankAccount(Map account);
  Future<void> updateBankAccount(int id, Map account);
  Future<void> deleteBankAccount(int id);
  Future<List> getTransactions(int accountId, {int page = 1, int pageSize = 50});
  Future<void> transfer(int fromId, int toId, double amount, {String? description});
  Future<void> deposit(int accountId, double amount, {String? description});
  Future<void> withdraw(int accountId, double amount, {String? description});
  Future<List> getStatement(int accountId, {DateTime? from, DateTime? to});
}

abstract class ExpenseService {
  Future<List> getAll({int page = 1, int pageSize = 50});
  Future<Map?> getById(int id);
  Future<Map> create(Map expense);
  Future<Map> update(int id, Map expense);
  Future<void> delete(int id);
}

abstract class PaymentService {
  Future<List> getAll({int page = 1, int pageSize = 50});
  Future<Map?> getById(int id);
  Future<Map> create(Map payment);
  Future<void> delete(int id);
}

abstract class ChequeService {
  Future<List> getAll({String? status, int page = 1, int pageSize = 50});
  Future<Map?> getById(int id);
  Future<Map> create(Map cheque);
  Future<void> updateStatus(int id, String status);
  Future<void> delete(int id);
}

// ── HR ──
abstract class EmployeeService {
  Future<List> getAll({String? search, int page = 1, int pageSize = 20});
  Future<Map?> getById(int id);
  Future<Map> create(Map employee);
  Future<Map> update(int id, Map employee);
  Future<void> delete(int id);
}

abstract class PayrollService {
  Future<List> getAll({int? month, int? year});
  Future<Map> generatePayroll(int month, int year);
  Future<Uint8List> generatePayslip(int payrollId);
}

abstract class ContractService {
  Future<List> getAll({String? status, int page = 1, int pageSize = 20});
  Future<Map?> getById(int id);
  Future<Map> create(Map contract);
  Future<Map> update(int id, Map contract);
  Future<void> delete(int id);
  Future<List> getExpiring({int withinDays = 30});
}

abstract class LeaveService {
  Future<List> getAll({String? status, int page = 1, int pageSize = 20});
  Future<Map> create(Map leave);
  Future<void> approveLeave(int id);
  Future<void> rejectLeave(int id, {String? reason});
  Future<Map<String, double>> getLeaveBalance(int employeeId);
}

// ── System ──
abstract class SubscriptionService {
  Future<List> getPlans();
  Future<Map?> getPlan(int id);
  Future<bool> subscribe(int planId, {String? period});
  Future<bool> activateTrial({String? mode});
  Future<Map<String, dynamic>> getStatus();
  Future<int> getDaysRemaining();
  Future<bool> hasFeature(String feature);
}

abstract class NotificationService {
  Future<List> getAll({int limit = 50, bool? unreadOnly});
  /// Offline mirror: returns only locally-cached notifications (never network).
  Future<List> getCached({int limit = 50});
  Future<int> getUnreadCount();
  Future<void> markRead(String id);
  Future<void> markAllRead();
}

abstract class EmailService {
  Future<void> send(String to, String subject, String body, {bool isHtml = false});
  Future<List> getLogs({int page = 1, int pageSize = 50});
  Future<void> sendPasswordReset(String to, String token);
}

abstract class SettingsService {
  Future<Map<String, dynamic>> getCompanySettings();
  Future<void> updateCompanySettings(Map<String, dynamic> settings);
  Future<List> getTaxes();
  Future<void> updateTaxes(List taxes);
  Future<List> getCurrencies();
}

abstract class AuditService {
  Future<void> log(String action, String resource, {String? resourceId, String? details, String? ipAddress});
  Future<List> getLogs({int? orgId, String? action, String? resource, DateTime? from, DateTime? to, int page = 1, int pageSize = 50});
  Future<Map<String, dynamic>> getStats();
}

abstract class DataImportServiceInterface {
  Future<List<Map<String, dynamic>>> parseFile(String path, String entityType);
  Future<Map<String, dynamic>> importRecords(String entityType, List<Map<String, dynamic>> records);
  String generateTemplate(String entityType);
}

// ── Core Platform Services ──
abstract class SchedulerService {
  Future<List<Map<String, dynamic>>> getScheduledTasks();
  Future<Map<String, dynamic>> createTask(Map<String, dynamic> data);
  Future<bool> updateTask(int id, Map<String, dynamic> data);
  Future<bool> deleteTask(int id);
  Future<bool> runNow(int id);
  Future<List<Map<String, dynamic>>> getTaskLogs(int id);
  Future<Map<String, dynamic>> getSchedulerStatus();
}

abstract class FileStorageService {
  Future<Map<String, dynamic>> uploadFile(String path, Uint8List bytes, {String? folder});
  Future<Uint8List?> downloadFile(int fileId);
  Future<bool> deleteFile(int fileId);
  Future<List<Map<String, dynamic>>> listFiles({String? folder, int page = 1});
  Future<Map<String, dynamic>> getFileStats();
}

abstract class OrganizationService {
  Future<Map<String, dynamic>> getOrganization(int orgId);
  Future<bool> updateOrganization(int orgId, Map<String, dynamic> data);
  Future<Map<String, dynamic>> getOrganizationSettings(int orgId);
  Future<bool> updateOrganizationSettings(int orgId, Map<String, dynamic> data);
  Future<List<Map<String, dynamic>>> getBranches(int orgId);
  Future<Map<String, dynamic>> createBranch(Map<String, dynamic> data);
  Future<Map<String, dynamic>> getSubscriptionInfo(int orgId);
}

abstract class PermissionService {
  Future<List<String>> getUserPermissions(int userId);
  Future<bool> hasPermission(int userId, String permission);
  Future<List<String>> getRolePermissions(String role);
  Future<bool> assignPermission(int userId, String permission);
  Future<bool> revokePermission(int userId, String permission);
  Future<List<Map<String, dynamic>>> getAllPermissions();
}

abstract class UserPreferencesService {
  Future<dynamic> getPreference(String key, {dynamic defaultValue});
  Future<bool> setPreference(String key, dynamic value);
  Future<Map<String, dynamic>> getAllPreferences();
  Future<bool> resetPreference(String key);
  Future<Map<String, dynamic>> getPreferencesByGroup(String group);
}

// ── Exchange Rate ──
abstract class ExchangeRateService {
  Future<double> getRate(String from, String to);
  Future<Map<String, double>> getAllRates({String? base});
  Future<bool> refreshRates();
  DateTime? getLastUpdated();
}

// ── Trash ──
abstract class TrashService {
  Future<List<Map<String, dynamic>>> getTrashedItems({String? entityType, int page = 1});
  Future<bool> restoreItem(String entityType, int id);
  Future<bool> permanentlyDelete(String entityType, int id);
  Future<bool> emptyTrash();
  Future<Map<String, int>> getTrashStats();
}

// ── Receipt Engine ──
abstract class ReceiptService {
  Future<ReceiptData> generateReceipt(DocumentType type, Map<String, dynamic> data, {DocumentConfig? config});
  Widget previewDocument(ReceiptData data, {DocumentConfig? config});
  Future<Uint8List> exportPdf(ReceiptData data, {DocumentConfig? config});
  Future<Uint8List> exportImage(ReceiptData data, BuildContext context, {DocumentConfig? config});
  Future<void> printDocument(ReceiptData data, {DocumentConfig? config});
  Future<DocumentConfig> loadConfig({DocumentType type = DocumentType.salesInvoice});
  Future<void> saveConfig(DocumentConfig config);
  List<TemplatePreset> listTemplates();
  TemplatePreset getTemplate(DocumentType type);
  List<DocumentType> supportedTypes();
}

// ── Encryption ──
abstract class EncryptionService {
  String encrypt(String plainText);
  String decrypt(String cipherText);
  String encryptField(String value, String fieldName);
  String decryptField(String encrypted, String fieldName);
  String hashPassword(String password);
  bool verifyPassword(String password, String hash);
}

// ── Tenant Context ──
abstract class TenantService {
  Future<Map<String, dynamic>> getCurrentTenant();
  Future<bool> switchTenant(int orgId);
  Future<bool> validateTenantAccess(int orgId);
  String getTenantIsolationKey();
  Future<List<Map<String, dynamic>>> getAvailableTenants();
}

// ── Quota Management ──
abstract class QuotaService {
  Future<Map<String, dynamic>> getQuota(String feature);
  Future<bool> checkQuota(String feature);
  Future<bool> incrementUsage(String feature);
  Future<Map<String, Map<String, dynamic>>> getAllQuotas();
  Map<String, int> getPlanLimits(String plan);
}
