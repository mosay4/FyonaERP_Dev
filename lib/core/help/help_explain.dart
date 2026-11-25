import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';
import 'help_content.dart';

class HelpExplainData {
  final String title;
  final String body;
  final List<String> steps;
  final IconData icon;
  final String? asset;
  final Color iconColor;
  const HelpExplainData({
    required this.title,
    required this.body,
    required this.steps,
    required this.icon,
    this.asset,
    this.iconColor = Colors.white,
  });
}

class _StepRule {
  final String match;
  final bool isRoute;
  final List<String> ar;
  final List<String> en;
  const _StepRule(this.match, this.isRoute, this.ar, this.en);
}

class _IconRule {
  final String match;
  final IconData icon;
  const _IconRule(this.match, this.icon);
}

class HelpExplain {
  HelpExplain._();

  static HelpExplainData resolve({
    required String route,
    required String label,
    required bool arabic,
  }) {
    final base = HelpContent.resolve(route: route, label: label, arabic: arabic);
    final visual = _visual(route: route, label: label);
    return HelpExplainData(
      title: base.title,
      body: base.body,
      steps: _steps(route: route, label: label, arabic: arabic),
      icon: visual.icon,
      asset: visual.asset,
      iconColor: visual.color,
    );
  }

  static const List<String> _specificStems = [
    'سحب',
    'إيداع',
    'تحويل',
    'دخل',
    'دفع',
    'اشتراك',
  ];

  static List<String> _steps({
    required String route,
    required String label,
    required bool arabic,
  }) {
    final hay = '${route.toLowerCase()} $label';
    for (final stem in _specificStems) {
      if (!hay.contains(stem)) continue;
      for (final rule in _stepRules) {
        if (!rule.isRoute && rule.match == stem) {
          final list = arabic ? rule.ar : rule.en;
          return list.length > 4 ? list.sublist(0, 4) : list;
        }
      }
    }
    _StepRule? best;
    // Element first, section second: a button with its own curated flow
    // (pay, collect, execute…) must explain ITSELF, not its screen. Longer
    // (more specific) matches win over generic ones.
    final labelRules = _stepRules.where((r) => !r.isRoute).toList()
      ..sort((a, b) => b.match.length.compareTo(a.match.length));
    for (final rule in labelRules) {
      if (hay.contains(rule.match)) {
        best = rule;
        break;
      }
    }
    // An element with its own curated description but no curated flow gets
    // description-only: the screen's generic flow does not describe THIS
    // button, so showing it would mislead.
    if (best == null &&
        label.trim().isNotEmpty &&
        HelpContent.hasExactLabel(label, arabic: arabic)) {
      return const <String>[];
    }
    if (best == null) {
      for (final rule in _stepRules) {
        if (rule.isRoute) {
          if (route.toLowerCase().startsWith(rule.match) &&
              (best == null || rule.match.length > best.match.length)) {
            best = rule;
          }
        }
      }
    }
    // No curated flow for this element: no steps at all. The card renders
    // description-only — a generic filler would be a lie about the UI.
    if (best == null) return const <String>[];
    final picked = best;
    final list = arabic ? picked.ar : picked.en;
    return list.length > 4 ? list.sublist(0, 4) : list;
  }

  static ({IconData icon, String? asset, Color color}) _visual({
    required String route,
    required String label,
  }) {
    final hay = '${route.toLowerCase()} $label';
    final lower = label.toLowerCase();
    if (route.toLowerCase().startsWith('/personal/ai') ||
        route.toLowerCase() == '/ai' ||
        hay.contains('سارة') ||
        lower.contains('sara')) {
      return (
        icon: Icons.smart_toy_outlined,
        asset: 'assets/images/sara_avatar.jpg',
        color: Colors.white,
      );
    }
    final r = route.toLowerCase();
    _IconRule? best;
    for (final rule in _routeIcons) {
      if (r.startsWith(rule.match) &&
          (best == null || rule.match.length > best.match.length)) {
        best = rule;
      }
    }
    IconData icon = Icons.touch_app_rounded;
    if (best != null) {
      icon = best.icon;
    } else {
      // Income/expense intent reads exactly like the app's own tiles
      // (arrow down in green / arrow up in red) instead of a generic plus.
      final wantsIncome = hay.contains('دخل') ||
          hay.contains('إيداع') ||
          lower.contains('income') ||
          lower.contains('deposit');
      final wantsExpense = hay.contains('سحب') ||
          hay.contains('مصروف') ||
          lower.contains('expense') ||
          lower.contains('withdraw');
      if (wantsIncome && !wantsExpense) {
        return (
          icon: Icons.arrow_downward_rounded,
          asset: null,
          color: AppColors.success
        );
      }
      if (wantsExpense && !wantsIncome) {
        return (
          icon: Icons.arrow_upward_rounded,
          asset: null,
          color: AppColors.danger
        );
      }
      // Longest match wins: 'إضافة دخل' must read as income (trending_up),
      // not as a generic add (plus) — same rule as step resolution.
      _IconRule? labelBest;
      for (final rule in _labelIcons) {
        if (hay.contains(rule.match) &&
            (labelBest == null ||
                rule.match.length > labelBest.match.length)) {
          labelBest = rule;
        }
      }
      if (labelBest != null) icon = labelBest.icon;
    }
    return (icon: icon, asset: null, color: _iconColor(hay: hay, lower: lower));
  }

