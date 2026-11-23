/// Network/DNS failures on the way to Stripe (the phone has LAN but no
/// real internet, airplane mode, VPN/ad-block DNS, …). Returns a clear
/// message, or null when the text is not a connectivity problem.
String? stripeNetworkMessage(String? message, {bool arabic = true}) {
  final m = (message ?? '').toLowerCase();
  if (m.isEmpty) return null;
  const markers = [
    'unable to resolve host',
    'no address associated with hostname',
    'failed host lookup',
    'network is unreachable',
    'software caused connection abort',
  ];
  final hit = markers.any(m.contains);
  if (!hit) return null;
  if (arabic) {
    return 'تعذر الوصول إلى خدمة الدفع. تحقق من اتصال الإنترنت في جهازك '
        '(وليس الشبكة المحلية فقط) ثم حاول مجددًا. إذا استمرت المشكلة '
        'جرّب بيانات الهاتف أو عطّل الـVPN.';
  }
  return 'Could not reach the payment service. Check your device internet '
      'connection (not just the local network) and try again. If it persists, '
      'try mobile data or disable VPN.';
}
/// Localized card-decline messages (Arabic/English) keyed by Stripe's
/// machine-readable codes — never by the English free text.
///
/// `declineCode` (e.g. `insufficient_funds`) wins over `stripeErrorCode`
/// (e.g. `card_declined`). Returns null when nothing matches so callers
/// keep Stripe's own message as the fallback.
String? stripeDeclineMessage({
  String? declineCode,
  String? stripeErrorCode,
  bool arabic = true,
}) {
  final d = (declineCode ?? '').trim().toLowerCase();
  final s = (stripeErrorCode ?? '').trim().toLowerCase();
  String? pick(String ar, String en) => arabic ? ar : en;

  switch (d) {
    case 'insufficient_funds':
      return pick(
        'رصيد البطاقة غير كافٍ لإتمام الدفع. يرجى التحقق من الرصيد المتاح أو استخدام بطاقة أخرى.',
        'Your card has insufficient funds. Please check the available balance or use another card.',
      );
    case 'expired_card':
      return pick(
        'البطاقة منتهية الصلاحية. يرجى استخدام بطاقة سارية.',
        'Your card has expired. Please use a valid card.',
      );
    case 'incorrect_cvc':
    case 'invalid_cvc':
      return pick(
        'رمز الأمان (CVC) غير صحيح. تحقق منه وحاول مجددًا.',
        'The security code (CVC) is incorrect. Please check it and try again.',
      );
    case 'incorrect_number':
    case 'invalid_number':
      return pick(
        'رقم البطاقة غير صحيح. تحقق منه وحاول مجددًا.',
        'The card number is incorrect. Please check it and try again.',
      );
    case 'incorrect_expiry':
    case 'invalid_expiry_month':
    case 'invalid_expiry_year':
      return pick(
        'تاريخ انتهاء البطاقة غير صحيح.',
        'The card expiry date is incorrect.',
      );
    case 'authentication_required':
      return pick(
        'يلزم توثيق إضافي من البنك لإتمام العملية. أكمل خطوة التحقق.',
        'Additional bank authentication is required to complete. Please finish verification.',
      );
    case 'approve_with_id':
    case 'issuer_not_available':
    case 'processing_error':
    case 'try_again_later':
      return pick(
        'تعذر إتمام الدفع مؤقتًا. حاول مجددًا بعد قليل.',
        'The payment could not be completed right now. Please try again shortly.',
      );
    case 'lost_card':
    case 'stolen_card':
    case 'pickup_card':
    case 'restricted_card':
    case 'security_violation':
      return pick(
        'تم رفض البطاقة من البنك. يرجى استخدام بطاقة أخرى.',
        'Your card was declined by the bank. Please use another card.',
      );
    case 'do_not_honor':
    case 'generic_decline':
      return pick(
        'تم رفض العملية من البنك دون توضيح السبب. تحقق من البطاقة أو الرصيد وحاول مجددًا.',
        'The bank declined the transaction. Please check your card or balance and try again.',
      );
    case '':
      break;
    default:
      return pick(
        'تم رفض البطاقة. تحقق من بياناتها أو الرصيد وحاول مجددًا.',
        'Your card was declined. Please check its details or balance and try again.',
      );
  }
  switch (s) {
    case 'card_declined':
      return pick(
        'تم رفض البطاقة من البنك. تحقق من البطاقة أو الرصيد وحاول مجددًا.',
        'Your card was declined by the bank. Please check your card or balance and try again.',
      );
    case 'expired_card':
      return pick(
        'البطاقة منتهية الصلاحية. يرجى استخدام بطاقة سارية.',
        'Your card has expired. Please use a valid card.',
      );
    case 'incorrect_cvc':
      return pick(
        'رمز الأمان (CVC) غير صحيح. تحقق منه وحاول مجددًا.',
        'The security code (CVC) is incorrect. Please check it and try again.',
      );
    case 'incorrect_number':
      return pick(
        'رقم البطاقة غير صحيح. تحقق منه وحاول مجددًا.',
        'The card number is incorrect. Please check it and try again.',
      );
    case 'authentication_required':
      return pick(
        'يلزم توثيق إضافي من البنك لإتمام العملية. أكمل خطوة التحقق.',
        'Additional bank authentication is required to complete. Please finish verification.',
      );
    case 'processing_error':
      return pick(
        'تعذر إتمام الدفع مؤقتًا. حاول مجددًا بعد قليل.',
        'The payment could not be completed right now. Please try again shortly.',
      );
    case 'invalid_request_error':
      return null;
  }
  return null;
}
