import '../../../personal/data/merchant_api.dart';
import '../../../personal/data/models/financial_tree_models.dart';
import '../../../personal/data/models/personal_models.dart';
import '../../../personal/data/repositories/financial_tree_storage.dart';
import '../../../personal/domain/services/personal_finance_service.dart';
import 'verification_gateway.dart';

/// Sara's Personal tools for the screens that are not gateway-mirrored
/// entities: spending categories (device mirror, no outbox), the financial
/// tree (device storage) and merchant links (server API). Each write does
/// exactly what the screen's button does (same storage, same rules), then
/// re-reads what it wrote; only a confirmed re-read reports success.
///
/// The chat resolves everything by NAME (the model cannot see device ids);
/// an unknown or ambiguous name is answered with the available choices.
class SaraPersonalExtraTools {
  SaraPersonalExtraTools(
    this._service,
    this._verify, {
    FinancialTreeStorage? treeStorage,
    this.merchantApi,
    this.onTreesChanged,
  }) : _trees = treeStorage ?? FinancialTreeStorage();

  final PersonalFinanceService _service;
  final SaraVerificationGateway _verify;
  final FinancialTreeStorage _trees;
  final MerchantApi? merchantApi;

  /// Lets the open tree screen reload after Sara changed the storage (its
  /// notifier keeps the nodes in memory and would overwrite them).
  final Future<void> Function()? onTreesChanged;

  static const categoriesRoute = '/personal/categories';
  static const treeRoute = '/personal/financial-tree';
  static const merchantsRoute = '/personal/merchant-accounts';

  static const categoryTools = {'add_category', 'update_category', 'delete_category'};
  static const treeTools = {
    'create_financial_tree', 'update_financial_tree', 'delete_financial_tree',
    'add_tree_node', 'update_tree_node', 'delete_tree_node',
  };
  static const merchantTools = {'accept_merchant_invite', 'reject_merchant_invite', 'unlink_merchant'};
  static final all = {...categoryTools, ...treeTools, ...merchantTools};

  /// Screen whose buttons do [tool] (maintenance gate + reply button).
  static String? routeOf(String tool) {
    if (categoryTools.contains(tool)) return categoriesRoute;
    if (treeTools.contains(tool)) return treeRoute;
    if (merchantTools.contains(tool)) return merchantsRoute;
    return null;
  }

  /// Node types a user can pick (the root is the tree itself).
  static final nodeTypes = [
    for (final t in FinancialTreeNodeType.values)
      if (t != FinancialTreeNodeType.root) t.id,
  ];

  Future<SaraVerificationResult> run(String tool, Map<String, dynamic> p) {
    return _verify.executeOnce(
      opKey: SaraVerificationGateway.opKeyFor(tool, p),
      run: () async {
        switch (tool) {
          case 'add_category': return _addCategory(p);
          case 'update_category': return _updateCategory(p);
          case 'delete_category': return _deleteCategory(p);
          case 'create_financial_tree': return _createTree(p);
          case 'update_financial_tree': return _updateTree(p);
          case 'delete_financial_tree': return _deleteTree(p);
          case 'add_tree_node': return _addNode(p);
          case 'update_tree_node': return _updateNode(p);
          case 'delete_tree_node': return _deleteNode(p);
          case 'accept_merchant_invite': return _respondInvite(p, accept: true);
          case 'reject_merchant_invite': return _respondInvite(p, accept: false);
          case 'unlink_merchant': return _unlink(p);
        }
        return _fail(tool, 'أداة غير معروفة: $tool', 'Unknown tool: $tool', 'UNKNOWN_TOOL');
      },
    );
  }

  // ── shared ──

  static String _s(dynamic v) => v == null ? '' : '$v'.trim();
  static String _key(String s) => s.trim().toLowerCase();

  static double? _num(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    const digits = {'٠': '0', '١': '1', '٢': '2', '٣': '3', '٤': '4', '٥': '5', '٦': '6', '٧': '7', '٨': '8', '٩': '9'};
    var s = '$v';
    digits.forEach((k, d) => s = s.replaceAll(k, d));
    return double.tryParse(s.replaceAll(RegExp(r'[,\s٬]'), ''));
  }

