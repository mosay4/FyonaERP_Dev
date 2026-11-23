set -euo pipefail
umask 077
export TMPDIR=/tmp/opencode
proof=../verification/business-restore-continuation
mapfile -t cases < <(grep -Eo '/test/[^ :]+\.dart' ../verification/business-local-continuation/flutter-enabled-verified.log | sed 's|^/||' | sort -u)
if ((${#cases[@]} < 25)); then exit 2; fi
cases+=(
  test/business_backup_screen_test.dart test/business_local_backup_test.dart test/business_debt_report_test.dart
  test/business_money_report_test.dart test/business_reconciliation_test.dart test/business_local_ledger_test.dart
  test/business_device_followup_test.dart test/business_cash_relay_runtime_test.dart test/reports_feature_test.dart
  test/reconciliation_feature_test.dart test/recon_back_nav_test.dart test/recon_count_linked_test.dart
)
run_suite() {
  local log=$1
  shift
  flock /tmp/opencode/fyona-business-flutter.lock /opt/fyona/flutter/bin/flutter test --no-pub --reporter expanded "$@" "${cases[@]}" > "$log" 2>&1 || {
    grep -A22 -B2 -E '(\[E\]|Failing tests:|\.dart:[0-9]+:[0-9]+: Error)' "$log" | tail -155
    return 1
  }
  tail -4 "$log"
}
case "${1:-enabled}" in
  enabled)
    run_suite "$proof/flutter-qa-enabled-final.log" \
      --dart-define=FYONA_DIRECTORY_PILOT=true --dart-define=FYONA_DIRECTORY_PILOT_SIGNUP=true \
      --dart-define=FYONA_BUSINESS_LEDGER_QA=true --dart-define=FYONA_BUSINESS_CASH_RELAY_QA=true \
      --dart-define=FYONA_DIRECTORY_ACCOUNT=b722efef-8a1c-4830-885b-3ad90492e837 \
      --dart-define=FYONA_DIRECTORY_ORG=0f683120-9e30-4876-ac15-6dd2decafaa6 \
      --dart-define=FYONA_DIRECTORY_BRANCH=da2e39ff-3990-4c16-863d-293fb902b93d
    ;;
  disabled) run_suite "$proof/flutter-flags-off-final.log" ;;
  *) exit 2 ;;
esac
