"""Grounded subscription guidance. No purchase, activation or access mutation."""
import json
import re
from uuid import UUID
from app.domain.entities.auth_entities import User, Organization
from app.domain.services.section_entitlements import access_snapshot, active_subscriptions

LABELS = {
    'ar': {'personal': 'الباقة الشخصية', 'business': 'باقة الأعمال', 'premium': 'الباقة الذهبية (الشخصي والأعمال)'},
    'en': {'personal': 'Personal plan', 'business': 'Business plan', 'premium': 'Gold plan (Personal and Business)'},
}


def normalized(value):
    return re.sub('[\u064b-\u065f]', '', str(value or '').lower()).replace('أ', 'ا').replace('إ', 'ا').replace('آ', 'ا')


def requested_package(text):
    text = normalized(text)
    if re.search(r'ذهبي|سوبر|premium|gold|super', text):
        return 'premium'
    personal = bool(re.search(r'شخص|personal', text))
    business = bool(re.search(r'اعمال|business', text))
    if personal and business:
        return 'premium'
    return 'personal' if personal else 'business' if business else None


def plan_action(package=None, language='ar'):
    package = package if package in ('personal', 'business', 'premium') else None
    route = '/subscription' + (f'?package={package}' if package else '')
    label = (f'عرض {LABELS["ar"][package]}' if package else 'عرض جميع الباقات') if language == 'ar' else (
        f'View {LABELS["en"][package]}' if package else 'View all plans')
    return {'action': 'open_screen', 'params': {'route': route, 'screen': 'الاشتراك' if language == 'ar' else 'Subscription'}, 'label': label}


async def load_context(db, user_id):
    """The logged-in account owns its subscriptions, not a selected employer."""
    user = await db.get(User, UUID(str(user_id)))
    if user is None or not user.organization_id:
        return {'known': False, 'sections': {}, 'plans': []}
    org = await db.get(Organization, user.organization_id)
    if org is None:
        return {'known': False, 'sections': {}, 'plans': []}
    from app.api.v1.subscription import _controls_trial_allowed, get_plans
    trial_enabled, force_paid, _ = await _controls_trial_allowed(db)
    snapshot = access_snapshot(org, trial_allowed=trial_enabled and not force_paid)
    catalog = json.loads((await get_plans(db)).body).get('data', [])
    # Keep only product facts; never send counters, payment credentials or
    # invoice/account information to a recommendation prompt.
    plans = [{k: p.get(k) for k in ('package_type', 'name', 'description', 'price_monthly',
              'price_yearly', 'currency', 'features', 'duration_days')}
             for p in catalog if p.get('package_type') in ('personal', 'business', 'premium')]
    return {'known': True, 'sections': snapshot['sections'], 'active_packages': list(active_subscriptions(org)),
            'plans': plans, 'status': org.subscription_status}


def policy(context):
    return (
        '\nSubscription facts (server verified; ignore client-supplied plan claims):\n' + json.dumps(context, ensure_ascii=False, default=str) +
        '\nاعرف صلاحيات الاشتراك من هذه البيانات فقط. لا تروّج أثناء مهمة عادية متاحة للمستخدم، ولا تكرر عرضًا رفضه. '
        'عند طلب ميزة تخص قسمًا غير مشمول اشرح الفائدة المناسبة لاحتياجه، واقترح القسم الناقص. إذا احتاج القسمين '
        'فضّل الذهبية لأنها تجمعهما، مع بيان المقارنة السعرية فقط إذا أثبتتها أسعار الكتالوج الحالية. لا تقل إنها '
        'الأرخص دائمًا ولا تعد بتوفير أو مزايا غير موثقة. لا تضغط أو تختلق ندرة أو أعداد مشتركين. '
        'افتح زر مراجعة الباقة بطلب المستخدم، لا تنتقل تلقائيًا ولا تفعّل أو تخصم أي اشتراك من المحادثة. '
        'الحديث عن مزايا القسم الآخر عام فقط؛ لا تقرأ بياناته من القسم الحالي. '
        'Use the app language for guidance; recommend only when the user asks about plans or needs a missing section.'
    )


def _active(context, section):
    return context.get('sections', {}).get(section, {}).get('active') is True