  SaraVerificationResult _fail(String tool, String ar, String en, String code,
          {SaraVerificationState state = SaraVerificationState.failed, Map<String, dynamic>? data}) =>
      SaraVerificationResult(
          state: state, tool: tool, route: routeOf(tool),
          messageAr: ar, messageEn: en, errorCode: code, data: data);

  SaraVerificationResult _ok(String tool, String ar, String en, {String? id, Map<String, dynamic>? data}) =>
      SaraVerificationResult(
          state: SaraVerificationState.successConfirmed, tool: tool, entityId: id,
          route: routeOf(tool), serverConfirmed: merchantTools.contains(tool),
          syncState: merchantTools.contains(tool) ? 'synced' : 'local',
          messageAr: ar, messageEn: en, data: data);

  SaraVerificationResult _unverified(String tool) => _fail(tool,
      'لم أتمكن من التأكد من حفظ العملية — تحقق من الشاشة.',
      'The change could not be verified — check the screen.', 'VERIFY_FAILED',
      state: SaraVerificationState.verificationFailed);

  /// Exact (case-insensitive) match first, then a unique partial match.
  /// Returns (match, candidates) — candidates when none/ambiguous.
  static (T?, List<T>) _pick<T>(List<T> items, String name, Iterable<String> Function(T) names) {
    final k = _key(name);
    if (k.isEmpty) return (null, items);
    final exact = items.where((i) => names(i).any((n) => _key(n) == k)).toList();
    if (exact.length == 1) return (exact.first, const []);
    if (exact.length > 1) return (null, exact);
    final partial = items.where((i) => names(i).any((n) => _key(n).isNotEmpty && (_key(n).contains(k) || k.contains(_key(n))))).toList();
    if (partial.length == 1) return (partial.first, const []);
    return (null, partial.isEmpty ? items : partial);
  }

  // ── categories (the categories screen: both names required) ──

  Future<SaraVerificationResult> _resolveCategory(String tool, String name,
      Future<SaraVerificationResult> Function(SpendingCategory c) then) async {
    final cats = await _service.getLocalCategories();
    final (c, options) = _pick(cats, name, (c) => [c.name, c.nameAr]);
    if (c == null) {
      final list = options.map((c) => c.nameAr).join('، ');
      return _fail(tool,
          name.isEmpty ? 'أي تصنيف تقصد؟ ${list.isEmpty ? 'لا توجد تصنيفات.' : 'التصنيفات: $list'}'
              : 'لا يوجد تصنيف «$name».${list.isEmpty ? '' : ' التصنيفات: $list'}',
          name.isEmpty ? 'Which category? ${options.map((c) => c.name).join(', ')}'
              : 'No category "$name". Categories: ${options.map((c) => c.name).join(', ')}',
          'NOT_FOUND', state: SaraVerificationState.notFound,
          data: {'categories': options.map((c) => c.nameAr).toList()});
    }
    return then(c);
  }

  Future<SaraVerificationResult> _addCategory(Map<String, dynamic> p) async {
    const tool = 'add_category';
    final ar = _s(p['name_ar']);
    final en = _s(p['name_en']);
    try {
      final saved = await _service.addCategory(SpendingCategory(id: '', name: en, nameAr: ar));
      final back = (await _service.getLocalCategories()).where((c) => c.id == saved.id);
      if (back.isEmpty) return _unverified(tool);
      return _ok(tool, 'تمت إضافة التصنيف «$ar» ($en)', 'Added category "$en" ($ar)', id: saved.id);
    } on CategoryException catch (e) {
      return _fail(tool, e.messageAr, e.messageEn, e.code);
    }
  }

