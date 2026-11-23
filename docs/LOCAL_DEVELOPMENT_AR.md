# تشغيل FYONA ERP محليًا

مسار المشروع: `/root/fyona-erp`. أُعدّت الأدوات لـ Android ARM64 وخادم FastAPI على Linux.

## الخادم المحلي

```bash
cd /root/fyona-erp
bash tools/run_backend_dev.sh
```

فحص الجاهزية: `curl -fsS http://127.0.0.1:8001/api/v1/health/ready`. مستندات API المحلية: `http://127.0.0.1:8001/docs`.

يعمل الخادم من `~/.config/fyona-erp/backend` لعدم تحميل ملفات إعدادات الخادم الموجودة في الأرشيف. يستخدم قاعدة `fyona_workspace` في PostgreSQL 18، وRedis محليًا على المنفذ `16379`، وتخزين المرفقات المحلي بدل S3/MinIO. لا تستخدم هذه البيئة بيانات الإنتاج أو بيانات اعتماده لتشغيل الخادم.

لاختبار التسجيل، يلتقط Mailpit بريد التطوير ولا يرسله إلى الإنترنت. افتح `http://127.0.0.1:8025` محليًا للاطلاع على الرسائل. إذا توقف Mailpit، شغّله بالأمر `/opt/fyona/bin/mailpit --listen 127.0.0.1:8025 --smtp 127.0.0.1:1025`.

إذا توقفت قواعد البيانات بعد إعادة تشغيل المضيف، شغّل PostgreSQL بـ `pg_ctlcluster 18 main start` عند الحاجة. شغّل Redis الخاص بالمشروع فقط إذا لم يُجب `redis-cli -p 16379 ping`:

```bash
redis-server --bind 127.0.0.1 --port 16379 --save '' --appendonly no \
  --daemonize yes --pidfile /run/fyona-redis-dev.pid
```

## التطبيق وإرسال ملفات تيليجرام

```bash
cd /root/fyona-erp
export ANDROID_HOME=/opt/fyona/android-sdk JAVA_HOME=/opt/fyona/java17
export PATH="/opt/fyona/flutter/bin:$JAVA_HOME/bin:$ANDROID_HOME/platform-tools:$PATH"
flutter pub get --enforce-lockfile
flutter analyze --no-pub
bash tools/build_and_send_android.sh
python3 tools/send_telegram.py docs/FYONAERP_REVIEW_AR.txt
```

أمر البناء يرسل الـ APK فقط عند نجاح البناء. النسخة المحلية تستخدم توقيع تطوير لا يصلح للنشر أو التحديث فوق نسخة لها توقيع مختلف. عنوان API الافتراضي في هذا الأمر محلي؛ للوصول إليه من هاتف Android متصل بجسر التصحيح، نفّذ `adb reverse tcp:8001 tcp:8001`. عند الحاجة لعنوان خادم آخر ومصرّح به، مرّره كوسيط كامل ينتهي بـ `/api/v1`.

للتحقق من توقيع الحزمة وسلامتها ومعمارية التطبيق بعد البناء: `bash tools/verify_android_apk.sh build/app/outputs/flutter-apk/app-release.apk`.

للتطوير بإعادة التحميل السريع على هاتف ARM64 متصل:

```bash
adb devices
adb reverse tcp:8001 tcp:8001
flutter run --dart-define=API_BASE_URL=http://127.0.0.1:8001/api/v1
```

أبقِ `--dart-define` في أوامر التشغيل المحلية؛ افتراض التطبيق دون هذا الخيار ليس عنوان خادم التطوير. إذا حفظ الهاتف سابقًا عنوانًا مختلفًا من إعداد عنوان الخادم، أعد ضبطه من الشاشة نفسها.

إعداد تيليجرام في `~/.config/fyona-erp/telegram.json` بصلاحية `600`، خارج المصدر والحزمة، ومخصص لإرسال مستندات التطوير لا لتنبيهات الخادم. عند تدوير التوكن، استبدل قيمة `bot_token` في الملف الخاص مع إبقاء `chat_id` إن لم يتغير. لا تضع أيًا من أسرار الخادم في التقرير أو ملف APK.

لفحص واجهة الإدارة المنفصلة: `cd /root/fyona-erp/admin/web` ثم `export PATH="/opt/fyona/node22/bin:$PATH"` و`npm ci` و`npm run typecheck`.

## فحوص سريعة قبل تعديل منطق الأعمال

من جذر المشروع، بعد تصدير مسارات الأدوات:

```bash
flutter test --no-pub --dart-define=API_BASE_URL=http://127.0.0.1:8001/api/v1 \
  test/route_guard_test.dart test/business_routes_test.dart test/sale_totals_test.dart \
  test/usage_choice_trial_test.dart test/debt_payment_direction_test.dart \
  test/reports_feature_test.dart test/reconciliation_feature_test.dart \
  test/invoice_pdf_test.dart test/budget_membership_test.dart \
  test/employee_permissions_navigation_test.dart test/local_first_verification_test.dart
```

لفحوص الخادم، شغّل `pytest` من مجلد الإعدادات المعزول بدلًا من `backend/`، حتى لا تُحمّل الاختبارات ملفات اعتماد الأرشيف:

```bash
repo=/root/fyona-erp/backend
cd "${XDG_CONFIG_HOME:-$HOME/.config}/fyona-erp/backend"
PYTHONPATH="$repo" "$repo/.venv/bin/python" -m pytest -q \
  "$repo/tests/test_report_integrity_regression.py" \
  "$repo/tests/unit/test_all_branches_read_only.py" \
  "$repo/tests/unit/test_phone_validation.py" \
  "$repo/tests/unit/test_email_templates.py"
```
