import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../../shared/widgets/two_tone_icons.dart';
import '../../../../shared/widgets/sara_chat_page.dart';
import '../../../../core/localization/app_localizations.dart';
import '../providers/personal_providers.dart';
import '../../../auth/presentation/providers/auth_provider.dart';

class PersonalAiPage extends ConsumerStatefulWidget {
  const PersonalAiPage({super.key});
  @override
  ConsumerState<PersonalAiPage> createState() => _PersonalAiPageState();
}

class _PersonalAiPageState extends ConsumerState<PersonalAiPage> {
  StreamSubscription? _sub;

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      ref.read(personalFinanceProvider.notifier).load();
      ref.read(budgetProvider.notifier).load();
      ref.read(recurringProvider.notifier).load();
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final fin = ref.watch(personalFinanceProvider);
    final budget = ref.watch(budgetProvider);
    final rec = ref.watch(recurringProvider);

    final balance = fin.totalBalance;
    final txCount = fin.transactions.length;
    final budgetCount = budget.budgets.length;
    final recCount = rec.recurring.length;
    final fullName = ref.watch(authProvider).user?.fullName?.trim() ?? '';
    final firstName = fullName.isEmpty ? '' : fullName.split(RegExp(r'\s+')).first;

    return SaraChatPage(
      prefixWelcomeWithName: false,
      welcomeMessage: l10n.locale.languageCode == 'ar'
          ? 'أهلًا $firstName، أنا سارة. اسألني عن حسابك الشخصي أو اطلب عملية وسأساعدك.'
          : 'Hi $firstName, I’m Sara. Ask about your personal finances or request an operation.',
      suggestedQuestions: [
        if (balance > 0) l10n.translate('personalAiQBalance'),
        if (txCount > 0) l10n.translate('personalAiQSpendingAnalysis'),
        if (budgetCount > 0) l10n.translate('personalAiQBudgetPerformance'),
        if (recCount > 0) l10n.translate('personalAiQUpcomingRecurring'),
        l10n.translate('personalAiQWhereGoes'),
        l10n.translate('personalAiQSaveMore'),
      ],
      icon: TwoToneIcons.wallet,
      inputHint: l10n.translate('personalAiInputHint'),
      enableFilePicker: true,
    );
  }
}