  Future<SaraVerificationResult> _updateCategory(Map<String, dynamic> p) async {
    const tool = 'update_category';
    return _resolveCategory(tool, _s(p['category_name']), (c) async {
      final ar = _s(p['new_name_ar']).isEmpty ? c.nameAr : _s(p['new_name_ar']);
      final en = _s(p['new_name_en']).isEmpty ? c.name : _s(p['new_name_en']);
      if (ar == c.nameAr && en == c.name) {
        return _fail(tool, 'ما الاسم الجديد للتصنيف «${c.nameAr}»؟', 'What is the new name of "${c.name}"?', 'MISSING_NAME');
      }
      try {
        final saved = await _service.updateCategory(
            SpendingCategory(id: c.id, name: en, nameAr: ar, icon: c.icon, color: c.color, sortOrder: c.sortOrder, isActive: c.isActive));
        final back = (await _service.getLocalCategories()).where((x) => x.id == saved.id && x.nameAr == ar && x.name == en);
        if (back.isEmpty) return _unverified(tool);
        return _ok(tool, 'تم تعديل التصنيف إلى «$ar» ($en)', 'Category renamed to "$en" ($ar)', id: saved.id);
      } on CategoryException catch (e) {
        return _fail(tool, e.messageAr, e.messageEn, e.code);
      }
    });
  }

  Future<SaraVerificationResult> _deleteCategory(Map<String, dynamic> p) async {
    const tool = 'delete_category';
    return _resolveCategory(tool, _s(p['category_name']), (c) async {
      try {
        await _service.deleteCategory(c.id);
      } on CategoryException catch (e) {
        return _fail(tool, e.messageAr, e.messageEn, e.code);
      }
      final still = (await _service.getLocalCategories()).any((x) => x.id == c.id);
      if (still) return _unverified(tool);
      return _ok(tool, 'تم حذف التصنيف «${c.nameAr}»', 'Deleted category "${c.name}"', id: c.id);
    });
  }

  // ── financial tree (the tree screens: name required, root not removable) ──

  Future<void> _treesChanged() async {
    try {
      await onTreesChanged?.call();
    } catch (_) {}
  }

  /// [name] empty + exactly one tree = that tree (the user has one).
  Future<(FinancialTree?, SaraVerificationResult?)> _resolveTree(String tool, String name, {bool allowSole = true}) async {
    final trees = await _trees.loadTrees();
    if (trees.isEmpty) {
      return (null, _fail(tool, 'لا توجد شجرة مالية بعد — أنشئ واحدة أولاً.',
          'There is no financial tree yet — create one first.', 'NOT_FOUND', state: SaraVerificationState.notFound));
    }
    if (name.isEmpty && allowSole && trees.length == 1) return (trees.first, null);
    final (t, options) = _pick(trees, name, (t) => [t.name]);
    if (t != null) return (t, null);
    final list = options.map((t) => t.name).join('، ');
    return (null, _fail(tool,
        name.isEmpty ? 'أي شجرة تقصد؟ الأشجار: $list' : 'لا توجد شجرة «$name». الأشجار: $list',
        name.isEmpty ? 'Which tree? Trees: $list' : 'No tree "$name". Trees: $list',
        name.isEmpty ? 'NEEDS_TREE' : 'NOT_FOUND',
        state: name.isEmpty ? SaraVerificationState.failed : SaraVerificationState.notFound,
        data: {'trees': options.map((t) => t.name).toList()}));
  }

  (FinancialTreeNode?, SaraVerificationResult?) _resolveNode(String tool, List<FinancialTreeNode> nodes, String name) {
    final (n, options) = _pick(nodes, name, (n) => [n.name]);
    if (n != null) return (n, null);
    final list = options.map((n) => n.name).join('، ');
    return (null, _fail(tool,
        name.isEmpty ? 'أي بند تقصد؟ البنود: $list' : 'لا يوجد بند «$name». البنود: $list',
        name.isEmpty ? 'Which item? Items: $list' : 'No item "$name". Items: $list',
        name.isEmpty ? 'NEEDS_NODE' : 'NOT_FOUND',
        state: name.isEmpty ? SaraVerificationState.failed : SaraVerificationState.notFound,
        data: {'nodes': options.map((n) => n.name).toList()}));
  }

