"""Phase 1 test only: fresh Postgres & real FYONA API, all on loopback.

Run from Linux with the FYONA venv, PostgreSQL 18, Redis and Mailpit installed.
Nothing is loaded from a project .env. Credentials for fake users are written
to a private run folder. Managed QA uses a separate unprivileged systemd unit
and is exposed only by the dedicated HTTPS proxy. This API never binds publicly.
"""

import atexit
import contextlib
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
from urllib.request import ProxyHandler, build_opener


SERVE_PORT = 18084
ENROLL_PORT = 18085
API_PORT = 18083
QA_ORIGIN = "https://qa.fyonacompany.com:18443"
MANAGED_ENROLL_ROOT = Path("/var/lib/private/fyona-directory-qa-enroll/run")
BUSINESS_FLAGS = (
    "FYONA_QA_ENROLL_NEW_LEDGER",
    "FYONA_QA_CASH_RELAY",
    "FYONA_QA_EMPLOYEE_FINANCE",
)
BUSINESS_PROBE_SLOTS = range(1, 5)
BUSINESS_LINK_PROBE_SLOTS = range(1, 6)


def business_probe_email(root, slot, *, link=False):
    if slot not in (BUSINESS_LINK_PROBE_SLOTS if link else BUSINESS_PROBE_SLOTS):
        raise ValueError("Invalid managed Business probe slot")
    label = "business-link-probe" if link else "business-probe"
    return root / f"{label}-email-{slot}"


PILOT = {
    "account": "b722efef-8a1c-4830-885b-3ad90492e837",
    "organization": "0f683120-9e30-4876-ac15-6dd2decafaa6",
    "branch": "da2e39ff-3990-4c16-863d-293fb902b93d",
    "other_branch": "da2e39ff-3990-4c16-863d-293fb902b93e",
}
SEED = """
import asyncio, json
from datetime import datetime, timezone, timedelta
from pathlib import Path
from uuid import UUID, uuid4
import app.main
from app.core.database import async_session_factory
from app.core.security import hash_password
from app.domain.entities.auth_entities import Organization, Role, User
from app.domain.entities.sale_entities import Branch
from app.domain.entities.branch_entities import BranchMember
from app.domain.entities.business_entities import Customer, Supplier

async def seed():
    fs = json.loads(Path('fixture.json').read_text())
    org = UUID(fs['organization'])
    own = UUID(fs['account'])
    two = uuid4()
    staff = uuid4()
    now = datetime.now(timezone.utc)
    ends = now + timedelta(days=7)
    async with async_session_factory() as db:
        for oid, name, plan in ((org, 'متجر المرحلة الأولى', 'premium'),
                                (two, 'حساب الموظف التجريبي', 'personal')):
            db.add(Organization(id=oid, name=name, slug=oid.hex,
                subscription_plan=plan, subscription_status='active',
                subscription_start_date=now, subscription_end_date=ends,
                business_setup_completed=True, onboarding_completed=True))
        await db.flush()
        for oid in (org, two):
            db.add(Role(organization_id=oid, name='owner', name_ar='مالك', is_system=True))
        await db.flush()
        for index, (uid, oid, profile, mode) in enumerate((
            (own, org, 'owner', 'business'), (staff, two, 'staff', 'personal')
        ), start=1):
            credentials = fs[profile]
            phone = credentials.get('phone') or f'+1202555010{index}'
            # Seeded fake users own VERIFIED phones (auth v2) and keep their
            # email + password for the QA scripts (legacy /auth/login stays
            # enabled for them via AUTH_LEGACY_EMAIL_ROUTES=login).
            db.add(User(id=uid, organization_id=oid, full_name='QA ' + profile,
                email=credentials['email'], phone=phone, phone_e164=phone,
                phone_verified_at=now, phone_country='US', email_verified=True,
                role='owner', password_hash=hash_password(credentials['password']),
                preferred_usage_mode=mode))
        await db.flush()
        pilot = UUID(fs['branch'])
        legacy = UUID(fs['other_branch'])
        db.add_all([Branch(id=pilot, organization_id=org, name='فرع تجربة الدليل'),
                    Branch(id=legacy, organization_id=org, name='فرع اختبار الأعمال المتصلة', is_default=True)])
        await db.flush()
        db.add(BranchMember(organization_id=org, user_id=staff,
                 branch_ids=json.dumps([str(legacy)]), status='active',
                 all_branches=False, permissions=json.dumps(
                     {'dashboard': True, 'customers': False, 'suppliers': False,
                      'branches': True, 'branches.view': True})))
        # These server rows belong to the legacy branch only. The directory
        # pilot branch has no REST directory fixture and never publishes its IDs.
        db.add_all([Customer(organization_id=org, branch_id=legacy, name='Legacy QA Customer'),
                    Supplier(organization_id=org, branch_id=legacy, name='Legacy QA Supplier')])
        await db.commit()

asyncio.run(seed())
"""