  static Color _iconColor({required String hay, required String lower}) {
    // Income/expense follow the home screen's exact palette so a clicker on
    // "إيداع"/"سحب" reads the same green/red the dashboard already teaches.
    if (hay.contains('دخل') ||
        hay.contains('إيداع') ||
        hay.contains('راتب') ||
        lower.contains('income') ||
        lower.contains('deposit') ||
        lower.contains('salary')) {
      return AppColors.success;
    }
    if (hay.contains('مصروف') ||
        hay.contains('سحب') ||
        lower.contains('expense') ||
        lower.contains('withdraw')) {
      return AppColors.danger;
    }
    if (hay.contains('تحويل') || lower.contains('transfer')) {
      return const Color(0xFF8FB8FF);
    }
    if (hay.contains('دين') || lower.contains('debt')) {
      return const Color(0xFFC9A7EB);
    }
    if (hay.contains('هدف') || lower.contains('goal')) {
      return const Color(0xFF7FD8C9);
    }
    if (hay.contains('تقرير') ||
        hay.contains('تحليل') ||
        lower.contains('report') ||
        lower.contains('analy')) {
      return const Color(0xFF8AC6E8);
    }
    if (hay.contains('حذف') || lower.contains('delete')) {
      return const Color(0xFFFF8A8A);
    }
    if (hay.contains('حفظ') || lower.contains('save')) {
      return const Color(0xFF8FD694);
    }
    return Colors.white;
  }