  SaraVerificationResult? _badType(String tool, String type) {
    if (type.isEmpty || nodeTypes.contains(type)) return null;
    return _fail(tool, 'نوع البند غير صالح: $type (${nodeTypes.join('، ')})',
        'Invalid item type: $type (${nodeTypes.join(', ')})', 'INVALID_TYPE');
  }

  SaraVerificationResult? _badAmount(String tool, dynamic raw) {
    if (raw == null || '$raw'.trim().isEmpty) return null;
    final v = _num(raw);
    if (v != null && v >= 0) return null;
    return _fail(tool, 'المبلغ غير صالح', 'Invalid amount', 'INVALID_AMOUNT');
  }

  Future<SaraVerificationResult> _createTree(Map<String, dynamic> p) async {
    const tool = 'create_financial_tree';
    final name = _s(p['name']);
    if (name.isEmpty) return _fail(tool, 'ما اسم الشجرة؟', 'What is the tree name?', 'MISSING_NAME');
    final bad = _badAmount(tool, p['base_amount']);
    if (bad != null) return bad;
    final now = DateTime.now();
    final treeId = newNodeId();
    final rootId = newNodeId();
    final amount = _num(p['base_amount']) ?? 0;
    final currency = _s(p['currency']).isEmpty ? 'SAR' : _s(p['currency']).toUpperCase();
    final notes = _s(p['notes']);
    final tree = FinancialTree(
      id: treeId, name: name, clientName: _s(p['client_name']), baseAmount: amount,
      currency: currency, notes: notes, rootNodeId: rootId, createdAt: now, updatedAt: now);
    final root = FinancialTreeNode(
      id: rootId, treeId: treeId, parentId: null, name: name, type: FinancialTreeNodeType.root,
      amount: amount, currency: currency, notes: notes, createdAt: now, updatedAt: now);
    await _trees.saveNodes(tree, [root]);
    final back = (await _trees.loadTrees()).any((t) => t.id == treeId) &&
        (await _trees.loadNodes(treeId)).any((n) => n.id == rootId);
    if (!back) return _unverified(tool);
    await _treesChanged();
    return _ok(tool, 'تم إنشاء الشجرة «$name»', 'Created tree "$name"', id: treeId);
  }

  Future<SaraVerificationResult> _updateTree(Map<String, dynamic> p) async {
    const tool = 'update_financial_tree';
    final (tree, err) = await _resolveTree(tool, _s(p['tree_name']));
    if (tree == null) return err!;
    final bad = _badAmount(tool, p['base_amount']);
    if (bad != null) return bad;
    final newName = _s(p['new_name']).isEmpty ? tree.name : _s(p['new_name']);
    final updated = tree.copyWith(
      name: newName,
      clientName: p.containsKey('client_name') ? _s(p['client_name']) : null,
      baseAmount: _num(p['base_amount']),
      currency: _s(p['currency']).isEmpty ? null : _s(p['currency']).toUpperCase(),
      notes: p.containsKey('notes') ? _s(p['notes']) : null,
      updatedAt: DateTime.now(),
    );
    // Same as the edit page: the root node follows the tree's meta.
    final nodes = [
      for (final n in await _trees.loadNodes(tree.id))
        n.isRoot
            ? n.copyWith(name: updated.name, amount: updated.baseAmount, currency: updated.currency,
                notes: updated.notes, updatedAt: DateTime.now())
            : n,
    ];
    await _trees.saveNodes(updated, nodes);
    final back = (await _trees.loadTrees()).where((t) => t.id == tree.id && t.name == updated.name &&
        t.baseAmount == updated.baseAmount && t.currency == updated.currency);
    if (back.isEmpty) return _unverified(tool);
    await _treesChanged();
    return _ok(tool, 'تم تعديل الشجرة «${updated.name}»', 'Updated tree "${updated.name}"', id: tree.id);
  }