SERVER = """
import asyncio
import os
from pathlib import Path
import uvicorn
from app.core import version
from starlette.responses import JSONResponse
managed = os.environ['FYONA_QA_REMOTE'] == '1'
scenarios = os.environ.get('FYONA_QA_BUSINESS_SCENARIOS') == '1'
existing_business_qa = os.environ.get('FYONA_QA_KEEP_EXISTING_DATA') == '1'
if managed or scenarios:
    from app.core import paths
    paths.UPLOAD_ROOT = str(Path.cwd() / 'uploads')
if managed:
    release_info = version.get_version_info
    def qa_version_info():
        return {**release_info(), 'environment': 'phase-one-qa'}
    # Health caches version information at import.
    version.get_version_info = qa_version_info
from app import main
from app.core import mdns, qa_business_ledger, qa_directory
from app.core.database import async_session_factory, engine
from app.api.v1 import auth
from app.domain.services.branch_service import decode_scope_token

async def disabled_rates():
    await asyncio.Event().wait()
async def no_advertisement(*args):
    return None
main._warm_currency_rates = disabled_rates
mdns.start_advertisement = no_advertisement
if existing_business_qa:
    async def keep_role_permissions(*args):
        return 0
    main.ensure_system_role_permissions = keep_role_permissions
if qa_directory.INVITES:
    init_db = main.init_db
    async def install_enrollment_schema():
        # Upgrading an already initialized QA enrollment service should
        # install only the feature schemas, not re-run legacy data backfills.
        if not existing_business_qa:
            await init_db()
        await qa_directory.install(engine)
        await qa_business_ledger.install(engine)
        # Auth v2 tables/columns (init_db is skipped on a kept sandbox).
        from app.core import auth2_schema
        await auth2_schema.install(engine)
        if os.environ.get('FYONA_QA_CASH_RELAY') == '1':
            from app.domain.services.qa_cash_admission import orders
            async with engine.begin() as connection:
                await connection.run_sync(orders.metadata.create_all)
    main.init_db = install_enrollment_schema
if managed:
    async def no_geo(*args):
        return {'country': None, 'region': None, 'city': None}
    auth._geo_lookup = no_geo

@main.app.middleware('http')
async def qa_private_accounts_only(request, call_next):
    if not managed and not qa_directory.INVITES:
        return await call_next(request)
    if request.url.hostname == 'qa.fyonacompany.com' and not Path('ready').is_file():
        return JSONResponse({'status': 'starting'}, status_code=503)
    path = request.url.path.rstrip('/')
    invite_routes = frozenset(('/api/v1/auth/register',
                              '/api/v1/auth/verify-registration',
                              '/api/v1/auth/resend-otp'))
    if path in invite_routes and qa_directory.INVITES:
        try:
            payload = await request.json()
            email = str(payload.get('email') or '').strip().lower()
        except (AttributeError, ValueError):
            email = ''
        if email not in qa_directory.INVITES:
            return JSONResponse({'detail': 'غير مصرح بالوصول'}, status_code=403)
        return await call_next(request)
    if qa_directory.INVITES and path == '/api/v1/auth/me' and request.method == 'PUT':
        # An invitation can be claimed only through the existing signup OTP,
        # not by renaming an already seeded test user's profile.
        try:
            data = await request.json()
            email = str(data.get('email') or '').strip().lower()
        except (AttributeError, ValueError):
            email = ''
        if email in qa_directory.INVITES:
            return JSONResponse({'detail': 'غير مصرح بالوصول'}, status_code=403)
    # Keep signup closed without an invite. External OAuth, email mutation
    # and administrative routes are not part of the public sandbox.
    # Card payment for the user's own subscription (owner's decision: same
    # Stripe account as production). Admin/webhook payment routes stay shut.
    if os.environ.get('STRIPE_SECRET_KEY') and path in (
            '/api/v1/payments/stripe/plans',
            '/api/v1/payments/stripe/create-checkout-session',
            '/api/v1/payments/stripe/create-payment-intent',
            '/api/v1/payments/stripe/setup-intent',
            '/api/v1/payments/stripe/auto-renew/enable',
            '/api/v1/payments/stripe/auto-renew/activate',
            '/api/v1/payments/stripe/auto-renew/disable',
            '/api/v1/payments/stripe/auto-renew/status',
            '/api/v1/payments/stripe/confirm',
            '/api/v1/payments/stripe/return',
            '/api/v1/payments/stripe/cancel'):
        return await call_next(request)
    if path.startswith(('/api/v1/admin', '/fyona-admin', '/docs', '/redoc', '/metrics',
                        '/openapi.json', '/api/v1/auth/register', '/api/v1/payments',
                        '/api/v1/auth/verify-registration', '/api/v1/auth/resend',
                        '/api/v1/auth/forgot', '/api/v1/auth/reset',
                        '/api/v1/auth/email-change',
                        '/api/v1/auth/verify-otp', '/api/v1/auth/google',
                        '/api/v1/auth/firebase', '/api/v1/auth2/admin')):
        return JSONResponse({'detail': 'Not found'}, status_code=404)
    return await call_next(request)

@main.app.middleware('http')
async def single_writer_for_the_pilot_directory(request, call_next):
    path = request.url.path.rstrip('/')
    if request.method not in ('GET', 'HEAD', 'OPTIONS') and (
        path in ('/api/v1/customers', '/api/v1/suppliers', '/api/v1/merchant-links/party/delete') or
        path.startswith(('/api/v1/customers/', '/api/v1/suppliers/'))
    ):
        scope = decode_scope_token(request.headers.get('X-Branch-Token'))
        if scope and (scope.get('branch') == os.environ['FYONA_QA_BRANCH'] or
                      await qa_directory.is_registered_branch(async_session_factory,
                                                             scope.get('branch'))):
            return JSONResponse({'detail': 'غير مصرح بالوصول'}, status_code=403)
    return await call_next(request)

@main.app.middleware('http')
async def single_writer_for_the_pilot_ledger(request, call_next):
    # The trial branch's financial ledger is written by its device only.
    path = request.url.path.rstrip('/')
    if request.method not in ('GET', 'HEAD', 'OPTIONS') and path.startswith((
        '/api/v1/invoices', '/api/v1/products', '/api/v1/categories',
        '/api/v1/banking', '/api/v1/inventory', '/api/v1/returns',
        '/api/v1/expenses', '/api/v1/finance', '/api/v1/accounting',
        '/api/v1/reconciliation', '/api/v1/hr', '/api/v1/debts',
    )):
        scope = decode_scope_token(request.headers.get('X-Branch-Token'))
        if scope and await qa_business_ledger.is_registered_branch(
            async_session_factory, scope.get('branch'),
        ):
            return JSONResponse({'detail': 'دفتر هذا الفرع يعمل من الجهاز فقط'},
                                status_code=403)
    return await call_next(request)

uvicorn.run(main.app, host='127.0.0.1', port=int(os.environ['FYONA_QA_API_PORT']),
            forwarded_allow_ips='127.0.0.1', limit_concurrency=40,
            timeout_keep_alive=10)
"""


