# FYONA ERP — تعليمات البناء والتشغيل

هذا الأرشيف يحتوي **الكود المصدري والموارد والإعدادات** فقط. لا يحتوي بيئات تشغيل، ولا قواعد بيانات إنتاج، ولا مرفقات مستخدمين، ولا ملفات بناء/APK.

## 1) المتطلبات
- Flutter 3.47.x (Dart 3.13.x) — القيد في `pubspec.yaml`: `sdk: ^3.12.2`.
- Python 3.12 (مُختبر بالمشروع على 3.12.14).
- PostgreSQL 18 + Redis + MinIO (أو أي S3 متوافق).
- Android SDK + Java 17 لبناء APK.
- Node.js 18+ لبناء واجهة الإدارة إن لزم.
- أدوات Windows/Visual Studio لبناء نسخة Windows، وXcode/macOS لبناء iOS.

## 2) Backend (FastAPI)
```bash
cd backend
python3.12 -m venv venv
. venv/bin/activate
pip install -r requirements.txt
```
راجع `backend/.env` (مشمول). المفاتيح الأساسية:
- `DATABASE_URL` و`REDIS_URL`
- `JWT_SECRET_KEY`
- `S3_ENDPOINT_URL` / `S3_ACCESS_KEY` / `S3_SECRET_KEY` / `S3_BUCKET`
- `FIREBASE_CREDENTIALS_PATH` (الملف `backend/serviceAccount.json` مشمول)
- مفاتيح Stripe/SMTP/خرائط/SMS عند الحاجة.

أنشئ قاعدة البيانات. من قاعدة فارغة استخدم أحد المسارين:
```bash
sudo -u postgres createuser -s fyona
sudo -u postgres createdb -O fyona fyona_erp
# المسار الموصى به: مخطط كامل بدون بيانات (118 جدولًا)
psql -d fyona_erp -f schema.sql
```
أو دع التطبيق ينشئ المخطط من النماذج عند أول تشغيل:
```bash
python -c "import asyncio; from app.core.database import init_db; asyncio.run(init_db())"
```
> `schema.sql` هو **مخطط فقط** (بدون صفوف/بيانات مستخدمين) ومُختبر على قاعدة فارغة: 118 جدولًا.
> توجد 120 migration في `backend/migrations/versions/` لتحديث قواعد موجودة. سلسلة Alembic التاريخية قد لا تعمل من قاعدة فارغة بسبب ترتيب مفاتيح أجنبية قديم؛ استخدم `schema.sql` أو `init_db()` للإنشاء من الصفر، و`alembic upgrade head` للترقيات على قاعدة قائمة.

شغّل الخدمات:
```bash
redis-server --daemonize yes
# شغّل MinIO وأنشئ bucket بالاسم الموجود في .env (افتراضيًا fyona-files)
uvicorn app.main:app --host 0.0.0.0 --port 8001
# واجهة الإدارة (اختياري):
cd ../admin/server && uvicorn admin_server:app --host 0.0.0.0 --port 8080
```
لإنشاء مدير النظام الأول:
```bash
cd backend
. venv/bin/activate
ADMIN_MASTER_EMAIL=... ADMIN_SUPERADMIN_PASSWORD=... python create_super_admin.py
```
الـ API: `http://127.0.0.1:8001/api/v1` — الصحة عبر `/health` إن كانت متاحة.

## 3) تطبيق Flutter
```bash
flutter pub get
flutter analyze
flutter test
```
عنوان الـ API:
- افتراضيًا يُكتشف من الشبكة/`API_BASE_URL`.
- عند البناء يمكن تمريره:
```bash
flutter build apk --release --dart-define=API_BASE_URL=https://api.example.com/api/v1
```
بناء المنصات:
```bash
flutter build apk --release
flutter build windows --release
flutter build web --release
# iOS على macOS:
flutter build ios --release
```
توقيع Android:
- `android/key.properties` و`android/upload-keystore.jks` مشمولان.
- عدّل `storeFile` إن نقلت المشروع، وتأكد أن كلمة المرور صحيحة.
- إن لم ترغب باستخدام مفتاح الإنتاج، استخدم توقيع debug/مفتاحًا جديدًا.

## 4) واجهة الإدارة
`admin/web` واجهة ثابتة/JS. `admin/server/admin_server.py` خادم FastAPI صغير. شغّله من بيئة backend أو ثبّت FastAPI/uvicorn.
`backend/scripts/proxy80.py` وكيل HTTP اختياري.

## 5) ما استُثني
- `backend/venv/`, `.dart_tool/`, `build/`, `android/.gradle/`, `node_modules/`.
- `backend/app/uploads/` (مرفقات/وسائط مستخدمين فعلية).
- `backend/backups/`, السجلات، `__pycache__`, ملفات `.pyc`.
- APK/EXE الناتجة، ومقاطع الفيديو غير المستخدمة في الجذر.
- لا توجد قاعدة بيانات إنتاج؛ الهجرات وحدها كافية لإنشاء مخطط فارغ.

## 6) التحقق
```bash
cd backend && python -m compileall app
flutter analyze
flutter test
```
المشروع لا يحوي Git، لذا لا تاريخ commits. جميع الملفات المصدرية الحالية مشمولة.

## 7) تنبيه أمني
ملفات `.env` و`serviceAccount.json` ومفتاح التوقيع مشمولة لأنها لازمة للتشغيل. اعتبرها أسرارًا حقيقية: بدّلها/دوّرها قبل أي نشر إنتاجي، ولا ترفع الأرشيف إلى مكان عام.