  Future<SaraVerificationResult> _deleteTree(Map<String, dynamic> p) async {
    const tool = 'delete_financial_tree';
    final (tree, err) = await _resolveTree(tool, _s(p['tree_name']), allowSole: false);
    if (tree == null) return err!;
    await _trees.deleteTree(tree.id);
    if ((await _trees.loadTrees()).any((t) => t.id == tree.id)) return _unverified(tool);
    await _treesChanged();
    return _ok(tool, 'تم حذف الشجرة «${tree.name}»', 'Deleted tree "${tree.name}"', id: tree.id);
  }

  Future<SaraVerificationResult> _addNode(Map<String, dynamic> p) async {
    const tool = 'add_tree_node';
    final name = _s(p['name']);
    if (name.isEmpty) return _fail(tool, 'ما اسم البند؟', 'What is the item name?', 'MISSING_NAME');
    final type = _s(p['node_type']).toLowerCase();
    final bad = _badType(tool, type) ?? _badAmount(tool, p['amount']);
    if (bad != null) return bad;
    final (tree, err) = await _resolveTree(tool, _s(p['tree_name']));
    if (tree == null) return err!;
    final nodes = await _trees.loadNodes(tree.id);
    FinancialTreeNode? parent;
    if (_s(p['parent_name']).isEmpty) {
      parent = nodes.where((n) => n.isRoot).firstOrNull;
    } else {
      final (n, e) = _resolveNode(tool, nodes, _s(p['parent_name']));
      if (n == null) return e!;
      parent = n;
    }
    if (parent == null) return _fail(tool, 'الشجرة بلا جذر', 'The tree has no root', 'NOT_FOUND');
    final now = DateTime.now();
    final node = FinancialTreeNode(
      id: newNodeId(), treeId: tree.id, parentId: parent.id, name: name,
      type: FinancialTreeNodeType.fromId(type.isEmpty ? 'custom' : type),
      amount: _num(p['amount']) ?? 0,
      currency: _s(p['currency']).isEmpty ? tree.currency : _s(p['currency']).toUpperCase(),
      notes: _s(p['notes']),
      sortOrder: nodes.where((n) => n.parentId == parent!.id).length,
      createdAt: now, updatedAt: now);
    final out = [
      for (final n in nodes) n.id == parent.id && n.collapsed ? n.copyWith(collapsed: false) : n,
      node,
    ];
    await _trees.saveNodes(tree.copyWith(updatedAt: now), out);
    if (!(await _trees.loadNodes(tree.id)).any((n) => n.id == node.id)) return _unverified(tool);
    await _treesChanged();
    return _ok(tool, 'تمت إضافة «$name» تحت «${parent.name}» في «${tree.name}»',
        'Added "$name" under "${parent.name}" in "${tree.name}"', id: node.id);
  }

