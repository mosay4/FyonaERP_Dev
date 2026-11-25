import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart';
import '../../../../core/network/api_client.dart' show serverBaseUrlProvider;
import '../../../../core/network/dio_provider.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../shared/widgets/styled_snack.dart';
import '../../../auth/presentation/providers/auth_provider.dart';
import '../../../branches/data/branch_scope.dart';
import '../../../branches/data/branch_epoch.dart';
import '../../../core_business/data/local_directory/directory_database.dart';
import '../../../core_business/data/local_ledger/business_local_backups.dart';
import '../../../core_business/presentation/providers/business_backup_provider.dart';
import 'business_backup_file_actions.dart';

typedef _BackupSelection = ({
  LocalBusinessBackups? local,
  String? org,
  String? branch,
  String? actor,
  String server,
  bool all,
  int epoch,
});

class BusinessBackupPage extends ConsumerStatefulWidget {
  const BusinessBackupPage({super.key});
  @override
  ConsumerState<BusinessBackupPage> createState() => _BusinessBackupPageState();
}

class _BusinessBackupPageState extends ConsumerState<BusinessBackupPage> {
  List<Map> _rows = [];
  bool _busy = false;
  String? _error;
  _BackupSelection? _shown;
  static const _path = '/business/project-settings/backups';
  @override
  void initState() {
    super.initState();
    _refreshAfterFrame();
  }

