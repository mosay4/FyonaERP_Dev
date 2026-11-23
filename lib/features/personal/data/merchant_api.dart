import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http_parser/http_parser.dart';
import '../../../../core/di/providers.dart' show apiClientProvider;
import '../../../../core/network/api_client.dart';

final merchantApiProvider = Provider<MerchantApi>((ref) {
  return MerchantApi(ref.watch(apiClientProvider));
});

/// Merchant ↔ Personal accounts API («حساباتي مع التجار»).
class MerchantApi {
  final ApiClient _client;
  MerchantApi(this._client);

  ApiClient get client => _client;

  dynamic _data(response) {
    final d = response.data;
    if (d is Map && d['data'] != null) return d['data'];
    return d;
  }

  Future<List<Map<String, dynamic>>> _list(Future response) async {
    final r = await response;
    final d = _data(r);
    return (d as List? ?? [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  // ── personal ──
  Future<String> myCode() async {
    final r = await _client.get('/me/code');
    return '${(_data(r) as Map?)?['code'] ?? ''}';
  }

  Future<List<Map<String, dynamic>>> myMerchants() =>
      _list(_client.get('/me/merchant-links'));

  Future<List<Map<String, dynamic>>> myInvites() =>
      _list(_client.get('/me/merchant-invites'));

  Future<void> acceptInvite(String linkId) =>
      _client.post('/me/merchant-invites/$linkId/accept');

  Future<void> rejectInvite(String linkId) =>
      _client.post('/me/merchant-invites/$linkId/reject');

  /// Personal side: revoke the binding with this merchant (debts untouched).
  Future<void> unlinkMerchant(String linkId) =>
      _client.post('/me/merchant-links/$linkId/unlink');

  Future<Map<String, dynamic>> partnerDebts(String linkId) async {
    final r = await _client.get('/me/merchant-links/$linkId/debts');
    return Map<String, dynamic>.from(_data(r) as Map? ?? {});
  }

  Future<List<Map<String, dynamic>>> partnerInvoices(String linkId) =>
      _list(_client.get('/me/merchant-links/$linkId/invoices'));

  Future<List<Map<String, dynamic>>> mySettlementRequests(String linkId) =>
      _list(_client.get('/me/merchant-links/$linkId/settlement-requests'));

  Future<Map<String, dynamic>> requestSettlement({
    required String linkId,
    required double amount,
    required String currency,
    String? method,
    String? reference,
    String? receiptUrl,
    String? note,
    required String idempotencyKey,
  }) async {
    final r = await _client.post(
      '/me/merchant-links/settlement-requests',
      data: {
        'link_id': linkId,
        'amount': amount,
        'currency': currency,
        if (method != null) 'method': method,
        if (reference != null) 'reference': reference,
        if (receiptUrl != null) 'receipt_url': receiptUrl,
        if (note != null) 'note': note,
        'idempotency_key': idempotencyKey,
      },
    );
    return Map<String, dynamic>.from(_data(r) as Map? ?? {});
  }

  // ── business ──
  Future<Map<String, dynamic>> lookup({
    String? phone,
    String? code,
    String? country,
  }) async {
    final r = await _client.post(
      '/merchant-links/lookup',
      data: {
        if (phone != null && phone.isNotEmpty) 'phone': phone,
        if (code != null && code.isNotEmpty) 'code': code,
        if (phone != null && phone.isNotEmpty && country != null)
          'country': country,
      },
    );
    return Map<String, dynamic>.from(_data(r) as Map? ?? {});
  }

  Future<Map<String, dynamic>> invite({
    required String partyKind,
    required String partyId,
    String? phone,
    String? code,
    String? country,
  }) async {
    final r = await _client.post(
      '/merchant-links/invite',
      data: {
        'party_kind': partyKind,
        'party_id': partyId,
        if (phone != null && phone.isNotEmpty) 'phone': phone,
        if (code != null && code.isNotEmpty) 'code': code,
        if (phone != null && phone.isNotEmpty && country != null)
          'country': country,
      },
    );
    return Map<String, dynamic>.from(_data(r) as Map? ?? {});
  }

  Future<Map<String, dynamic>> linkStatus({
    required String partyKind,
    required String partyId,
  }) async {
    final r = await _client.get(
      '/merchant-links/status',
      queryParameters: {'party_kind': partyKind, 'party_id': partyId},
    );
    return Map<String, dynamic>.from(_data(r) as Map? ?? {});
  }

  /// Business side: create the opening «رصيد افتتاحي» debt of a new party.
  Future<Map<String, dynamic>> createOpeningDebt({
    required String partyKind,
    required String partyId,
    required double amount,
    required String currency,
  }) async {
    final r = await _client.post(
      '/merchant-links/party/opening-debt',
      data: {
        'party_kind': partyKind,
        'party_id': partyId,
        'amount': amount,
        'currency': currency,
      },
    );
    return Map<String, dynamic>.from(_data(r) as Map? ?? {});
  }

  /// Business side: delete a party. Linked → unlink + notify; otherwise the
  /// party and its debts are removed (backup taken server-side).
  Future<Map<String, dynamic>> deleteParty({
    required String partyKind,
    required String partyId,
  }) async {
    final r = await _client.post(
      '/merchant-links/party/delete',
      data: {'party_kind': partyKind, 'party_id': partyId},
    );
    return Map<String, dynamic>.from(_data(r) as Map? ?? {});
  }

  Future<List<Map<String, dynamic>>> settlementRequests({
    required String partyKind,
    required String partyId,
  }) => _list(
    _client.get(
      '/merchant-links/settlement-requests',
      queryParameters: {'party_kind': partyKind, 'party_id': partyId},
    ),
  );

  Future<void> decideSettlement({
    required String requestId,
    required bool approve,
    String? bankAccountId,
    String? reason,
  }) => _client.post(
    '/merchant-links/settlement-requests/$requestId/decide',
    data: {
      'approve': approve,
      if (bankAccountId != null) 'bank_account_id': bankAccountId,
      if (reason != null) 'reason': reason,
    },
  );

  Future<Map<String, dynamic>> debtOverview(
    String linkId, {
    String? currency,
    String? groupId,
    String? dateFrom,
    String? dateTo,
  }) async {
    final r = await _client.get(
      '/me/merchant-links/$linkId/debt-overview',
      queryParameters: {
        if (currency != null) 'currency': currency,
        if (groupId != null && groupId.isNotEmpty) 'group_id': groupId,
        if (dateFrom != null) 'date_from': dateFrom,
        if (dateTo != null) 'date_to': dateTo,
      },
    );
    return Map<String, dynamic>.from(_data(r) as Map? ?? {});
  }

  /// Persist the merchant's customized A4 design so linked parties see it.
  Future<void> saveInvoiceDesign(
    String templateId,
    Map<String, dynamic> payload,
  ) => _client.put('/invoices/designs/$templateId', data: {'payload': payload});

  Future<Map<String, dynamic>> businessOperationDetail({
    required String partyKind,
    required String partyId,
    required String invoiceId,
  }) async {
    final r = await _client.get(
      '/merchant-links/operation',
      queryParameters: {
        'party_kind': partyKind,
        'party_id': partyId,
        'invoice_id': invoiceId,
      },
    );
    return Map<String, dynamic>.from(_data(r) as Map? ?? {});
  }

  Future<Map<String, dynamic>> businessAdjustInvoice({
    required String partyKind,
    required String partyId,
    required String invoiceId,
    required List<Map<String, dynamic>> items,
  }) async {
    final r = await _client.patch(
      '/merchant-links/operation/$invoiceId',
      data: {'party_kind': partyKind, 'party_id': partyId, 'items': items},
    );
    return Map<String, dynamic>.from(_data(r) as Map? ?? {});
  }

  Future<void> businessDeleteInvoice({
    required String partyKind,
    required String partyId,
    required String invoiceId,
  }) => _client.delete(
    '/merchant-links/operation/$invoiceId',
    queryParameters: {'party_kind': partyKind, 'party_id': partyId},
  );

  Future<Map<String, dynamic>> operationDetail(
    String linkId,
    String invoiceId,
  ) async {
    final r = await _client.get(
      '/me/merchant-links/$linkId/operations/$invoiceId',
    );
    return Map<String, dynamic>.from(_data(r) as Map? ?? {});
  }

  Future<Map<String, dynamic>> debtNotifications({
    String? linkId,
    String? side,
  }) async {
    final r = await _client.get(
      '/debt-notifications',
      queryParameters: {
        if (linkId != null) 'link_id': linkId,
        if (side != null) 'side': side,
      },
    );
    return Map<String, dynamic>.from(_data(r) as Map? ?? {});
  }

  Future<int> unreadNotifications({String? side}) async {
    final r = await _client.get(
      '/debt-notifications/unread',
      queryParameters: {if (side != null) 'side': side},
    );
    final d = _data(r);
    if (d is Map) {
      return (d['unread'] as num?)?.toInt() ?? 0;
    }
    return 0;
  }

  /// Unread chat messages per link (red dot on the chat icon).
  Future<Map<String, int>> chatUnreadByLink({String? side}) async {
    final r = await _client.get(
      '/debt-notifications/chat-unread',
      queryParameters: {if (side != null) 'side': side},
    );
    final d = _data(r);
    final out = <String, int>{};
    if (d is Map) {
      final byLink = d['by_link'];
      if (byLink is Map) {
        byLink.forEach((k, v) {
          final n = v is num ? v.toInt() : int.tryParse('$v') ?? 0;
          if (n > 0) out['$k'] = n;
        });
      }
    }
    return out;
  }

  Future<void> markDebtNotificationsRead({List<String>? ids}) async {
    await _client.post(
      '/debt-notifications/read',
      data: {if (ids != null && ids.isNotEmpty) 'ids': ids},
    );
  }

  Future<List<Map<String, dynamic>>> debtGroups({
    required String partyKind,
    required String partyId,
  }) => _list(
    _client.get(
      '/merchant-links/debt-groups',
      queryParameters: {'party_kind': partyKind, 'party_id': partyId},
    ),
  );

  Future<Map<String, dynamic>> createDebtGroup({
    required String partyKind,
    required String partyId,
    required String name,
    String kind = 'manual',
    String? period,
  }) async {
    final r = await _client.post(
      '/merchant-links/debt-groups',
      data: {
        'party_kind': partyKind,
        'party_id': partyId,
        'name': name,
        'kind': kind,
        if (period != null) 'period': period,
      },
    );
    return Map<String, dynamic>.from(_data(r) as Map? ?? {});
  }

  // ── business party overview + group administration ──
  Future<Map<String, dynamic>> businessOverview({
    required String partyKind,
    required String partyId,
    String? currency,
    String? groupId,
    String? dateFrom,
    String? dateTo,
  }) async {
    final r = await _client.get(
      '/merchant-links/overview',
      queryParameters: {
        'party_kind': partyKind,
        'party_id': partyId,
        if (currency != null) 'currency': currency,
        if (groupId != null && groupId.isNotEmpty) 'group_id': groupId,
        if (dateFrom != null) 'date_from': dateFrom,
        if (dateTo != null) 'date_to': dateTo,
      },
    );
    return Map<String, dynamic>.from(_data(r) as Map? ?? {});
  }

  Future<void> renameDebtGroup({
    required String groupId,
    required String name,
  }) =>
      _client.put('/merchant-links/debt-groups/$groupId', data: {'name': name});

  Future<void> deleteDebtGroup({required String groupId}) =>
      _client.delete('/merchant-links/debt-groups/$groupId');

  Future<void> assignOperationGroup({
    required String invoiceId,
    required String partyKind,
    required String partyId,
    String? groupId,
  }) => _client.put(
    '/merchant-links/operations/$invoiceId/group',
    data: {
      'party_kind': partyKind,
      'party_id': partyId,
      if (groupId != null) 'group_id': groupId,
    },
  );

  // ── chat (isolated per MerchantLink) ──
  Future<void> touchPresence() => _client.post('/chat/presence');

  Future<void> chatPresence(
    String linkId, {
    bool active = true,
    String? side,
  }) => _client.post(
    '/chat/presence',
    data: {
      'conversation_id': linkId,
      'active': active,
      if (side != null) 'side': side,
    },
  );

  Future<Map<String, dynamic>> chatInfo(String linkId, {String? side}) async {
    final r = await _client.get(
      '/chat/$linkId',
      queryParameters: {if (side != null) 'side': side},
    );
    return Map<String, dynamic>.from(_data(r) as Map? ?? {});
  }

  Future<List<Map<String, dynamic>>> chatMessages(
    String linkId, {
    String? after,
    String? before,
    String? around,
    String? side,
    int limit = 40,
    bool waitForChanges = false,
    CancelToken? cancelToken,
  }) async {
    final r = await _client.get(
      '/chat/$linkId/${waitForChanges ? 'updates' : 'messages'}',
      queryParameters: {
        if (after != null) 'after': after,
        if (before != null) 'before': before,
        if (around != null) 'around': around,
        'limit': limit,
        if (side != null) 'side': side,
      },
      cancelToken: cancelToken,
      options: waitForChanges
          ? Options(receiveTimeout: const Duration(seconds: 25))
          : null,
    );
    final d = _data(r);
    if (waitForChanges) realtimeAvailable = d is! Map || d['realtime'] != false;
    // The endpoint returns {messages: [...]}, not a bare list.
    final raw = (d is Map) ? d['messages'] : d;
    return (raw as List? ?? [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  bool realtimeAvailable = true;

  Future<Map<String, dynamic>> sendChat(
    String linkId, {
    required String kind,
    String? side,
    String? text,
    String? mediaPath,
    String? fileName,
    String? invoiceId,
    String? replyToId,
    int? durationMs,
    List<Map<String, dynamic>>? media,
    String? clientId,
  }) async {
    final r = await _client.post(
      '/chat/$linkId/messages',
      data: {
        'kind': kind,
        if (side != null) 'side': side,
        if (text != null) 'text': text,
        if (mediaPath != null) 'media_path': mediaPath,
        if (fileName != null) 'file_name': fileName,
        if (replyToId != null) 'reply_to_id': replyToId,
        if (durationMs != null) 'duration_ms': durationMs,
        if (media != null) 'media': media,
        if (invoiceId != null) 'invoice_id': invoiceId,
        if (clientId != null) 'client_id': clientId,
        if (clientId != null) 'client_message_id': clientId,
        if (clientId != null) 'idempotency_key': clientId,
      },
    );
    final result = Map<String, dynamic>.from(_data(r) as Map? ?? {});
    // Bind the response to THIS request even when an older server omits the
    // echo. History can then reconcile by server id without losing the key.
    if (clientId != null && result['message'] is Map) {
      result['message'] = {
        ...Map<String, dynamic>.from(result['message']),
        'client_id': clientId,
        'client_message_id': clientId,
      };
    }
    return result;
  }

  Future<void> markChatRead(String linkId) =>
      _client.post('/chat/$linkId/read');

  Future<void> editChat(String linkId, String messageId, String text) =>
      _client.patch('/chat/$linkId/messages/$messageId', data: {'text': text});

  Future<void> deleteChat(String linkId, String messageId) =>
      _client.delete('/chat/$linkId/messages/$messageId');

  Future<List<Map<String, dynamic>>> chatInvoices(String linkId, {String? q}) =>
      _list(
        _client.get(
          '/chat/$linkId/invoices',
          queryParameters: {if (q != null && q.isNotEmpty) 'q': q},
        ),
      );

  Future<Map<String, String>> uploadChatMedia(
    String linkId,
    List<int> bytes,
    String filename,
    String mime, {
    String? path,
    void Function(int sent, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final part = (path != null && path.isNotEmpty)
        ? await MultipartFile.fromFile(
            path,
            filename: filename,
            contentType: MediaType.parse(mime),
          )
        : MultipartFile.fromBytes(
            bytes,
            filename: filename,
            contentType: MediaType.parse(mime),
          );
    final r = await _client.dio.post(
      '/chat/$linkId/media',
      data: FormData.fromMap({'file': part}),
      onSendProgress: onProgress,
      cancelToken: cancelToken,
      // Large videos can take minutes; the global 30s send timeout used to
      // abort uploads part-way. Give media its own generous budget.
      options: Options(
        sendTimeout: const Duration(minutes: 60),
        receiveTimeout: const Duration(minutes: 10),
      ),
    );
    final data = _data(r) as Map? ?? const {};
    return {
      'url': '${data['url'] ?? ''}',
      'thumbnail': '${data['thumbnail'] ?? ''}',
    };
  }
}
