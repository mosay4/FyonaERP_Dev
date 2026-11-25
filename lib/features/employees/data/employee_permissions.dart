const employeePermissionGroups = <String, List<String>>{
  'dashboard': [],
  'falcon': [],
  'transactions': [],
  'income': [],
  'expenses': [],
  'reports': ['view', 'export'],
  'reconciliation': ['bank', 'inventory', 'equalize'],
  'banks': ['add_delete', 'transfer', 'details', 'balances'],
  'sales': ['create', 'view', 'delete', 'returns'],
  'purchases': ['create', 'view', 'delete', 'returns'],
  'returns': [],
  'invoices': [],
  'inventory': ['add', 'edit', 'delete', 'count', 'transfer'],
  'customers': ['add', 'edit', 'delete', 'details'],
  'suppliers': ['add', 'edit', 'delete', 'details'],
  'debts': ['add', 'settle', 'details'],
  'branches': ['view', 'transfer', 'manage'],
  'suggestions': [],
  'notifications': [],
  'chat': [],
  'transfers': [],
};

const _groupLabels = <String, (String, String)>{
  'dashboard': ('الرئيسية', 'Dashboard'),
  'ai': ('سارة', 'Sara'),
  'falcon': ('صقر', 'Saqr'),
  'transactions': ('العمليات', 'Transactions'),
  'income': ('إضافة دخل', 'Add income'),
  'expenses': ('سحب مصروف', 'Add expense'),
  'reports': ('التقارير', 'Reports'),
  'reconciliation': ('الفحص والجرد', 'Check & Count'),
  'banks': ('البنوك', 'Banks'),
  'sales': ('فواتير البيع', 'Sales invoices'),
  'purchases': ('فواتير الشراء', 'Purchase invoices'),
  'returns': ('المرتجعات', 'Returns'),
  'invoices': ('تخصيص الفواتير', 'Invoice customization'),
  'inventory': ('المخزون', 'Inventory'),
  'customers': ('العملاء', 'Customers'),
  'suppliers': ('الموردون', 'Suppliers'),
  'debts': ('الديون', 'Debts'),
  'branches': ('الفروع', 'Branches'),
  'suggestions': ('الاقتراحات', 'Suggestions'),
  'notifications': ('الإشعارات', 'Notifications'),
  'chat': ('المحادثات', 'Chat'),
  'transfers': ('التحويلات', 'Transfers'),
};

const _groupDescriptions = <String, (String, String)>{
  'dashboard': (
    'الصفحة الرئيسية والأزرار السريعة',
    'Home page and quick actions',
  ),
  'ai': ('مساعد ذكي يساعدك بالشغل', 'An intelligent assistant for your work'),
  'falcon': ('صقر — مساعد المخزون', 'Saqr — inventory assistant'),
  'transactions': (
    'سجل العمليات المسموحة له فقط',
    'Only transactions this employee may view',
  ),
  'income': ('تسجيل دخل للفرع', 'Record branch income'),
  'expenses': ('تسجيل مصروف للفرع', 'Record branch expenses'),
  'reports': (
    'تقارير البيع والشراء والأرباح',
    'Sales, purchases and profit reports',
  ),
  'reconciliation': (
    'فحص البنك وجرد المخزون وتصحيح الأرصدة',
    'Check banks, count stock and fix balances',
  ),
  'banks': ('الحسابات والفلوس والأرصدة', 'Accounts, money and balances'),
  'sales': ('فواتير البيع للعملاء', 'Sales invoices for customers'),
  'purchases': (
    'فواتير الشراء من الموردين',
    'Purchase invoices from suppliers',
  ),
  'returns': ('إرجاع بضاعة أو فاتورة', 'Return goods or invoices'),
  'invoices': ('شكل الفواتير وطباعتها', 'Invoice appearance and printing'),
  'inventory': (
    'المنتجات والكميات والجرد',
    'Products, quantities and stocktaking',
  ),
  'customers': (
    'بيانات العملاء وحساباتهم',
    'Customer information and accounts',
  ),
  'suppliers': (
    'بيانات الموردين وحساباتهم',
    'Supplier information and accounts',
  ),
  'debts': ('فلوس لك أو عليك', 'Money owed to you or by you'),
  'branches': ('الفروع والتنقل بينها', 'Branches and switching between them'),
  'suggestions': (
    'اقتراحات وتطوير التطبيق',
    'Suggestions and app improvements',
  ),
  'notifications': ('تنبيهات ورسائل', 'Alerts and messages'),
  'chat': ('محادثات داخلية', 'Internal conversations'),
  'transfers': ('نقل فلوس بين الحسابات', 'Transfer money between accounts'),
};