  static const List<_StepRule> _stepRules = [
    _StepRule(
      '/personal/recurring',
      true,
      [
        'أنشئ قاعدة متكررة وحدد المبلغ والتكرار.',
        'اربطها بالحساب وفعّل التنفيذ التلقائي.',
        'يتحقق التطبيق من الرصيد قبل كل تنفيذ وينبهك عند النقص.',
      ],
      [
        'Create a recurring rule with amount and frequency.',
        'Link it to an account and enable auto execution.',
        'The app checks the balance before each run and warns you.',
      ],
    ),
    _StepRule(
      '/personal/banks',
      true,
      [
        'افتح الحساب تشوف رصيده وحركاته.',
        'من داخل الحساب تضيف دخل أو تسحب أو تحوّل.',
        'راجع كشف الحساب لأي فترة.',
      ],
      [
        'Open an account to see its balance and movements.',
        'Inside it you can add income, withdraw or transfer.',
        'Review the statement for any period.',
      ],
    ),
    _StepRule(
      '/banks',
      true,
      [
        'اختر الحساب البنكي لعرض الرصيد والحركات.',
        'نفّذ حوالة أو راجع الكشف.',
        'أضف حساباً جديداً عند الحاجة.',
      ],
      [
        'Pick the bank account to see balance and movements.',
        'Make a transfer or review the statement.',
        'Add a new account when needed.',
      ],
    ),
    _StepRule(
      '/personal/transactions',
      true,
      [
        'سجّل دخلاً أو مصروفاً بالعملة والتصنيف.',
        'ابحث وصفِّ حسب النوع والتاريخ.',
        'اضغط أي معاملة تشوف إيصالها، وبالضغطة المطولة تطلع لك خيارات العرض والحذف.',
      ],
      [
        'Record income or expense with currency and category.',
        'Search and filter by type and date.',
        'Tap any transaction for its receipt; long-press shows view and delete options.',
      ],
    ),
    _StepRule(
      '/personal/savings',
      true,
      [
        'أنشئ هدفاً بالمبلغ والتاريخ المستهدف.',
        'أضف مبالغ إليه بشكل دوري.',
        'تابع نسبة التقدم حتى الإنجاز.',
      ],
      [
        'Create a goal with amount and target date.',
        'Add amounts to it regularly.',
        'Track progress until completion.',
      ],
    ),
    _StepRule(
      '/personal/budget',
      true,
      [
        'اختر الفترة والتصنيف وحدّ الصرف.',
        'سجّل مصروفاتك بشكل طبيعي.',
        'تنبّه عند الاقتراب من الحد أو تجاوزه.',
      ],
      [
        'Pick the period, the category and the cap.',
        'Record expenses normally.',
        'Get warned near or over the limit.',
      ],
    ),
    _StepRule(
      '/personal/debts',
      true,
      [
        'سجّل الدين: لك أو عليك مع المبلغ والطرف.',
        'حدد موعد السداد وفعّل التذكير.',
        'سجّل كل دفعة حتى إغلاق الدين.',
      ],
      [
        'Record the debt: owed to you or by you, with amount and party.',
        'Set the due date and enable reminders.',
        'Record every payment until closure.',
      ],
    ),
    _StepRule(
      '/personal/reports',
      true,
      [
        'اختر عملة التقرير والفترة — كل المبالغ تتحول إليها.',
        'افتح التقرير الذي تريده: الشامل، الدخل والمصروف، التصنيفات، الميزانيات، الأهداف، الديون أو البنوك.',
        'صدّر PDF أو شارك التقرير.',
      ],
      [
        'Choose the report currency and period — every amount converts to it.',
        'Open the report you need: full, income & spending, categories, budgets, goals, debts or banks.',
        'Export to PDF or share the report.',
      ],
    ),
    _StepRule(
      '/reports',
      true,
      [
        'اختر التقرير المطلوب من القائمة.',
        'حدد الفترة والفلاتر المناسبة.',
        'اعرض النتائج ثم صدّر أو اطبع.',
      ],
      [
        'Pick the report from the list.',
        'Set the period and filters.',
        'View results, then export or print.',
      ],
    ),
    _StepRule(
      '/customers',
      true,
      [
        'أضف بيانات العميل الأساسية.',
        'أنشئ فواتيره وسجّل دفعاته.',
        'تابع رصيده وكشف حسابه.',
      ],
      [
        'Add the customer basic data.',
        'Create invoices and record payments.',
        'Track the balance and statement.',
      ],
    ),
    _StepRule(
      '/sales',
      true,
      [
        'اختر العميل وأضف الأصناف والكميات.',
        'راجع الإجمالي والضريبة والخصم.',
        'اعتمد الفاتورة وسجّل القبض.',
      ],
      [
        'Pick the customer and add items and quantities.',
        'Review total, tax and discount.',
        'Approve the invoice and record receipt.',
      ],
    ),
    _StepRule(
      '/suppliers',
      true,
      [
        'أضف بيانات المورد الأساسية.',
        'سجّل مشترياتك وفواتيره.',
        'تابع المستحقات وكشف الحساب.',
      ],
      [
        'Add the supplier basic data.',
        'Record purchases and invoices.',
        'Track dues and the statement.',
      ],
    ),
    _StepRule(
      '/purchases',
      true,
      [
        'اختر المورد وأضف الأصناف.',
        'راجع الإجمالي وشروط الدفع.',
        'اعتمد الفاتورة وسجّل الدفع.',
      ],
      [
        'Pick the supplier and add items.',
        'Review the total and payment terms.',
        'Approve the invoice and record payment.',
      ],
    ),
    _StepRule(
      '/products',
      true,
      [
        'أضف الصنف باسمه وسعره ووحدته.',
        'حدد الباركود والتصنيف.',
        'احفظ ليظهر في الفواتير والمخزون.',
      ],
      [
        'Add the item with name, price and unit.',
        'Set barcode and category.',
        'Save so it appears in invoices and stock.',
      ],
    ),
    _StepRule(
      '/inventory',
      true,
      [
        'راجع الكميات المتاحة لكل صنف.',
        'سجّل حركات الإدخال والإخراج.',
        'نفّذ الجرد الدوري للمطابقة.',
      ],
      [
        'Review available quantities per item.',
        'Record stock in and out movements.',
        'Run periodic counts to reconcile.',
      ],
    ),
    _StepRule(
      '/expenses',
      true,
      [
        'اختر الحساب والتصنيف المناسب.',
        'أدخل المبلغ والعملة والوصف.',
        'احفظ وراجع المصروف في التقارير.',
      ],
      [
        'Pick the account and category.',
        'Enter amount, currency and description.',
        'Save and review it in reports.',
      ],
    ),
    _StepRule(
      '/payments',
      true,
      [
        'اختر المستند المراد سداده.',
        'أدخل مبلغ الدفعة وطريقتها.',
        'احفظ لتحديث الرصيد المتبقي.',
      ],
      [
        'Pick the document to pay.',
        'Enter the payment amount and method.',
        'Save to update the remaining balance.',
      ],
    ),
    _StepRule(
      '/cheques',
      true,
      [
        'سجّل بيانات الشيك وتاريخ الاستحقاق.',
        'حدد الحالة: وارد أو صادر.',
        'تابع التحصيل وحدّث الحالة.',
      ],
      [
        'Record cheque data and due date.',
        'Set status: incoming or outgoing.',
        'Track collection and update status.',
      ],
    ),
    _StepRule(
      '/employees',
      true,
      [
        'أضف بيانات الموظف الوظيفية.',
        'حدد القسم والراتب وتاريخ التعيين.',
        'تابع الحضور والإجازات والرواتب.',
      ],
      [
        'Add the employee job data.',
        'Set department, salary and hire date.',
        'Track attendance, leaves and payroll.',
      ],
    ),
    _StepRule(
      '/attendance',
      true,
      [
        'اختر التاريخ والموظف.',
        'سجّل الحضور أو الغياب أو التأخير.',
        'احفظ لينعكس في التقارير.',
      ],
      [
        'Pick the date and employee.',
        'Record present, absent or late.',
        'Save to reflect in reports.',
      ],
    ),
    _StepRule(
      '/leaves',
      true,
      [
        'اختر الموظف ونوع الإجازة.',
        'حدد الفترة وسبب الإجازة.',
        'اعتمد الطلب لخصم الرصيد.',
      ],
      [
        'Pick the employee and leave type.',
        'Set the period and reason.',
        'Approve to deduct the balance.',
      ],
    ),
    _StepRule(
      '/payroll',
      true,
      [
        'اختر الشهر والموظفين المشمولين.',
        'راجع الرواتب والبدلات والخصومات.',
        'اعتمد المسيّر وسجّل الصرف.',
      ],
      [
        'Pick the month and included staff.',
        'Review salaries, allowances and deductions.',
        'Approve the run and record payout.',
      ],
    ),
    _StepRule(
      '/contracts',
      true,
      [
        'أدخل بيانات العقد ومدته وقيمته.',
        'حدد تاريخ البدء والانتهاء.',
        'تابع العقود القريبة من الانتهاء.',
      ],
      [
        'Enter contract data, duration and value.',
        'Set start and end dates.',
        'Watch contracts nearing expiry.',
      ],
    ),
    _StepRule(
      '/journal',
      true,
      [
        'اختر الحساب المدين والحساب الدائن.',
        'أدخل مبالغ متوازنة للطرفين.',
        'اعتمد القيد ليثبت في الدفاتر.',
      ],
      [
        'Pick the debit and credit accounts.',
        'Enter balanced amounts for both sides.',
        'Approve the entry to post it.',
      ],
    ),
    _StepRule(
      '/accounts',
      true,
      [
        'استعرض دليل الحسابات حسب النوع.',
        'أضف حساباً جديداً عند الحاجة.',
        'استخدم الحسابات في القيود والتقارير.',
      ],
      [
        'Browse the chart of accounts by type.',
        'Add a new account when needed.',
        'Use accounts in entries and reports.',
      ],
    ),
    _StepRule(
      '/pos',
      true,
      [
        'أضف الأصناف إلى سلة البيع.',
        'اختر طريقة الدفع المناسبة.',
        'أتمم البيع واطبع الإيصال.',
      ],
      [
        'Add items to the sale basket.',
        'Choose the payment method.',
        'Complete the sale and print the receipt.',
      ],
    ),
    _StepRule(
      '/fiscal-years',
      true,
      [
        'أنشئ السنة المالية الجديدة.',
        'اعتمد الفترات المحاسبية.',
        'أغلق السنة بعد المراجعة.',
      ],
      [
        'Create the new fiscal year.',
        'Approve the accounting periods.',
        'Close the year after review.',
      ],
    ),
    _StepRule(
      '/settings',
      true,
      [
        'اختر الإعداد المطلوب من القائمة.',
        'عدّل القيم حسب احتياجك.',
        'احفظ لتُطبق التغييرات فوراً.',
      ],
      [
        'Pick the needed setting.',
        'Adjust values to your needs.',
        'Save to apply changes instantly.',
      ],
    ),
    _StepRule(
      '/profile',
      true,
      [
        'حدّث بياناتك الشخصية.',
        'بدّل المظهر واللغة والعملة.',
        'أدر تفضيلات معلومات النقرات.',
      ],
      [
        'Update your personal data.',
        'Switch theme, language and currency.',
        'Manage Information Clicker preferences.',
      ],
    ),
    _StepRule(
      '/notifications',
      true,
      [
        'استعرض أحدث التنبيهات أولاً.',
        'اضغط أي إشعار للانتقال لتفاصيله.',
        'امسح المقروء لتنظيم القائمة.',
      ],
      [
        'Browse the newest alerts first.',
        'Tap any notification to open its details.',
        'Clear read items to tidy the list.',
      ],
    ),
    _StepRule(
      '/subscription',
      true,
      [
        'قارن بين الباقات ومزاياها.',
        'اختر طريقة الدفع المناسبة.',
        'أكمل الدفع وابدأ رحلتك المالية.',
      ],
      [
        'Compare plans and their features.',
        'Choose a payment method.',
        'Complete payment and start.',
      ],
    ),
    _StepRule(
      '/personal/ai',
      true,
      [
        'اكتب سؤالك أو تحدث بصوتك.',
        'راجع إجابة سارة والتحليل.',
        'نفّذ الإجراء المقترح عند الحاجة.',
      ],
      [
        'Type your question or speak.',
        'Review Sara answer and analysis.',
        'Run the suggested action if needed.',
      ],
    ),
    _StepRule(
      '/personal/transfer',
      true,
      [
        'اختر الحساب المحوَّل منه وإليه.',
        'أدخل المبلغ وسيُحتسب الصرف تلقائياً.',
        'أكّد الحوالة وراجع الحركتين.',
      ],
      [
        'Pick source and destination accounts.',
        'Enter the amount; FX is auto calculated.',
        'Confirm and review both movements.',
      ],
    ),
    _StepRule(
      '/personal/backup',
      true,
      [
        'اختر إنشاء نسخة احتياطية الآن.',
        'انتظر اكتمال الحفظ بنجاح.',
        'استعد أي نسخة سابقة عند الحاجة.',
      ],
      [
        'Choose to create a backup now.',
        'Wait until saving completes.',
        'Restore any previous copy when needed.',
      ],
    ),
    _StepRule(
      '/personal/categories',
      true,
      [
        'استعرض تصنيفات الدخل والمصروف.',
        'أضف تصنيفاً جديداً عند الحاجة.',
        'اربط معاملاتك بالتصنيف الصحيح.',
      ],
      [
        'Browse income and expense categories.',
        'Add a new category when needed.',
        'Link transactions to the right category.',
      ],
    ),
    _StepRule(
      '/users',
      true,
      [
        'أضف المستخدم وحدد دوره.',
        'امنح الصلاحيات المناسبة فقط.',
        'راجع الجلسات النشطة دورياً.',
      ],
      [
        'Add the user and set a role.',
        'Grant only needed permissions.',
        'Review active sessions regularly.',
      ],
    ),
    _StepRule(
      '/projects',
      true,
      [
        'أنشئ المشروع وحدد أهدافه.',
        'أضف المهام والمواعيد.',
        'تابع نسبة التقدم أولاً بأول.',
      ],
      [
        'Create the project with its goals.',
        'Add tasks and deadlines.',
        'Track progress continuously.',
      ],
    ),
    _StepRule(
      'إضافة',
      false,
      [
        'املأ الحقول المطلوبة بدقة.',
        'راجع البيانات قبل الحفظ.',
        'احفظ ليظهر العنصر في القائمة.',
      ],
      [
        'Fill the required fields carefully.',
        'Review the data before saving.',
        'Save so the item appears in the list.',
      ],
    ),
    _StepRule(
      'تعديل',
      false,
      [
        'عدّل الحقول المطلوبة فقط.',
        'راجع التغييرات الجديدة.',
        'احفظ التعديل ليعتمد.',
      ],
      [
        'Edit only the needed fields.',
        'Review the new changes.',
        'Save the edit to apply it.',
      ],
    ),
    _StepRule(
      'حذف',
      false,
      [
        'اختر العنصر المراد حذفه.',
        'أكّد الحذف من النافذة.',
        'لاحظ: لا يمكن التراجع بعد الحذف.',
      ],
      [
        'Pick the item to delete.',
        'Confirm deletion in the dialog.',
        'Note: deletion cannot be undone.',
      ],
    ),
    _StepRule(
      'حفظ',
      false,
      [
        'املأ جميع الحقول المطلوبة.',
        'راجع البيانات المدخلة.',
        'اضغط حفظ لاعتماد التغييرات.',
      ],
      [
        'Fill all required fields.',
        'Review the entered data.',
        'Tap save to commit the changes.',
      ],
    ),
    _StepRule(
      'بحث',
      false,
      [
        'اكتب كلمة أو رقم البحث.',
        'راجع النتائج الظاهرة.',
        'اضغط النتيجة لعرض تفاصيلها.',
      ],
      [
        'Type the search word or number.',
        'Review the shown results.',
        'Tap a result to view details.',
      ],
    ),
    _StepRule(
      'تصدير',
      false,
      [
        'حدد البيانات المطلوب تصديرها.',
        'اختر صيغة الملف المناسبة.',
        'احفظ الملف أو شاركه.',
      ],
      [
        'Select the data to export.',
        'Choose the right file format.',
        'Save or share the file.',
      ],
    ),
    _StepRule(
      'طباعة',
      false,
      [
        'راجع معاينة المستند أولاً.',
        'اختر الطابعة أو الحفظ PDF.',
        'أتمم الطباعة من النافذة.',
      ],
      [
        'Preview the document first.',
        'Pick a printer or save as PDF.',
        'Finish printing from the dialog.',
      ],
    ),
    _StepRule(
      'مشاركة',
      false,
      [
        'اختر التطبيق المستلم للمشاركة.',
        'راجع المحتوى المرسل.',
        'أرسل وأكّد وصوله.',
      ],
      [
        'Pick the receiving app.',
        'Review the sent content.',
        'Send and confirm delivery.',
      ],
    ),
    _StepRule(
      'دفع',
      false,
      [
        'حدد المستند والمبلغ المراد سداده.',
        'اختر طريقة الدفع المناسبة.',
        'احفظ لتحديث الرصيد المتبقي.',
      ],
      [
        'Pick the document and amount to pay.',
        'Choose the payment method.',
        'Save to update the remaining balance.',
      ],
    ),
    _StepRule(
      'اشتراك',
      false,
      [
        'قارن الباقات المتاحة.',
        'اختر الباقة وطريقة الدفع.',
        'أكمل الدفع لتفعيل الاشتراك.',
      ],
      [
        'Compare the available plans.',
        'Pick a plan and payment method.',
        'Complete payment to activate.',
      ],
    ),
    _StepRule(
      'سحب',
      false,
      [
        'اختر الحساب (البنك أو المحفظة).',
        'أدخل المبلغ والعملة.',
        'اختر التصنيف ثم أضف وصفاً للمصروف.',
      ],
      [
        'Pick the account (bank or wallet).',
        'Enter the amount and currency.',
        'Pick a category, then add a description.',
      ],
    ),
    _StepRule(
      'إيداع',
      false,
      [
        'اختر الحساب المستلم للمبلغ.',
        'أدخل المبلغ والعملة.',
        'اختر التصنيف ثم احفظ الإيداع.',
      ],
      [
        'Pick the receiving account.',
        'Enter the amount and currency.',
        'Pick a category, then save the deposit.',
      ],
    ),
    _StepRule(
      'تحويل',
      false,
      [
        'اختر الحساب المحوَّل منه وإليه.',
        'أدخل المبلغ وسيُحتسب الصرف تلقائياً.',
        'أكّد الحوالة وراجع الحركتين.',
      ],
      [
        'Pick source and destination accounts.',
        'Enter the amount; FX is auto calculated.',
        'Confirm and review both movements.',
      ],
    ),
    _StepRule(
      'دخل',
      false,
      [
        'اختر الحساب الذي سيستلم المبلغ.',
        'أدخل المبلغ والعملة والتصنيف.',
        'احفظ ليُضاف الدخل إلى رصيدك.',
      ],
      [
        'Pick the account receiving the amount.',
        'Enter amount, currency and category.',
        'Save to add the income to your balance.',
      ],
    ),
    _StepRule(
      'هدف',
      false,
      [
        'أنشئ الهدف بالمبلغ والتاريخ المستهدف.',
        'أضف مبالغ إليه بشكل دوري.',
        'تابع نسبة التقدم حتى الإنجاز.',
      ],
      [
        'Create the goal with amount and target date.',
        'Add amounts to it regularly.',
        'Track progress until completion.',
      ],
    ),
    _StepRule(
      'دين',
      false,
      [
        'سجّل الدين: لك أو عليك مع المبلغ والطرف.',
        'حدد موعد السداد وفعّل التذكير.',
        'سجّل كل دفعة حتى إغلاق الدين.',
      ],
      [
        'Record the debt with amount and party.',
        'Set the due date and enable reminders.',
        'Record every payment until closure.',
      ],
    ),
    _StepRule(
      'ميزانية',
      false,
      [
        'اختر الفترة والتصنيف وحدّ الصرف.',
        'سجّل مصروفاتك بشكل طبيعي.',
        'تنبّه عند الاقتراب من الحد أو تجاوزه.',
      ],
      [
        'Pick the period, the category and the cap.',
        'Record expenses normally.',
        'Get warned near or over the limit.',
      ],
    ),
    _StepRule(
      'تقرير',
      false,
      [
        'اختر نوع التقرير والفترة الزمنية.',
        'راجع النتائج والرسوم البيانية.',
        'صدّر PDF أو شارك التقرير.',
      ],
      [
        'Choose the report type and period.',
        'Review results and charts.',
        'Export to PDF or share the report.',
      ],
    ),
    _StepRule(
      'سداد',
      false,
      [
        'اكتب مبلغ السداد واختر الحساب اللي بتدفع منه.',
        'تأكد إن رصيد الحساب يكفي المبلغ.',
        'اضغط تأكيد السداد وتسجّل الدفعة على الدين.',
      ],
      [
        'Enter the payment amount and the account you pay from.',
        'Make sure the account balance covers it.',
        'Confirm and the payment lands on the debt.',
      ],
    ),
    _StepRule(
      'تحصيل',
      false,
      [
        'اكتب المبلغ اللي استلمته واختر الحساب اللي دخله.',
        'اضغط تأكيد التحصيل وتزيد فلوسك وينقص المتبقي.',
      ],
      [
        'Enter what you received and the account it went into.',
        'Confirm and your money grows while less is owed.',
      ],
    ),
    _StepRule(
      'مساهمة',
      false,
      [
        'اكتب مبلغ المساهمة واختر المصدر (كاش أو بنك).',
        'أكّد والهدف يتقدم فوراً.',
      ],
      [
        'Enter the contribution and pick the source (cash or bank).',
        'Confirm and the goal jumps forward immediately.',
      ],
    ),
    _StepRule(
      'إضافة مبلغ',
      false,
      [
        'اكتب المبلغ واختر الحساب أو المصدر.',
        'أكّد ويتحدث الرصيد أو التقدم فوراً.',
      ],
      [
        'Enter the amount and pick the account or source.',
        'Confirm and the balance or progress updates immediately.',
      ],
    ),
    _StepRule(
      'إضافة بنك',
      false,
      [
        'اكتب اسم البنك واختر عملته.',
        'حط الرصيد الافتتاحي لو فيه.',
        'احفظ وتطلع لك بطاقته في الرئيسية.',
      ],
      [
        'Name the bank and pick its currency.',
        'Set an opening balance if there is one.',
        'Save and its card appears on home.',
      ],
    ),
    _StepRule(
      'إنشاء ميزانية',
      false,
      [
        'سمّ الميزانية واختر فترتها.',
        'وزع السقوف على التصنيفات.',
        'احفظ وتابع الصرف والتنبيهات.',
      ],
      [
        'Name the budget and pick its period.',
        'Split caps across categories.',
        'Save and track spending and alerts.',
      ],
    ),
    _StepRule(
      'نسخة احتياطية',
      false,
      [
        'أنشئ نسخة جديدة مرقمة أو حدّث آخر نسخة.',
        'للاستعادة اختر النسخة من الإدارة وأكّد.',
      ],
      [
        'Create a new numbered copy or refresh the latest one.',
        'To restore, pick the copy from manage and confirm.',
      ],
    ),
    _StepRule(
      'شترك',
      false,
      [
        'قارن الباقات واختر اللي تناسبك.',
        'اشترك سنوي أو جرّب المجانية.',
        'كمّل الدفع وتنفتح لك المزايا.',
      ],
      [
        'Compare plans and pick what suits you.',
        'Subscribe yearly or try free.',
        'Complete payment to unlock features.',
      ],
    ),
    _StepRule(
      'تنفيذ',
      false,
      [
        'اضغط تنفيذ الآن على العملية.',
        'يتأكد النظام إن رصيدك يكفي.',
        'تتنفذ فوراً وتنزل في المعاملات.',
      ],
      [
        'Tap execute now on the operation.',
        'The app checks your balance covers it.',
        'It runs immediately and lands in transactions.',
      ],
    ),
    _StepRule(
      'مصارفة',
      false,
      [
        'اختر الحساب اللي بيطلع منه المبلغ والحساب اللي بيستلمه.',
        'اكتب المبلغ وبيتحوّل لعملة الاستقبال تلقائياً.',
        'أكّد وتتحرك الفلوس بين الحسابين بنفس اللحظة.',
      ],
      [
        'Pick the sending and the receiving account.',
        'Enter the amount; it converts to the receiving currency.',
        'Confirm and the money moves instantly.',
      ],
    ),
    _StepRule(
      'exchange',
      false,
      [
        'اختر الحساب اللي بيطلع منه المبلغ والحساب اللي بيستلمه.',
        'اكتب المبلغ وبيتحوّل لعملة الاستقبال تلقائياً.',
        'أكّد وتتحرك الفلوس بين الحسابين بنفس اللحظة.',
      ],
      [
        'Pick the sending and the receiving account.',
        'Enter the amount; it converts to the receiving currency.',
        'Confirm and the money moves instantly.',
      ],
    ),
  ];

