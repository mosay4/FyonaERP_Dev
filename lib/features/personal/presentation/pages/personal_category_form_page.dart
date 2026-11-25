import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../shared/widgets/two_tone_icon.dart';
import '../../../../shared/widgets/two_tone_icons.dart';
import '../../data/models/personal_models.dart';
import '../providers/personal_providers.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';

class PersonalCategoryFormPage extends ConsumerStatefulWidget {
  const PersonalCategoryFormPage({super.key});
  @override
  ConsumerState<PersonalCategoryFormPage> createState() => _PersonalCategoryFormPageState();
}

class _PersonalCategoryFormPageState extends ConsumerState<PersonalCategoryFormPage> {
  final _nameCtrl = TextEditingController();
  final _nameArCtrl = TextEditingController();
  bool _isEdit = false;
  String _editId = '';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final extra = GoRouterState.of(context).extra;
    if (extra is Map<String, dynamic>) {
      final cat = extra['category'] as SpendingCategory?;
      if (cat != null) {
        _isEdit = true;
        _editId = cat.id;
        _nameCtrl.text = cat.name;
        _nameArCtrl.text = cat.nameAr;
      }
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _nameArCtrl.dispose();
    super.dispose();
  }

  bool _saving = false;

  Future<void> _submit() async {
    if (_saving) return;
    final l10n = AppLocalizations.of(context);
    final name = _nameCtrl.text.trim();
    final nameAr = _nameArCtrl.text.trim();
    if (name.isEmpty || nameAr.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(l10n.translate('pleaseEnterName'), style: TextStyle(fontFamily: 'Cairo')),
        backgroundColor: AppColors.danger, behavior: SnackBarBehavior.floating,
      ));
      return;
    }
    HapticFeedback.lightImpact();
    final cat = SpendingCategory(id: _editId, name: name, nameAr: nameAr);
    final notifier = ref.read(categoryProvider.notifier);
    _saving = true;
    final err = _isEdit ? await notifier.update(cat) : await notifier.add(cat);
    _saving = false;
    if (!mounted) return;
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(err, style: TextStyle(fontFamily: 'Cairo')),
        backgroundColor: AppColors.danger, behavior: SnackBarBehavior.floating,
      ));
      return;
    }
    context.pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return SingleChildScrollView(
        padding: EdgeInsets.all(R.spacing(context, 16)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(l10n.translate('nameArabic'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 14), fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
          SizedBox(height: R.spacing(context, 8)),
          FyonaTextField(
            controller: _nameArCtrl,
            decoration: InputDecoration(
              hintText: l10n.translate('exampleFood'), hintStyle: TextStyle(fontFamily: 'Cairo', color: AppColors.textSecondary),
              filled: true, fillColor: AppColors.surface,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
            ),
            style: TextStyle(fontFamily: 'Cairo', color: AppColors.textPrimary, fontSize: R.fontSize(context, 15)),
          ),
          SizedBox(height: R.spacing(context, 16)),
          Text(l10n.translate('nameEnglish'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 14), fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
          SizedBox(height: R.spacing(context, 8)),
          FyonaTextField(
            controller: _nameCtrl,
            decoration: InputDecoration(
              hintText: 'e.g. Food', hintStyle: TextStyle(fontFamily: 'Cairo', color: AppColors.textSecondary),
              filled: true, fillColor: AppColors.surface,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
            ),
            style: TextStyle(fontFamily: 'Cairo', color: AppColors.textPrimary, fontSize: R.fontSize(context, 15)),
          ),
          SizedBox(height: R.spacing(context, 24)),
          ElevatedButton(
            onPressed: _submit,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary, foregroundColor: Colors.white,
              padding: EdgeInsets.symmetric(vertical: R.spacing(context, 14)),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)), elevation: 0,
            ),
            child: Text(_isEdit ? l10n.translate('saveChanges') : l10n.translate('add'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 15), fontWeight: FontWeight.w700)),
          ),
        ]),
      );
  }
}