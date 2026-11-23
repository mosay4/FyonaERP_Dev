import 'reports_api.dart';

class ReportRequestGuard {
  int _generation = 0;
  (int, String) begin() => (++_generation, BusinessReportsApi.scopeIdentity);
  bool accepts((int, String) ticket) =>
      ticket.$1 == _generation && ticket.$2 == BusinessReportsApi.scopeIdentity;
  void invalidate() => _generation++;
}
