import 'help_catalog.dart';
import 'help_catalog_backup.dart';
import 'help_catalog_business.dart';
import 'help_catalog_common.dart';
import 'help_catalog_gaps.dart';
import 'help_catalog_operations.dart';
import 'help_catalog_personal.dart';
import 'help_catalog_settings.dart';
import 'help_entry.dart';

/// Every curated help entry of the app, in priority order (section catalogs
/// before the common one, so a section's wording wins for shared keys).
class HelpRegistry {
  HelpRegistry._();

  static const List<List<HelpEntry>> sections = [
    kHelpPersonal,
    kHelpBusiness,
    kHelpOperations,
    kHelpSettings,
    kHelpBackup,
    kHelpGaps,
    kHelpCommon,
  ];

  static List<HelpEntry> get all => [for (final s in sections) ...s];

  static HelpCatalog? _catalog;
  static HelpCatalog get catalog => _catalog ??= HelpCatalog(all);
}