  Future<SaraVerificationResult> _updateNode(Map<String, dynamic> p) async {
    const tool = 'update_tree_node';
    final type = _s(p['node_type']).toLowerCase();
    final bad = _badType(tool, type) ?? _badAmount(tool, p['amount']);
    if (bad != null) return bad;
    final (tree, err) = await _resolveTree(tool, _s(p['tree_name']));
    if (tree == null) return err!;
    final nodes = await _trees.loadNodes(tree.id);
    final (node, e) = _resolveNode(tool, nodes, _s(p['node_name']));
    if (node == null) return e!;
    if (node.isRoot) {
      return _fail(tool, 'هذا جذر الشجرة — عدّله من بيانات الشجرة.',
          'This is the tree root — edit the tree itself.', 'ROOT_NODE');
    }
    String? parentId;
    if (_s(p['new_parent_name']).isNotEmpty) {
      final (np, pe) = _resolveNode(tool, nodes, _s(p['new_parent_name']));
      if (np == null) return pe!;
      // Same rule as «نقل»: never under itself or its own branch.
      String? cursor = np.id;
      while (cursor != null) {
        if (cursor == node.id) {
          return _fail(tool, 'لا يمكن نقل البند تحت نفسه أو أحد فروعه.',
              'An item cannot move under itself or its own branch.', 'INVALID_PARENT');
        }
        cursor = nodes.where((n) => n.id == cursor).firstOrNull?.parentId;
      }
      parentId = np.id;
    }
    final now = DateTime.now();
    final updated = node.copyWith(
      name: _s(p['new_name']).isEmpty ? null : _s(p['new_name']),
      type: type.isEmpty ? null : FinancialTreeNodeType.fromId(type),
      amount: _num(p['amount']),
      currency: _s(p['currency']).isEmpty ? null : _s(p['currency']).toUpperCase(),
      notes: p.containsKey('notes') ? _s(p['notes']) : null,
      parentId: parentId,
      sortOrder: parentId != null && parentId != node.parentId
          ? nodes.where((n) => n.parentId == parentId).length : null,
      updatedAt: now,
    );
    final out = _recomputeSortOrders([for (final n in nodes) n.id == node.id ? updated : n]);
    await _trees.saveNodes(tree.copyWith(updatedAt: now), out);
    final back = (await _trees.loadNodes(tree.id)).where((n) => n.id == node.id &&
        n.name == updated.name && n.amount == updated.amount && n.parentId == updated.parentId);
    if (back.isEmpty) return _unverified(tool);
    await _treesChanged();
    return _ok(tool, 'تم تعديل البند «${updated.name}» في «${tree.name}»',
        'Updated "${updated.name}" in "${tree.name}"', id: node.id);
  }

  Future<SaraVerificationResult> _deleteNode(Map<String, dynamic> p) async {
    const tool = 'delete_tree_node';
    final (tree, err) = await _resolveTree(tool, _s(p['tree_name']));
    if (tree == null) return err!;
    final nodes = await _trees.loadNodes(tree.id);
    final (node, e) = _resolveNode(tool, nodes, _s(p['node_name']));
    if (node == null) return e!;
    if (node.isRoot) {
      return _fail(tool, 'جذر الشجرة لا يُحذف — احذف الشجرة نفسها إن أردت.',
          'The root cannot be deleted — delete the tree instead.', 'ROOT_NODE');
    }
    // Same as the screen: the item goes with its whole branch.
    final remove = <String>{node.id};
    var changed = true;
    while (changed) {
      changed = false;
      for (final n in nodes) {
        if (n.parentId != null && remove.contains(n.parentId) && remove.add(n.id)) changed = true;
      }
    }
    final now = DateTime.now();
    await _trees.saveNodes(tree.copyWith(updatedAt: now),
        _recomputeSortOrders(nodes.where((n) => !remove.contains(n.id)).toList()));
    if ((await _trees.loadNodes(tree.id)).any((n) => remove.contains(n.id))) return _unverified(tool);
    await _treesChanged();
    final extra = remove.length - 1;
    return _ok(tool,
        'تم حذف «${node.name}»${extra > 0 ? ' مع $extra بند تحته' : ''} من «${tree.name}»',
        'Deleted "${node.name}"${extra > 0 ? ' with $extra items under it' : ''} from "${tree.name}"',
        id: node.id, data: {'deleted_nodes': remove.length});
  }

  static List<FinancialTreeNode> _recomputeSortOrders(List<FinancialTreeNode> nodes) {
    final result = <FinancialTreeNode>[];
    void visit(String? parentId) {
      final children = nodes.where((n) => n.parentId == parentId).toList()
        ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
      for (var i = 0; i < children.length; i++) {
        final c = children[i];
        result.add(c.sortOrder == i ? c : c.copyWith(sortOrder: i));
        visit(c.id);
      }
    }
    visit(null);
    return result;
  }

  // ── merchant links (the merchant accounts screen) ──

  static List<String> _merchantNames(Map<String, dynamic> m) =>
      [_s(m['merchant_name']), _s(m['shop_name'])].where((s) => s.isNotEmpty).toList();

  static String _merchantLabel(Map<String, dynamic> m) {
    final names = _merchantNames(m);
    return names.isEmpty ? '—' : names.first;
  }

