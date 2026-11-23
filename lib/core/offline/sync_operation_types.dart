/// Canonical personal-finance operation catalog.
///
/// Every mutation the user performs in the personal section is recorded as ONE
/// semantic operation in the durable outbox (`sync_queue`). The sync engine
/// replays these operations through the exact same server endpoints the online
/// path uses, so the accounting effect (deduct/credit/reverse) is always
/// applied atomically and idempotently — never as an absolute balance blob.
class SyncOperationTypes {
  static const transactionCreate = 'TRANSACTION_CREATE';
  static const transactionUpdate = 'TRANSACTION_UPDATE';
  static const transactionDelete = 'TRANSACTION_DELETE';
  static const goalContribute = 'GOAL_CONTRIBUTE';
  static const goalContributionDelete = 'GOAL_CONTRIBUTION_DELETE';
  static const debtPayment = 'DEBT_PAYMENT';
  static const debtPaymentDelete = 'DEBT_PAYMENT_DELETE';

  static const bankCreate = 'BANK_CREATE';
  static const bankUpdate = 'BANK_UPDATE';
  static const bankDelete = 'BANK_DELETE';
  static const bankBalanceSet = 'BANK_BALANCE_SET';

  static const goalCreate = 'GOAL_CREATE';
  static const goalUpdate = 'GOAL_UPDATE';
  static const goalDelete = 'GOAL_DELETE';

  static const debtCreate = 'DEBT_CREATE';
  static const debtUpdate = 'DEBT_UPDATE';
  static const debtDelete = 'DEBT_DELETE';

  static const budgetCreate = 'BUDGET_CREATE';
  static const budgetUpdate = 'BUDGET_UPDATE';
  static const budgetDelete = 'BUDGET_DELETE';

  static const recurringCreate = 'RECURRING_CREATE';
  static const recurringUpdate = 'RECURRING_UPDATE';
  static const recurringDelete = 'RECURRING_DELETE';

  /// Legacy (pre-journal) operations.
  static const entityCreate = 'ENTITY_CREATE';
  static const entityUpdate = 'ENTITY_UPDATE';
  static const entityDelete = 'ENTITY_DELETE';

  /// Map a legacy INSERT/UPDATE/DELETE string to a journal operation type.
  static String fromLegacy(String operation) {
    switch (operation.toUpperCase()) {
      case 'INSERT':
        return entityCreate;
      case 'DELETE':
        return entityDelete;
      default:
        return entityUpdate;
    }
  }

  /// Semantic family for an operation — used for deterministic ordering.
  /// Definitions (parents) must reach the server before operations that
  /// reference them, and deletes must come last.
  static bool isDefinition(String type) => const {
        bankCreate,
        bankUpdate,
        bankBalanceSet,
        goalCreate,
        goalUpdate,
        debtCreate,
        debtUpdate,
        budgetCreate,
        budgetUpdate,
        recurringCreate,
        recurringUpdate,
        entityCreate,
        entityUpdate,
      }.contains(type);

  static bool isMutation(String type) => const {
        transactionCreate,
        transactionUpdate,
        transactionDelete,
        goalContribute,
        goalContributionDelete,
        debtPayment,
        debtPaymentDelete,
      }.contains(type);

  static bool isDelete(String type) => const {
        bankDelete,
        goalDelete,
        debtDelete,
        budgetDelete,
        recurringDelete,
        transactionDelete,
        goalContributionDelete,
        debtPaymentDelete,
        entityDelete,
      }.contains(type);

  /// Priority bucket: lower runs first.
  static int priority(String entityType, String operationType) {
    if (isDelete(operationType)) return 3;
    if (isMutation(operationType)) return 2;
    if (entityType == 'personal_bank_account' ||
        entityType == 'personal_savings_goal' ||
        entityType == 'personal_debt' ||
        entityType == 'personal_budget' ||
        entityType == 'personal_recurring_transaction') {
      return 1;
    }
    return 1;
  }
}

/// Sync lifecycle statuses persisted in `sync_queue.status`.
class SyncStatuses {
  static const pending = 'pending';
  static const syncing = 'syncing';
  static const failed = 'failed';
  static const conflict = 'conflict';
}