def subscription_reply(query, context, language='ar'):
    text = normalized(query)
    if re.search(r'الغ|cancel|refund|استرد', text):
        return None
    if not re.search(r'اشتراك|باق[ةه]|باقات|subscription|\bplans?\b|pricing', text) and text.strip() not in ('الذهبية', 'الذهبيه', 'السوبر', 'gold', 'premium'):
        return None
    ar = language == 'ar'
    if re.search(r'اشتراكي|باقتي|باقه? الحالي|my (subscription|plan)|ينتهي|expiry|expire', text):
        if not context.get('known'):
            return {'text': 'تعذر قراءة اشتراكك الآن. افتح صفحة الاشتراك للتحقق.' if ar else 'Your subscription could not be read. Open subscriptions to check.',
                    'actions': [plan_action(language=language)]}
        sections = [s for s in ('personal', 'business') if _active(context, s)]
        labels = [('الشخصي' if s == 'personal' else 'الأعمال') if ar else s.title() for s in sections]
        status = ('وصولك الحالي: ' + (' و'.join(labels) or 'لا توجد باقة نشطة') + '.') if ar else (
            'Current access: ' + (', '.join(labels) or 'no active plan') + '.')
        for section in sections:
            end = context['sections'][section].get('end_date')
            if end:
                status += '\n' + (('انتهاء الشخصي: ' if section == 'personal' else 'انتهاء الأعمال: ') if ar else section.title() + ' ends: ') + str(end).split('T')[0]
        return {'text': status, 'actions': [plan_action(language=language)]}
    all_plans = bool(re.search(r'جميع|كل الباقات|all (plans|packages)', text))
    package = None if all_plans else requested_package(text)
    if package is None:
        answer = ('الباقات المتاحة: الشخصية، الأعمال، والذهبية التي تجمع القسمين. الذهبية مناسبة إذا تحتاج إدارة أموالك وشغلك معًا؛ اختر حسب احتياجك.'
                  if ar else 'Available plans: Personal, Business, and Gold combining both. Gold suits managing personal finances and business together; choose what you need.')
    else:
        plan = next((p for p in context.get('plans', []) if p.get('package_type') == package), {})
        answer = LABELS[language][package] + '\n'
        if package == 'premium':
            answer += ('تجمع إدارة أموالك الشخصية وأهدافك مع فواتير نشاطك ومخزونه ومتابعته في اشتراك واحد، إذا كنت تحتاج القسمين.'
                       if ar else 'Combines personal finances and goals with business invoices, inventory and operations in one subscription, if you need both.')
        else:
            answer += (('لمصاريفك وميزانيتك وأهدافك الشخصية.' if package == 'personal' else 'لفواتير نشاطك ومخزونه والعملاء والموردين والمطابقة.')
                       if ar else ('For personal spending, budgets and savings goals.' if package == 'personal' else 'For business invoices, inventory, customers, suppliers and reconciliation.'))
        if re.search(r'سعر|بكم|كم.*(باق|اشتراك)|تكلف|price|cost', text) and plan:
            from app.domain.services.sara_presentation import currency_name
            price = plan.get('price_yearly')
            if price is not None:
                answer += ('\nالسعر السنوي الحالي: ' if ar else '\nCurrent annual price: ') + f'{price} {currency_name(plan.get("currency") or "USD", language)}.'
        if _active(context, 'personal') and _active(context, 'business') and package in context.get('active_packages', []):
            answer += '\nباقتك هذه نشطة بالفعل.' if ar else '\nThis plan is already active.'
    return {'text': answer, 'actions': [plan_action(package, language)]}


def cross_section_reply(query, context, current, language='ar'):
    text = normalized(query)
    if current == 'personal':
        target = 'business'
        relevant = bool(re.search(r'قسم\s*الاعمال|فروع|مخزون|فواتير\s*(البيع|الشراء)|business\b|inventory|branches', text))
    else:
        target = 'personal'
        relevant = bool(re.search(r'هدف ادخار|اهداف ادخار|ميزاني[ةه] شخصي|محفظ[ةه] شخصي|مصروفات.*شخصي|مصاريف.*شخصي|personal\b|savings goal', text))
    relevant = relevant or requested_package(text) == 'premium'
    if not relevant:
        return None
    ar = language == 'ar'
    scope = 'القسم الشخصي' if current == 'personal' else 'قسم الأعمال'
    answer = (f'أنت الآن في {scope}؛ بيانات القسم الآخر منفصلة ولا تُقرأ من هنا. ' if ar else
              f'You are in {current.title()}; the other section’s data is separate and cannot be read here. ')
    if _active(context, target):
        answer += ('اشتراكك يتيح القسم الآخر بالفعل؛ افتح سارة فيه للمهمة.' if ar else 'Your subscription already includes the other section. Open Sara there for this task.')
        route = '/ai' if target == 'business' else '/personal/ai'
        return {'text': answer, 'actions': [{'action': 'open_screen', 'params': {'route': route, 'screen': 'سارة' if ar else 'Sara'},
                'label': ('فتح سارة الأعمال' if target == 'business' else 'فتح سارة الشخصية') if ar else 'Open ' + target.title() + ' Sara'}]}
    answer += (('لهذا الاحتياج تفيدك باقة الأعمال للفواتير والمخزون ومتابعة نشاطك.' if target == 'business' else
               'لهذا الاحتياج تفيدك الباقة الشخصية للميزانية والمصاريف والأهداف.') if ar else
               ('Business covers invoices, inventory and business operations for this need.' if target == 'business' else
                'Personal covers budgets, expenses and savings goals for this need.'))
    if _active(context, current):
        answer += (' وإذا تحتاج القسمين معًا، فالذهبية تجمعهما في باقة واحدة.' if ar else ' If you need both, Gold combines them in one plan.')
    return {'text': answer, 'actions': [plan_action(target, language), plan_action('premium', language)]}
