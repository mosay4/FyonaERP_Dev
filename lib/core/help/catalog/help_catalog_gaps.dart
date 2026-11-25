import 'package:flutter/material.dart';

import '../../../shared/widgets/two_tone_icons.dart';
import 'help_entry.dart';

/// Elements found by the coverage audit after the section catalogs were
/// written (notification preference switches; that page is currently not linked
/// from any route, the entries are global so they work wherever it opens).
const List<HelpEntry> kHelpGaps = [
  HelpEntry(
    id: 'g.notif.email',
    keys: ['notificationsEmailAlerts'],
    icon: Icons.mark_email_unread_rounded,
    ar: 'شغّله لو تبي توصلك التنبيهات على إيميلك كمان.',
    en: 'Turn on to also get alerts by email.',
  ),
  HelpEntry(
    id: 'g.notif.payments',
    keys: ['notificationsPaymentAlerts'],
    icon: Icons.payments_rounded,
    ar: 'ينبّهك كل ما انسجل دفع أو استلمت فلوس.',
    en: 'Alerts you whenever a payment is made or received.',
  ),
  HelpEntry(
    id: 'g.notif.system',
    keys: ['notificationsSystemUpdates'],
    icon: Icons.system_update_rounded,
    ar: 'يعلمك بالمزايا الجديدة والتحديثات في التطبيق.',
    en: 'Tells you about new features and app updates.',
  ),
  HelpEntry(
    id: 'g.notif.budget',
    keys: ['notificationsBudgetAlerts'],
    icon: Icons.savings_rounded,
    ar: 'ينبّهك لما تقرب توصل حد الصرف اللي حطيته.',
    en: 'Warns you when you get close to a spending limit you set.',
  ),
  HelpEntry(
    id: 'g.notif.lowBalance',
    keys: ['notificationsLowBalanceAlert'],
    icon: Icons.account_balance_wallet_rounded,
    ar: 'ينبّهك لما رصيد حساب ينزل تحت الحد.',
    en: 'Warns you when an account balance drops too low.',
  ),
  HelpEntry(
    id: 'g.notif.daily',
    keys: ['notificationsDailyReport'],
    icon: Icons.today_rounded,
    ar: 'يوصلك كل يوم ملخص سريع لفلوسك.',
    en: 'Sends you a quick money summary every day.',
  ),
  HelpEntry(
    id: 'g.notif.weekly',
    keys: ['weeklyReport'],
    icon: Icons.date_range_rounded,
    ar: 'يوصلك كل أسبوع ملخص لفلوسك.',
    en: 'Sends you a money summary every week.',
  ),
  HelpEntry(
    id: 'g.emp.paySubmit',
    texts: [
      'صرف راتب',
      'تحصيل من الموظف',
      'سداد للموظف',
      'دين على الموظف',
      'دين للموظف',
    ],
    scopes: ['/employees'],
    icon: Icons.task_alt_rounded,
    ar: 'يحفظ العملية للموظف بالمبلغ والعملة اللي اخترتها.',
    en: 'Saves this employee operation with the amount and currency you chose.',
  ),
  HelpEntry(
    id: 'g.profile.bizCurrencies',
    texts: [
      'تخصيص عملات هذا الفرع',
      'Customize this branch currencies',
      'تخصيص عملات قسم الأعمال',
      'Customize business currencies',
    ],
    icon: Icons.currency_exchange_rounded,
    ar: 'تختار العملات اللي تبيها تظهر في حساباتك التجارية.',
    en: 'Choose which currencies show up in your business accounts.',
  ),
  HelpEntry(
    id: 'g.currency.closeSearch',
    icons: [TwoToneIcons.arrowUp],
    icon: Icons.keyboard_arrow_up_rounded,
    arTitle: 'إغلاق القائمة',
    enTitle: 'Close list',
    ar: 'يقفل قائمة العملات ويرجعك للنموذج.',
    en: 'Closes the currency list and takes you back to the form.',
  ),
];