const _childLabels = <String, (String, String)>{
  'view': ('عرض', 'View'),
  'export': ('تصدير', 'Export'),
  'add_delete': ('إضافة وحذف', 'Add and delete'),
  'transfer': ('تحويل ومصارفة', 'Transfer and exchange'),
  'details': ('التفاصيل', 'Details'),
  'balances': ('الأرصدة', 'Balances'),
  'create': ('إنشاء', 'Create'),
  'delete': ('حذف', 'Delete'),
  'edit': ('تعديل', 'Edit'),
  'count': ('الجرد', 'Stock count'),
  'add': ('إضافة', 'Add'),
  'settle': ('سداد', 'Pay'),
  'bank': ('فحص البنك', 'Bank check'),
  'inventory': ('جرد المخزون', 'Inventory count'),
  'equalize': ('تصحيح الأرصدة', 'Fix balances'),
  'manage': ('إدارة', 'Manage'),
  'salary': ('الرواتب', 'Salaries'),
  'debts': ('الديون', 'Debts'),
  'returns': ('المرتجعات', 'Returns'),
};

String employeeGroupLabel(String key, {required bool arabic}) {
  final label = _groupLabels[key] ?? ('قسم آخر', 'Other section');
  return arabic ? label.$1 : label.$2;
}

String employeeGroupDescription(String key, {required bool arabic}) {
  final description =
      _groupDescriptions[key] ?? ('صلاحيات القسم', 'Section permissions');
  return arabic ? description.$1 : description.$2;
}

String employeeChildLabel(String key, {required bool arabic}) {
  final label = _childLabels[key] ?? ('صلاحية أخرى', 'Other permission');
  return arabic ? label.$1 : label.$2;
}

Map<String, bool> defaultEmployeePermissions({bool value = true}) {
  final out = <String, bool>{};
  for (final entry in employeePermissionGroups.entries) {
    out[entry.key] = value;
    for (final child in entry.value) {
      out['${entry.key}.$child'] = value;
    }
  }
  return out;
}

const employeePermissionOrder = [
  'dashboard',
  'banks',
  'sales',
  'purchases',
  'returns',
  'invoices',
  'inventory',
  'customers',
  'suppliers',
  'debts',
  'branches',
  'reports',
  'reconciliation',
  'transfers',
  'chat',
  'notifications',
  'suggestions',
  'falcon',
  'transactions',
  'income',
  'expenses',
];

bool employeePermissionAllowed(Map<String, bool> permissions, String key) {
  final parent = key.split('.').first;
  if (parent == 'employees' || parent == 'subscription' || parent == 'ai') return false;
  const legacy = {
    'falcon': 'inventory',
    'transactions': 'dashboard',
    'income': 'reports',
    'expenses': 'reports',
  };
  final enabled = permissions[parent] ?? permissions[legacy[parent]] ?? false;
  return enabled && (permissions[key] ?? enabled);
}

bool employeeHasFullAccess(Map<String, bool> permissions) =>
    employeePermissionGroups.entries.every(
      (entry) =>
          employeePermissionAllowed(permissions, entry.key) &&
          entry.value.every(
            (child) =>
                employeePermissionAllowed(permissions, '${entry.key}.$child'),
          ),
    );

String? employeeRoutePermission(String route) {
  if (route.startsWith('/notifications')) return 'notifications';
  if (route.startsWith('/subscription')) return 'subscription';
  if (route.startsWith('/employees')) return 'employees';
  if (route.startsWith('/banks/detail') || route.startsWith('/banks/account/'))
    return 'banks.details';
  if (route.startsWith('/banks')) return 'banks';
  if (route.startsWith('/sales/add')) return 'sales.create';
  if (route.startsWith('/sales')) return 'sales.view';
  if (route.startsWith('/purchases/add')) return 'purchases.create';
  if (route.startsWith('/purchases')) return 'purchases.view';
  if (route.startsWith('/inventory/falcon')) return 'falcon';
  if (route.startsWith('/inventory/settings')) return 'inventory.edit';
  if (route.startsWith('/inventory/count')) return 'inventory.count';
  if (route.startsWith('/inventory/product/edit')) return 'inventory.edit';
  if (route.startsWith('/inventory')) return 'inventory';
  if (route.startsWith('/customers/add')) return 'customers.add';
  if (route.startsWith('/customers/edit')) return 'customers.edit';
  if (route.startsWith('/customers/detail')) return 'customers.details';
  if (route.startsWith('/customers')) return 'customers';
  if (route.startsWith('/suppliers/add')) return 'suppliers.add';
  if (route.startsWith('/suppliers/edit')) return 'suppliers.edit';
  if (route.startsWith('/suppliers/detail')) return 'suppliers.details';
  if (route.startsWith('/suppliers')) return 'suppliers';
  if (route.startsWith('/debts/party-')) return 'debts.details';
  if (route.startsWith('/debts')) return 'debts';
  if (route.startsWith('/reports')) return 'reports.view';
  if (route.startsWith('/reconciliation/bank')) return 'reconciliation.bank';
  if (route.startsWith('/reconciliation/inventory'))
    return 'reconciliation.inventory';
  if (route.startsWith('/reconciliation')) return 'reconciliation';
  if (route.startsWith('/returns')) return 'returns';
  if (route.startsWith('/invoices')) return 'invoices';
  if (route.startsWith('/ai')) return 'ai';
  if (route.startsWith('/business/transactions')) return 'transactions';
  if (route.startsWith('/branches/transfers')) return 'branches.transfer';
  if (route.startsWith('/branches/members')) return 'branches.manage';
  if (route.startsWith('/branches')) return 'branches.view';
  return null;
}