  static const List<_IconRule> _routeIcons = [
    _IconRule('/personal/recurring', Icons.autorenew_rounded),
    _IconRule('/personal/banks', Icons.account_balance_rounded),
    _IconRule('/banks', Icons.account_balance_rounded),
    _IconRule('/personal/transactions', Icons.swap_horiz_rounded),
    _IconRule('/personal/savings', Icons.savings_rounded),
    _IconRule('/personal/budget', Icons.pie_chart_rounded),
    _IconRule('/personal/debts', Icons.handshake_outlined),
    _IconRule('/personal/reports', Icons.bar_chart_rounded),
    _IconRule('/reports', Icons.assessment_rounded),
    _IconRule('/customers', Icons.people_rounded),
    _IconRule('/sales', Icons.shopping_cart_rounded),
    _IconRule('/suppliers', Icons.store_rounded),
    _IconRule('/purchases', Icons.shopping_bag_rounded),
    _IconRule('/products', Icons.inventory_2_rounded),
    _IconRule('/inventory', Icons.inventory_rounded),
    _IconRule('/expenses', Icons.receipt_long_rounded),
    _IconRule('/payments', Icons.payments_rounded),
    _IconRule('/cheques', Icons.description_outlined),
    _IconRule('/employees', Icons.badge_rounded),
    _IconRule('/attendance', Icons.fingerprint_rounded),
    _IconRule('/leaves', Icons.event_available_rounded),
    _IconRule('/payroll', Icons.account_balance_wallet_rounded),
    _IconRule('/contracts', Icons.assignment_rounded),
    _IconRule('/journal', Icons.book_rounded),
    _IconRule('/accounts', Icons.list_alt_rounded),
    _IconRule('/ledger', Icons.menu_book_rounded),
    _IconRule('/pos', Icons.point_of_sale_rounded),
    _IconRule('/settings', Icons.settings_rounded),
    _IconRule('/profile', Icons.person_rounded),
    _IconRule('/notifications', Icons.notifications_rounded),
    _IconRule('/reminders', Icons.alarm_rounded),
    _IconRule('/subscription', Icons.card_membership_rounded),
    _IconRule('/personal/ai', Icons.smart_toy_outlined),
    _IconRule('/ai', Icons.smart_toy_outlined),
    _IconRule('/personal/transfer', Icons.swap_horiz_rounded),
    _IconRule('/personal/backup', Icons.backup_rounded),
    _IconRule('/personal/categories', Icons.category_rounded),
    _IconRule('/users', Icons.group_rounded),
    _IconRule('/projects', Icons.folder_rounded),
    _IconRule('/personal/financial-tree', Icons.account_tree_rounded),
    _IconRule('/personal/account-tree', Icons.account_tree_rounded),
    _IconRule('/personal/executive', Icons.insights_rounded),
    _IconRule('/personal/finance-overview', Icons.dashboard_rounded),
    _IconRule('/personal/all-banks-report', Icons.assessment_rounded),
    _IconRule('/personal/bank-statement', Icons.receipt_rounded),
    _IconRule('/email', Icons.mail_outline_rounded),
    _IconRule('/design-studio', Icons.palette_rounded),
    _IconRule('/import', Icons.upload_rounded),
    _IconRule('/fiscal-years', Icons.calendar_month_rounded),
    _IconRule('/fixed-assets', Icons.business_rounded),
    _IconRule('/suggestions', Icons.lightbulb_outline_rounded),
    _IconRule('/personal/receipt-design', Icons.design_services_rounded),
  ];