  SaraVerificationResult _offline(String tool) => _fail(tool,
      'روابط التجار تحتاج اتصالاً بالإنترنت — لم يتغير شيء.',
      'Merchant links need an internet connection — nothing changed.', 'OFFLINE');

  Future<SaraVerificationResult> _respondInvite(Map<String, dynamic> p, {required bool accept}) async {
    final tool = accept ? 'accept_merchant_invite' : 'reject_merchant_invite';
    final api = merchantApi;
    if (api == null) return _offline(tool);
    final name = _s(p['merchant_name']);
    List<Map<String, dynamic>> invites;
    try {
      invites = await api.myInvites();
    } catch (_) {
      return _offline(tool);
    }
    if (invites.isEmpty) {
      return _fail(tool, 'لا توجد طلبات ربط من التجار.', 'There are no merchant link requests.', 'NOT_FOUND',
          state: SaraVerificationState.notFound);
    }
    Map<String, dynamic>? inv;
    if (name.isEmpty && invites.length == 1) {
      inv = invites.first;
    } else {
      final (m, options) = _pick(invites, name, _merchantNames);
      if (m == null) {
        final list = options.map(_merchantLabel).join('، ');
        return _fail(tool, 'أي طلب تقصد؟ الطلبات: $list', 'Which request? Requests: $list',
            name.isEmpty ? 'NEEDS_MERCHANT' : 'NOT_FOUND',
            data: {'invites': options.map(_merchantLabel).toList()});
      }
      inv = m;
    }
    final linkId = _s(inv['link_id']);
    final label = _merchantLabel(inv);
    try {
      accept ? await api.acceptInvite(linkId) : await api.rejectInvite(linkId);
    } catch (_) {
      return _fail(tool, accept ? 'فشل قبول طلب «$label»' : 'فشل رفض طلب «$label»',
          accept ? 'Failed to accept "$label"' : 'Failed to reject "$label"', 'SAVE_FAILED');
    }
    try {
      final pending = (await api.myInvites()).any((i) => _s(i['link_id']) == linkId);
      final linked = !accept || (await api.myMerchants()).any((m) => _s(m['link_id']) == linkId);
      if (pending || !linked) return _unverified(tool);
    } catch (_) {
      return _unverified(tool);
    }
    return _ok(tool, accept ? 'تم ربط التاجر «$label» بحسابك' : 'تم رفض طلب «$label»',
        accept ? 'Linked merchant "$label"' : 'Rejected the request of "$label"', id: linkId);
  }

  Future<SaraVerificationResult> _unlink(Map<String, dynamic> p) async {
    const tool = 'unlink_merchant';
    final api = merchantApi;
    if (api == null) return _offline(tool);
    List<Map<String, dynamic>> merchants;
    try {
      merchants = await api.myMerchants();
    } catch (_) {
      return _offline(tool);
    }
    final (m, options) = _pick(merchants, _s(p['merchant_name']), _merchantNames);
    if (m == null) {
      final list = options.map(_merchantLabel).join('، ');
      return _fail(tool,
          merchants.isEmpty ? 'لا يوجد تجار مرتبطون بحسابك.' : 'أي تاجر تقصد؟ التجار: $list',
          merchants.isEmpty ? 'No merchants are linked.' : 'Which merchant? $list',
          'NOT_FOUND', state: SaraVerificationState.notFound,
          data: {'merchants': options.map(_merchantLabel).toList()});
    }
    final linkId = _s(m['link_id']);
    final label = _merchantLabel(m);
    try {
      await api.unlinkMerchant(linkId);
    } catch (_) {
      return _fail(tool, 'فشل فك الربط مع «$label»', 'Failed to unlink "$label"', 'SAVE_FAILED');
    }
    try {
      if ((await api.myMerchants()).any((x) => _s(x['link_id']) == linkId)) return _unverified(tool);
    } catch (_) {
      return _unverified(tool);
    }
    return _ok(tool, 'تم فك الربط مع «$label» (الديون كما هي)',
        'Unlinked "$label" (debts unchanged)', id: linkId);
  }
}