def port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def main():
    managed = os.environ.get("FYONA_QA_REMOTE") == "1"
    signup = os.environ.get("FYONA_QA_SIGNUP") == "1"
    scenarios = os.environ.get("FYONA_QA_BUSINESS_SCENARIOS") == "1"
    probe_slots = os.environ.get("FYONA_QA_BUSINESS_PROBES") == "1"
    link_probes = os.environ.get("FYONA_QA_BUSINESS_LINK_PROBES") == "1"
    cash_link = scenarios or os.environ.get("FYONA_QA_CASH_LINK") == "1"
    business_flags = {key: "1" for key in BUSINESS_FLAGS if scenarios or os.environ.get(key) == "1"}
    if len(sys.argv) != 2 or (managed and os.geteuid() == 0) or (
        not managed and os.geteuid() != 0
    ):
        sys.exit("Use root for a local lab and an unprivileged systemd user for managed QA.")
    if scenarios and (
        managed or not signup
        or set(socket.if_nameindex()) != {(1, "lo")}
    ):
        sys.exit("Business scenarios require new accounts in a loopback-only network namespace.")
    if not scenarios and (business_flags or probe_slots or cash_link) and not (managed and signup):
        sys.exit("The managed Business services require the private enrollment sandbox.")
    if cash_link and "FYONA_QA_CASH_RELAY" not in business_flags:
        sys.exit("Cash link requires the QA cash relay.")
    if link_probes and not (managed and signup and probe_slots and cash_link):
        sys.exit("Managed link probes require separate enrollment slots and the QA cash link.")
    os.umask(0o077)
    root = Path(sys.argv[1]).resolve()
    if managed:
        expected = Path(os.environ["STATE_DIRECTORY"]).resolve()
        if root != expected / "run":
            sys.exit("Managed QA must use its private systemd state directory.")
    root.mkdir(exist_ok=managed)
    ready_path = root / "ready"
    ready_path.unlink(missing_ok=True)
    atexit.register(lambda: ready_path.unlink(missing_ok=True))
    source = Path(__file__).resolve().parents[1] / "backend"
    python = os.environ.get("FYONA_PYTHON", "/root/fyona-erp/backend/.venv/bin/python")
    pg_bin = Path("/usr/lib/postgresql/18/bin")
    invites = []
    if signup:
        invite_paths = [root / f"signup-email-{index}"
                        for index in range(1, (5 if scenarios else 3) + 1)]
        if probe_slots:
            if root != MANAGED_ENROLL_ROOT or set(business_flags) != set(BUSINESS_FLAGS):
                sys.exit("Managed probes require the QA enrollment service and all Business flags.")
            invite_paths.extend(business_probe_email(root, slot) for slot in BUSINESS_PROBE_SLOTS)
        if link_probes:
            invite_paths.extend(
                business_probe_email(root, slot, link=True) for slot in BUSINESS_LINK_PROBE_SLOTS
            )
        for email_path in invite_paths:
            if not email_path.is_file():
                email_path.write_text(f"signup-{secrets.token_hex(12)}@example.test\n")
            invites.append(email_path.read_text().strip())
        if len(set(invites)) != len(invites):
            sys.exit("QA invite slots must be distinct.")
    persistent = managed and bool(invites)

    def secret_file(name, entropy):
        p = root / name
        if not p.is_file():
            p.write_text(secrets.token_urlsafe(entropy) + "\n")
        value = p.read_text().strip()
        if not re.fullmatch(r"[A-Za-z0-9_-]{30,120}", value):
            raise ValueError("Malformed private sandbox secret")
        return value

    api_port = (ENROLL_PORT if invites else SERVE_PORT) if managed else API_PORT
    private_sockets = root / "ports.json"
    if persistent and private_sockets.is_file():
        pg, redis, mail, smtp = json.loads(private_sockets.read_text())
    else:
        pg, redis, mail, smtp = (port() for _ in range(4))
        if persistent:
            private_sockets.write_text(json.dumps([pg, redis, mail, smtp]) + "\n")
    assert len({pg, redis, mail, smtp, api_port}) == 5
    with socket.socket() as check_port:
        check_port.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        check_port.bind(("127.0.0.1", api_port))

    # No connections to the host's existing PostgreSQL instance. The only
    # database principal used by the API owns this disposable database.
    if persistent:
        cluster = root / "postgres"
        cluster.mkdir(exist_ok=True)
    else:
        cluster = Path(tempfile.mkdtemp(prefix="fyona-directory-pg.",
                                       dir=root if managed else "/tmp/opencode"))
    if not managed:
        shutil.chown(cluster, user="postgres", group="postgres")
    runner = [] if managed else ["runuser", "-u", "postgres", "--"]

    def postgres(tool, *args):
        subprocess.run(
            [*runner, str(pg_bin / tool), *args],
            check=True,
            stdout=subprocess.DEVNULL,
        )

    pgdata = cluster / "data"
    if not (pgdata / "PG_VERSION").is_file():
        postgres("initdb", "-D", str(pgdata), "-U", "postgres",
                 "--auth-local=trust" if managed else "--auth-local=peer",
                 "--auth-host=scram-sha-256")
    postgres("pg_ctl", "-D", str(cluster / "data"), "-l", str(cluster / "pg.log"),
             "-o", (f"-p {pg} -h 127.0.0.1 -k {cluster} "
                    "-c shared_buffers=32MB -c max_connections=24"), "-w", "start")

    def close_pg():
        postgres("pg_ctl", "-D", str(cluster / "data"), "-m", "fast", "-w", "stop")
        if not persistent:
            shutil.rmtree(cluster)

    atexit.register(close_pg)
    db_password = secret_file("db-password", 32) if persistent else secrets.token_urlsafe(32)
    if not (cluster / "db-initialized").is_file():
        subprocess.run(
            [*runner, str(pg_bin / "psql"), "-q", "-U", "postgres", "-h",
             str(cluster), "-p", str(pg), "-d", "postgres", "-v", "ON_ERROR_STOP=1"],
            input=("CREATE ROLE directory_pilot LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE "
                   f"PASSWORD '{db_password}';\n"
                   "CREATE DATABASE directory_pilot OWNER directory_pilot;\n"),
            text=True, check=True, stdout=subprocess.DEVNULL,
        )
        if persistent:
            (cluster / "db-initialized").touch()

    env = {
        "PATH": f"{Path(python).parent}:/usr/bin:/bin",
        "HOME": str(root),
        "LANG": "C.UTF-8",
        "PYTHONPATH": os.pathsep.join(
            [str(source), str(source.parents[0] / "python" / "site-packages")]
            if managed else [str(source)]
        ),
        "PYTHONDONTWRITEBYTECODE": "1",
        "AWS_EC2_METADATA_DISABLED": "true",
        "HTTPS_PROXY": "http://127.0.0.1:1",
        "HTTP_PROXY": "http://127.0.0.1:1",
        "NO_PROXY": "127.0.0.1,localhost",
        "ALLOWED_HOSTS": json.dumps(["127.0.0.1", "localhost"] +
                                   (["qa.fyonacompany.com"] if managed else [])),
        "API_BASE_URL": QA_ORIGIN if managed else f"http://127.0.0.1:{api_port}",
        "DEPLOY_SHA": ("phase-one-qa-enroll-6193-link" if link_probes else
                       "phase-one-qa-enroll-6193-business" if managed and business_flags else
                       "phase-one-qa-enroll-6193" if invites else "phase-one-qa-6193"),
        "FYONA_QA_API_PORT": str(api_port),
        "DEBUG": "false",
        "JWT_SECRET_KEY": secret_file("jwt-secret", 40) if persistent else secrets.token_urlsafe(40),
        # Backup key management: per-account keys are derived from this
        # master on the server only (never stored with the backups).
        "FYONA_BACKUP_MASTER_KEY": secret_file("backup-master-key", 48) if persistent else secrets.token_urlsafe(48),
        "DATABASE_URL": ("postgresql+asyncpg://directory_pilot:"
                         f"{db_password}@127.0.0.1:{pg}/directory_pilot"),
        "REDIS_URL": f"redis://127.0.0.1:{redis}/0",
        "DATABASE_POOL_SIZE": "4",
        "DATABASE_MAX_OVERFLOW": "4",
        "STORAGE_BACKEND": "local",
        "CELERY_BROKER_URL": "memory://",
        "CELERY_RESULT_BACKEND": "cache+memory://",
        "SMTP_HOST": "127.0.0.1",
        "SMTP_PORT": str(smtp),
        "SMTP_FROM": "lab@example.test",
        "SMTP_TLS": "false",
        "FYONA_QA_BRANCH": PILOT["branch"],
        "FYONA_QA_REMOTE": "1" if os.environ.get("FYONA_QA_REMOTE") == "1" else "0",
    }
    # Sara and the Falcon: DeepSeek key from a private file in the state
    # folder (never in the release or git). Only DeepSeek is reachable; every
    # other outbound call stays blocked by the dead proxy above.
    ai_key = root / "deepseek-key"
    if managed and ai_key.is_file():
        value = ai_key.read_text().strip()
        if not re.fullmatch(r"sk-[A-Za-z0-9]{20,100}", value):
            raise ValueError("Malformed AI provider key")
        env["DEEPSEEK_API_KEY"] = value
        env["SARA_API_KEY"] = value
        # The lab may only reach localhost; the egress gateway on localhost
        # (fyona-qa-sara-egress) opens the allow-listed hosts and nothing else.
        env["HTTPS_PROXY"] = "http://127.0.0.1:18990"
    # Stripe (card payment of the subscription): settings from a private
    # state file, never from the release or git.
    stripe_env = root / "stripe.env"
    if managed and stripe_env.is_file():
        for line in stripe_env.read_text().splitlines():
            name, _, value = line.partition("=")
            if re.fullmatch(r"STRIPE_[A-Z_]+", name) and value:
                env[name] = value.strip()
        env.setdefault("HTTPS_PROXY", "http://127.0.0.1:18990")
        if env["HTTPS_PROXY"] == "http://127.0.0.1:1":
            env["HTTPS_PROXY"] = "http://127.0.0.1:18990"
    # Phone sign-in providers (WhatsApp Cloud API, SMS.to, Sign in with
    # Apple): private state file, whitelisted names only, exactly like
    # stripe.env. The Apple .p8 key stays a file next to it (path only).
    providers_env = root / "auth-providers.env"
    if managed and providers_env.is_file():
        for line in providers_env.read_text().splitlines():
            name, _, value = line.partition("=")
            name = name.strip()
            if re.fullmatch(r"WHATSAPP_[A-Z_]+|META_[A-Z_]+|SMS_[A-Z_]+|APPLE_[A-Z_]+",
                            name) and value.strip():
                env[name] = value.strip()
        env.setdefault("HTTPS_PROXY", "http://127.0.0.1:18990")
        if env["HTTPS_PROXY"] == "http://127.0.0.1:1":
            env["HTTPS_PROXY"] = "http://127.0.0.1:18990"
    # Cloudflare R2 (media, chat files, encrypted backups): the S3 keys the
    # server needs to SIGN short-lived URLs. Admin API tokens in the same file
    # are never loaded into the server.
    cloudflare_env = root / "cloudflare.env"
    if managed and cloudflare_env.is_file():
        for line in cloudflare_env.read_text().splitlines():
            name, _, value = line.partition("=")
            name = name.strip()
            if name in ("CLOUDFLARE_ACCOUNT_ID", "R2_ACCESS_KEY_ID",
                        "R2_SECRET_ACCESS_KEY", "R2_BUCKET") and value.strip():
                env[name] = value.strip()
    apple_key = root / "apple-authkey.p8"
    if managed and apple_key.is_file():
        env["APPLE_PRIVATE_KEY_PATH"] = str(apple_key)
    # Seeded fake users keep signing in by email for the QA scripts; every
    # other email route answers 410 (auth v2 is phone-first).
    env["AUTH_LEGACY_EMAIL_ROUTES"] = "login"
    # Voice messages are turned into text on this server (Whisper, offline
    # model folder; no download at run time).
    stt_model = Path("/opt/fyona-directory-qa/sara-stt/model-small")
    if managed and (stt_model / "model.bin").is_file():
        env["SARA_STT_MODEL"] = str(stt_model)
        env["HF_HUB_OFFLINE"] = "1"
    if invites:
        env["FYONA_QA_DIRECTORY_INVITES"] = json.dumps(invites)
    # Device-only Personal (on by default on this service; the unit may set
    # FYONA_QA_LOCAL_PERSONAL=0 or a different grace period).
    for key in ("FYONA_QA_LOCAL_PERSONAL", "FYONA_PERSONAL_LOCAL_GRACE_HOURS"):
        if os.environ.get(key):
            env[key] = os.environ[key]
    env.update(business_flags)
    if cash_link:
        env["FYONA_QA_CASH_LINK"] = "1"
    if link_probes:
        env["FYONA_QA_LEDGER_PAIR_OWNER"] = business_probe_email(root, 5, link=True).read_text().strip()
    if persistent and (root / "seed-initialized").is_file() and business_flags:
        env["FYONA_QA_KEEP_EXISTING_DATA"] = "1"
    credentials = os.getenv("CREDENTIALS_DIRECTORY")
    if persistent and business_flags and credentials:
        continuity = Path(credentials) / "ledger-continuity"
        if continuity.is_file():
            env["FYONA_QA_EXISTING_LEDGER_GRANTS"] = json.dumps(
                json.loads(continuity.read_text()),
            )
    if scenarios:
        env.update(
            FYONA_QA_BUSINESS_SCENARIOS="1",
            FYONA_QA_LEDGER_PAIR_OWNER=invites[4],
            # Four OTP flows and several device sign-ins share one loopback IP.
            # Keep the normal per-user limits and the invite allowlist intact.
            AUTH_RATE_LIMIT_PER_IP_MINUTE="60",
        )
    mail_args = []
    if persistent:
        ui_password = secret_file("mail-reader-password", 32)
        smtp_password = secret_file("mail-sender-password", 32)
        ui_auth, smtp_auth = [root / name for name in ("mail-ui-auth", "mail-smtp-auth")]
        # Both local listeners are authenticated; neither is forwarded by the proxy.
        ui_hash = subprocess.check_output(
            ["openssl", "passwd", "-apr1", "-stdin"],
            input=ui_password + "\n", text=True,
        ).strip()
        ui_auth.write_text(f"relay:{ui_hash}\n")
        smtp_auth.write_text(f"directory-pilot:{smtp_password}\n")
        env.update(SMTP_USER="directory-pilot", SMTP_PASSWORD=smtp_password)
        mail_args += [
            "--ui-auth-file", str(ui_auth), "--smtp-auth-file", str(smtp_auth),
            "--smtp-auth-allow-insecure", "--smtp-max-recipients", "1",
            "--database", str(root / "mailpit.sqlite"),
        ]
        (root / "mailpit-access.json").write_text(json.dumps({
            "base": f"http://127.0.0.1:{mail}", "user": "relay", "password": ui_password,
            "test_address": invites[0],
        }) + "\n")
    children = []

    def close_children():
        for child in reversed(children):
            if child.poll() is None:
                child.terminate()
                try:
                    child.wait(7)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait()

    atexit.register(close_children)
    def stop(*_):
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        raise SystemExit()

    signal.signal(signal.SIGTERM, stop)

    def spawn(name, cmd):
        with (root / f"{name}.log").open("wb") as log:
            p = subprocess.Popen(cmd, env=env, cwd=root, stdout=log, stderr=log)
        children.append(p)
        return p

    spawn("redis", ["redis-server", "--bind", "127.0.0.1", "--port",
                    str(redis), "--save", "", "--appendonly", "no",
                    "--maxmemory", "32mb", "--maxmemory-policy", "noeviction"])
    spawn("mailpit", [os.environ.get("FYONA_MAILPIT", "/opt/fyona/bin/mailpit"),
                      "--listen", f"127.0.0.1:{mail}", "--smtp", f"127.0.0.1:{smtp}",
                      "--disable-version-check", "--max", "100", *mail_args])
    if not managed or invites:
        # This is private to the run directory, never proxied by Caddy.
        (root / "mailpit-url").write_text(f"http://127.0.0.1:{mail}\n")
    api = spawn("api", [python, "-c", SERVER])
    base = f"http://127.0.0.1:{api_port}/api/v1"
    opener = build_opener(ProxyHandler({}))
    deadline = time.monotonic() + 45
    while api.poll() is None and time.monotonic() < deadline:
        with contextlib.suppress(OSError, ValueError):
            with opener.open(f"{base}/health/ready", timeout=2) as reply:
                if json.load(reply)["status"] == "ready":
                    break
        time.sleep(.2)
    else:
        sys.exit(f"Unreachable test API. See {root / 'api.log'}")
    fixture_path = root / "fixture.json"
    public_base = f"{QA_ORIGIN}/api/v1" if managed else base
    if managed and fixture_path.is_file():
        # Preserve tester login on an intentional sandbox restart. The lab
        # PostgreSQL data is disposable; the on-device directory is not.
        fixture = json.loads(fixture_path.read_text())
        assert fixture["base"] == public_base
        assert all(fixture[key] == value for key, value in PILOT.items())
        if any("phone" not in fixture[role] for role in ("owner", "staff")):
            for index, role in enumerate(("owner", "staff"), start=1):
                fixture[role].setdefault("phone", f"+1202555010{index}")
            fixture_path.write_text(json.dumps(fixture, indent=2) + "\n")
    else:
        fixture = {
            **PILOT,
            "base": public_base,
            **{role: {"email": f"directory-{role}@example.test",
                      "phone": f"+1202555010{index}",
                      "password": "Aa1!" + secrets.token_hex(10)}
               for index, role in enumerate(("owner", "staff"), start=1)},
        }
        fixture_path.write_text(json.dumps(fixture, indent=2) + "\n")
    if not persistent or not (root / "seed-initialized").is_file():
        with (root / "seed.log").open("wb") as log:
            seeded = subprocess.run([python, "-c", SEED], env=env, cwd=root,
                                    stdout=log, stderr=log)
            if seeded.returncode:
                sys.exit(f"Test data setup failed. See {root / 'seed.log'}")
        if persistent:
            (root / "seed-initialized").touch()
    ready_path.touch()
    print(f"Directory pilot ready on {base}. Test fixture: {root / 'fixture.json'}", flush=True)
    if scenarios:
        scenario = source.parent / "tools" / "prepare_business_delivery_lab.py"
        prepared = subprocess.run([python, "-B", str(scenario), str(root)], env=env, cwd=root)
        if prepared.returncode:
            sys.exit(prepared.returncode)
    api.wait()
    sys.exit(api.returncode)


if __name__ == "__main__":
    main()