  static const List<_IconRule> _labelIcons = [
    _IconRule('حفظ', Icons.save_rounded),
    _IconRule('save', Icons.save_rounded),
    _IconRule('إضافة', Icons.add_rounded),
    _IconRule('add', Icons.add_rounded),
    _IconRule('جديد', Icons.add_rounded),
    _IconRule('new', Icons.add_rounded),
    _IconRule('تعديل', Icons.edit_rounded),
    _IconRule('edit', Icons.edit_rounded),
    _IconRule('حذف', Icons.delete_outline_rounded),
    _IconRule('delete', Icons.delete_outline_rounded),
    _IconRule('بحث', Icons.search_rounded),
    _IconRule('search', Icons.search_rounded),
    _IconRule('طباعة', Icons.print_rounded),
    _IconRule('print', Icons.print_rounded),
    _IconRule('مشاركة', Icons.share_rounded),
    _IconRule('share', Icons.share_rounded),
    _IconRule('تحويل', Icons.swap_horiz_rounded),
    _IconRule('transfer', Icons.swap_horiz_rounded),
    _IconRule('مصارفة', Icons.swap_horiz_rounded),
    _IconRule('exchange', Icons.swap_horiz_rounded),
    _IconRule('سحب', Icons.arrow_upward_rounded),
    _IconRule('withdraw', Icons.arrow_upward_rounded),
    _IconRule('إيداع', Icons.arrow_downward_rounded),
    _IconRule('deposit', Icons.arrow_downward_rounded),
    _IconRule('دخل', Icons.trending_up_rounded),
    _IconRule('income', Icons.trending_up_rounded),
    _IconRule('مصروف', Icons.trending_down_rounded),
    _IconRule('expense', Icons.trending_down_rounded),
    _IconRule('دين', Icons.handshake_outlined),
    _IconRule('debt', Icons.handshake_outlined),
    _IconRule('هدف', Icons.track_changes_rounded),
    _IconRule('goal', Icons.track_changes_rounded),
    _IconRule('راتب', Icons.payments_rounded),
    _IconRule('salary', Icons.payments_rounded),
    _IconRule('حضور', Icons.fingerprint_rounded),
    _IconRule('غياب', Icons.person_off_rounded),
    _IconRule('إجازة', Icons.event_available_rounded),
    _IconRule('leave', Icons.event_available_rounded),
    _IconRule('فاتورة', Icons.receipt_rounded),
    _IconRule('invoice', Icons.receipt_rounded),
    _IconRule('شيك', Icons.description_outlined),
    _IconRule('cheque', Icons.description_outlined),
    _IconRule('عميل', Icons.person_rounded),
    _IconRule('customer', Icons.person_rounded),
    _IconRule('مورد', Icons.store_rounded),
    _IconRule('supplier', Icons.store_rounded),
    _IconRule('منتج', Icons.inventory_2_rounded),
    _IconRule('product', Icons.inventory_2_rounded),
    _IconRule('بنك', Icons.account_balance_rounded),
    _IconRule('bank', Icons.account_balance_rounded),
    _IconRule('تقرير', Icons.bar_chart_rounded),
    _IconRule('report', Icons.bar_chart_rounded),
    _IconRule('إشعار', Icons.notifications_rounded),
    _IconRule('notification', Icons.notifications_rounded),
    _IconRule('تذكير', Icons.alarm_rounded),
    _IconRule('reminder', Icons.alarm_rounded),
    _IconRule('صورة', Icons.image_rounded),
    _IconRule('image', Icons.image_rounded),
    _IconRule('كاميرا', Icons.photo_camera_rounded),
    _IconRule('camera', Icons.photo_camera_rounded),
    _IconRule('تنزيل', Icons.download_rounded),
    _IconRule('download', Icons.download_rounded),
    _IconRule('تصدير', Icons.upload_rounded),
    _IconRule('export', Icons.upload_rounded),
    _IconRule('عملة', Icons.currency_exchange_rounded),
    _IconRule('currency', Icons.currency_exchange_rounded),
    _IconRule('لغة', Icons.language_rounded),
    _IconRule('language', Icons.language_rounded),
    _IconRule('مظهر', Icons.dark_mode_rounded),
    _IconRule('theme', Icons.dark_mode_rounded),
    _IconRule('هاتف', Icons.phone_rounded),
    _IconRule('phone', Icons.phone_rounded),
    _IconRule('بريد', Icons.mail_outline_rounded),
    _IconRule('email', Icons.mail_outline_rounded),
    _IconRule('واتساب', Icons.chat_bubble_rounded),
    _IconRule('whatsapp', Icons.chat_bubble_rounded),
    _IconRule('خروج', Icons.logout_rounded),
    _IconRule('logout', Icons.logout_rounded),
    _IconRule('دخول', Icons.login_rounded),
    _IconRule('login', Icons.login_rounded),
    _IconRule('اشتراك', Icons.card_membership_rounded),
    _IconRule('subscription', Icons.card_membership_rounded),
    _IconRule('سارة', Icons.smart_toy_outlined),
    _IconRule('sara', Icons.smart_toy_outlined),
    _IconRule('تقويم', Icons.calendar_today_rounded),
    _IconRule('تاريخ', Icons.calendar_today_rounded),
    _IconRule('وقت', Icons.schedule_rounded),
    _IconRule('مزامنة', Icons.sync_rounded),
    _IconRule('sync', Icons.sync_rounded),
    _IconRule('تحديث', Icons.refresh_rounded),
    _IconRule('refresh', Icons.refresh_rounded),
  ];
}
