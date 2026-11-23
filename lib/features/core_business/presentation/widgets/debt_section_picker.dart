import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/localization/app_localizations.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../personal/data/merchant_api.dart';
import '../../data/local_commerce/local_commerce_api.dart';
import '../../data/local_directory/directory_scope.dart';
import 'debt_widgets.dart';

/// «قسم الدين» selector (individual vs a real section) shown inside the
/// sale/purchase invoice when a debt remains. A clean field opens a designed
/// bottom sheet instead of an upward dropdown.
class DebtSectionPicker extends ConsumerStatefulWidget {
  final String partyKind; // customer | supplier
  final String partyId;
  final String? current;
  final ValueChanged<String?> onChanged;
  const DebtSectionPicker({
    super.key,
    required this.partyKind,
    required this.partyId,
    required this.current,
    required this.onChanged,
  });
  @override
  ConsumerState<DebtSectionPicker> createState() => _DebtSectionPickerState();
}

class _DebtSectionPickerState extends ConsumerState<DebtSectionPicker> {
  List<Map> _groups = [];
  bool _loading = true;
  int _generation = 0;
  late final LocalCommerceBridge _source;

  @override
  void initState() {
    super.initState();
    _source = ref.read(localCommerceBridgeProvider);
    _load();
  }

  @override
  void didUpdateWidget(covariant DebtSectionPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.partyId != widget.partyId ||
        oldWidget.partyKind != widget.partyKind) {
      _groups = [];
      _loading = true;
      _load();
    }
  }

  Future<void> _load() async {
    final generation = ++_generation;
    if (!identical(_source, ref.read(localCommerceBridgeProvider))) return;
    try {
      final groups = _source.active
          ? await _source.partyGroups(
              widget.partyKind == 'supplier'
                  ? DirectoryPartyKind.supplier
                  : DirectoryPartyKind.customer,
              widget.partyId,
            )
          : ((await ref
                        .read(merchantApiProvider)
                        .businessOverview(
                          partyKind: widget.partyKind,
                          partyId: widget.partyId,
                        ))['groups']
                    as List? ??
                const []);
      if (mounted &&
          generation == _generation &&
          identical(_source, ref.read(localCommerceBridgeProvider))) {
        setState(() {
          _groups = groups.whereType<Map>().toList();
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted && generation == _generation)
        setState(() => _loading = false);
    }
  }

  Future<void> _openSheet(AppLocalizations l10n) async {
    const individual = '__individual__';
    final generation = _generation;
    if (!identical(_source, ref.read(localCommerceBridgeProvider))) return;
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(ctx).size.height * 0.72,
        ),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.black12,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
                child: Row(
                  children: [
                    const DebtIcon(Icons.folder_copy_outlined, size: 36),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l10n.translate('debtSectionSheetTitle'),
                            style: DebtStyle.text(
                              context,
                              size: 15,
                              bold: true,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            l10n.translate('debtSectionSheetSubtitle'),
                            style: DebtStyle.text(
                              context,
                              size: 10.5,
                              color: Colors.grey,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(ctx),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                  children: [
                    _tile(
                      icon: Icons.receipt_long_outlined,
                      title: l10n.translate('debtIndividualOption'),
                      subtitle: l10n.translate('debtIndividualSubtitle'),
                      selected: widget.current == null,
                      onTap: () => Navigator.pop(ctx, individual),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      l10n.translate('debtSectionsHeader'),
                      style: DebtStyle.text(
                        context,
                        size: 12,
                        bold: true,
                        color: Colors.grey,
                      ),
                    ),
                    const SizedBox(height: 6),
                    if (_loading)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 18),
                        child: Center(
                          child: SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      )
                    else if (_groups.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        child: Text(
                          l10n.translate('debtNoSections'),
                          style: DebtStyle.text(
                            context,
                            size: 11,
                            color: Colors.grey,
                          ),
                        ),
                      )
                    else
                      for (final g in _groups) ...[
                        _tile(
                          icon: Icons.folder_outlined,
                          title: '${g['name'] ?? ''}',
                          subtitle: l10n.translate(
                            'debtGroupDebtsCount',
                            params: {'n': '${g['count'] ?? 0}'},
                          ),
                          selected: '${g['id']}' == widget.current,
                          onTap: () => Navigator.pop(ctx, '${g['id']}'),
                        ),
                        const SizedBox(height: 8),
                      ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted ||
        picked == null ||
        generation != _generation ||
        !identical(_source, ref.read(localCommerceBridgeProvider)))
      return;
    widget.onChanged(picked == individual ? null : picked);
  }

  Widget _tile({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(13),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        decoration: BoxDecoration(
          color: selected ? DebtStyle.red.withAlpha(12) : AppColors.background,
          borderRadius: BorderRadius.circular(13),
          border: Border.all(
            color: selected ? DebtStyle.red : DebtStyle.border(context),
            width: selected ? 1.6 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(icon, size: 20, color: selected ? DebtStyle.red : Colors.grey),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: DebtStyle.text(context, size: 13, bold: selected),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: DebtStyle.text(
                      context,
                      size: 10.5,
                      color: Colors.grey,
                    ),
                  ),
                ],
              ),
            ),
            if (selected)
              const Icon(Icons.check_circle, size: 18, color: DebtStyle.red),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 10),
        child: SizedBox(
          height: 18,
          width: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    final currentName = widget.current == null
        ? l10n.translate('debtIndividualOption')
        : (_groups.firstWhere(
                    (g) => '${g['id']}' == widget.current,
                    orElse: () => const {},
                  )['name'] ??
                  l10n.translate('debtIndividualOption'))
              .toString();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _openSheet(l10n),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            decoration: BoxDecoration(
              color: AppColors.background,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: DebtStyle.border(context)),
            ),
            child: Row(
              children: [
                Icon(
                  widget.current == null
                      ? Icons.receipt_long_outlined
                      : Icons.folder_outlined,
                  size: 20,
                  color: DebtStyle.red,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.translate('debtSectionLabel'),
                        style: DebtStyle.text(
                          context,
                          size: 10.5,
                          color: Colors.grey,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        currentName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: DebtStyle.text(context, size: 13, bold: true),
                      ),
                    ],
                  ),
                ),
                const Icon(
                  Icons.keyboard_arrow_down_rounded,
                  color: Colors.grey,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          l10n.translate('debtSectionHint'),
          style: DebtStyle.text(context, size: 10.5, color: Colors.grey),
        ),
      ],
    );
  }
}