  void _refreshAfterFrame() =>
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load();
      });

  _BackupSelection _selection() => (
    local: ref.read(localBusinessBackupsProvider),
    org: BranchScope.organizationId,
    branch: BranchScope.branchId,
    actor: ref.read(authProvider).user?.id,
    server: ref.read(serverBaseUrlProvider),
    all: BranchScope.allMode,
    epoch: ref.read(branchEpochProvider),
  );

  bool _same(_BackupSelection selection) =>
      mounted &&
      _selection() == selection &&
      (selection.local?.isCurrent ?? true);

  Future<void> _load() async {
    final selection = _selection();
    try {
      final local = selection.local;
      final List<Map> rows;
      if (local != null) {
        rows = [
          for (final file in await local.list())
            {
              'id': file.id,
              'created_at': file.createdAt
                  .toLocal()
                  .toString()
                  .split('.')
                  .first,
              'bytes': file.bytes,
            },
        ];
      } else {
        final r = await ref.read(apiClientProvider).get(_path);
        rows = List<Map>.from(r.data['data']['backups']);
      }
      if (_same(selection)) {
        setState(() {
          _rows = rows;
          _error = null;
          _shown = selection;
        });
      }
    } catch (_) {
      if (_same(selection)) {
        setState(() {
          _rows = [];
          _shown = selection;
          _error = 'تعذر تحميل النسخ';
        });
      }
    }
  }

  Future<void> _action(String action, [String? id]) async {
    if (_busy) return;
    final selection = _selection();
    if (!_same(selection) || (id != null && selection != _shown)) return;
    setState(() => _busy = true);
    try {
      final local = selection.local;
      if (local != null) {
        await _localAction(selection, local, action, id);
        return;
      }
      final api = ref.read(apiClientProvider);
      if (action == 'create') await api.post(_path);
      if (action == 'restore' || action == 'delete') {
        if (!await ref.read(businessBackupVerifierProvider)(
              context,
              ref,
              'تأكيد ${action == 'restore' ? 'استعادة' : 'حذف'} النسخة',
              false,
            ) ||
            !_same(selection)) {
          return;
        }
        if (action == 'restore') {
          await api.post('$_path/$id/restore');
          if (_same(selection)) ref.read(branchEpochProvider.notifier).state++;
        } else {
          await api.delete('$_path/$id');
        }
      }
      if (action == 'share' || action == 'save') {
        final r = await api.get('$_path/$id');
        if (!_same(selection)) return;
        final bytes = Uint8List.fromList(
          utf8.encode(jsonEncode(r.data['data'])),
        );
        final filename = 'fyona-business-$id.json';
        if (action == 'save') {
          await FilePicker.saveFile(
            fileName: filename,
            bytes: bytes,
            type: FileType.custom,
            allowedExtensions: ['json'],
          );
        } else {
          await Share.shareXFiles([
            XFile.fromData(bytes, name: filename, mimeType: 'application/json'),
          ]);
        }
      }
      if (_same(selection)) await _load();
    } catch (error) {
      if (_same(selection)) {
        final message = error is BusinessBackupRejected
            ? switch (error.problem) {
                BusinessBackupProblem.invalidArchive =>
                  'رمز الاستعادة أو النسخة غير صالح لهذه السجلات',
                BusinessBackupProblem.notEmpty =>
                  'السجلات غير فارغة؛ لم تُستبدل أو تُدمج أي سجلات',
                BusinessBackupProblem.tooLarge =>
                  'النسخة تتجاوز الحد المسموح لهذه التجربة',
                BusinessBackupProblem.nothingToBackUp =>
                  'لا توجد سجلات في هذا الفرع لإنشاء نسخة',
              }
            : 'تعذر إتمام العملية، لم يتم إعلان نجاحها';
        showFyonaSnack(context, message, success: false);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _localAction(
    _BackupSelection selection,
    LocalBusinessBackups local,
    String action,
    String? id,
  ) async {
    final files = ref.read(businessBackupFilesProvider);
    if (action == 'create') {
      if (!await _verify(selection, 'تأكيد إنشاء النسخة المشفّرة')) return;
      final code = BusinessBackupCode.generate();
      if (!await _showRecoveryCode(code) || !_same(selection)) return;
      await local.create(code);
      if (_same(selection)) {
        showFyonaSnack(context, 'تم إنشاء النسخة المشفّرة', success: true);
        await _load();
      }
      return;
    }
    if (action == 'save' || action == 'share') {
      if (!await _verify(selection, 'تأكيد إخراج النسخة المشفّرة')) return;
      final backup = await local.file(id!);
      if (!_same(selection)) return;
      if (action == 'save') {
        await files.save(backup);
      } else {
        await files.share(backup);
      }
      return;
    }
    if (action == 'delete') {
      if (!await _verify(selection, 'تأكيد حذف النسخة')) return;
      await local.remove(id!);
      if (_same(selection)) await _load();
      return;
    }
    if (!await _verify(selection, 'تأكيد استعادة النسخة')) return;
    final code = await _enterRecoveryCode();
    if (code == null || !_same(selection)) return;
    final BusinessBackupRestore outcome;
    if (action == 'import') {
      final input = await files.pick();
      if (input == null || !_same(selection)) return;
      outcome = await local.restoreStream(input, code);
    } else {
      outcome = await local.restoreFile(id!, code);
    }
    if (!_same(selection)) return;
    showFyonaSnack(
      context,
      outcome.alreadyRestored
          ? 'هذه النسخة مستعادة بالفعل؛ لم تُكرّر السجلات'
          : outcome.hasSharedHistory
          ? 'تمت الاستعادة؛ العمليات المشتركة تحتاج فحصاً قبل مزامنتها'
          : 'تمت استعادة السجلات المحلية',
      success: true,
    );
    if (!outcome.alreadyRestored)
      ref.read(branchEpochProvider.notifier).state++;
    await _load();
  }

  Future<bool> _verify(_BackupSelection selection, String reason) async =>
      await ref.read(businessBackupVerifierProvider)(
        context,
        ref,
        reason,
        true,
      ) &&
      _same(selection);

  Future<bool> _showRecoveryCode(BusinessBackupCode code) async =>
      await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          scrollable: true,
          title: const Text('رمز استعادة النسخة'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'احتفظ بهذا الرمز في مكان منفصل عن الملف. لا يُحفظ في التطبيق ولا يمكن استعادة النسخة بدونه.',
              ),
              const SizedBox(height: 12),
              SelectableText(
                code.text,
                key: const ValueKey('business-backup-code'),
                textDirection: TextDirection.ltr,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('حفظت الرمز، أنشئ النسخة'),
            ),
          ],
        ),
      ) ==
      true;

  Future<BusinessBackupCode?> _enterRecoveryCode() =>
      showDialog<BusinessBackupCode>(
        context: context,
        builder: (_) => const _BusinessRecoveryCodeDialog(),
      );

  @override
  Widget build(BuildContext context) {
    ref.watch(branchEpochProvider);
    ref.watch(localBusinessBackupsProvider);
    ref.watch(authProvider.select((value) => value.user?.id));
    ref.listen(branchEpochProvider, (_, __) => _refreshAfterFrame());
    ref.listen(localBusinessBackupsProvider, (_, __) => _refreshAfterFrame());
    ref.listen(
      authProvider.select((value) => value.user?.id),
      (_, __) => _refreshAfterFrame(),
    );
    final selection = _selection();
    final local = selection.local != null;
    final same = _shown == selection;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text(
          'النسخ الاحتياطي والمزامنة',
          style: TextStyle(fontFamily: 'Cairo'),
        ),
        actions: [
          IconButton(
            onPressed: _busy ? null : _load,
            icon: const Icon(Icons.sync_rounded),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            local
                ? 'نسخة مشفّرة من سجلات هذا الفرع على الجهاز. لا تشمل تسجيل الدخول أو الشخصي. '
                      'الاستعادة إلى سجلات فارغة فقط، ولا تُشغّل المزامنة أو تنقل التفويض إلى جهاز جديد.'
                : 'نسخ بيانات المتجر والفروع المسموحة لك: الفواتير والحسابات والمخزون وإعدادات المشروع. '
                      'حسابات الدخول وملفات الموظفين لا تدخل في هذه النسخة. الاستعادة ترجع البيانات المحفوظة، وترفض الدمج عند وجود سجلات مالية أو مخزنية أحدث لحماية الأرصدة.',
            style: const TextStyle(fontFamily: 'Cairo', fontSize: 12),
          ),
          const SizedBox(height: 16),
          if (_busy && !local) const LinearProgressIndicator(),
          if (!BranchScope.readOnly)
            FilledButton.icon(
              onPressed: _busy ? null : () => _action('create'),
              icon: const Icon(Icons.backup_rounded),
              label: const Text('إنشاء نسخة احتياطية'),
            ),
          if (local && !selection.all)
            OutlinedButton.icon(
              onPressed: _busy ? null : () => _action('import'),
              icon: const Icon(Icons.file_open_outlined),
              label: const Text('استعادة من ملف مشفّر'),
            ),
          if (same && _error != null) Text(_error!),
          for (final row in same ? _rows : const <Map>[])
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${row['created_at']}',
                      style: const TextStyle(
                        fontFamily: 'Cairo',
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      local
                          ? 'نسخة مشفّرة • ${row['bytes']} بايت'
                          : '${row['record_count']} سجل • ${row['bytes']} بايت',
                      style: const TextStyle(fontFamily: 'Cairo', fontSize: 11),
                    ),
                    Wrap(
                      spacing: 8,
                      children: [
                        TextButton(
                          onPressed: _busy
                              ? null
                              : () => _action('save', '${row['id']}'),
                          child: const Text('حفظ'),
                        ),
                        TextButton(
                          onPressed: _busy
                              ? null
                              : () => _action('share', '${row['id']}'),
                          child: const Text('مشاركة'),
                        ),
                        if (!BranchScope.readOnly) ...[
                          TextButton(
                            onPressed: _busy
                                ? null
                                : () => _action('restore', '${row['id']}'),
                            child: const Text('استعادة'),
                          ),
                          TextButton(
                            onPressed: _busy
                                ? null
                                : () => _action('delete', '${row['id']}'),
                            child: const Text('حذف'),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _BusinessRecoveryCodeDialog extends StatefulWidget {
  const _BusinessRecoveryCodeDialog();

  @override
  State<_BusinessRecoveryCodeDialog> createState() =>
      _BusinessRecoveryCodeDialogState();
}

class _BusinessRecoveryCodeDialogState
    extends State<_BusinessRecoveryCodeDialog> {
  final _code = TextEditingController();
  bool _invalid = false;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  void _confirm() {
    try {
      Navigator.pop(context, BusinessBackupCode.parse(_code.text));
    } on BusinessBackupRejected {
      setState(() => _invalid = true);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: const Text('استعادة السجلات'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'أدخل الرمز المحفوظ مع هذه النسخة. لن تُستبدل أي سجلات في الفرع.',
        ),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('business-restore-code'),
          controller: _code,
          textDirection: TextDirection.ltr,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: 'رمز الاستعادة',
            errorText: _invalid ? 'تحقق من الرمز' : null,
          ),
          onSubmitted: (_) => _confirm(),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('إلغاء'),
      ),
      FilledButton(onPressed: _confirm, child: const Text('متابعة')),
    ],
  );
}
