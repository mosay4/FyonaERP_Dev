import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../shared/widgets/two_tone_icons.dart';
import '../../../../shared/widgets/sara_chat_page.dart';
import '../../../employees/presentation/providers/employee_providers.dart';
import '../../../branches/data/branch_scope.dart';

class AiAssistantPage extends ConsumerWidget {
  const AiAssistantPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ar = Localizations.localeOf(context).languageCode == 'ar';
    if (!ref.watch(employeeCanProvider('ai'))) {
      return Center(child: Text(ar ? 'سارة متاحة لمالك المشروع فقط.' : 'Sara is available to the project owner only.'));
    }
    return SaraChatPage(
      prefixWelcomeWithName: false,
      enableFilePicker: true,
      inputHint: ar ? 'اسأل عن الفرع أو اطلب تنفيذ عملية...' : 'Ask about this branch or request an operation…',
      suggestedQuestions: ar ? const ['كيف وضع شغلي؟', 'كم أرصدة البنوك؟', 'إيش المنتجات القريبة من النفاد؟', 'اعرض ديون العملاء والموردين']
          : const ['How is my business?', 'Show bank balances', 'Which products are running low?', 'Show customer and supplier debts'],
      key: ValueKey('sara_${BranchScope.organizationId}_${BranchScope.allMode}_${BranchScope.branchId}'),
      welcomeMessage: !ar ? (BranchScope.readOnly ? 'I’m Sara. Compare and understand your branches here. This view is read-only.' : 'I’m Sara. Ask about this branch or request an operation to review and confirm.') : BranchScope.readOnly
          ? 'أنا سارة، أساعدك تقارن وتفهم بيانات فروعك. أنت في وضع القراءة فقط.'
          : 'أنا سارة، أساعدك في شغل هذا الفرع. اسألني عن بياناته أو اطلب عملية وسأعرض تفاصيلها للتأكيد.',
      icon: TwoToneIcons.ai,
      accountType: 'business',
    );
  }
}
