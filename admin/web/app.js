/* FYONA Admin Web App — SPA logic. Talks only to the local proxy (/api/...). */
const $ = (s) => document.querySelector(s);
const $$ = (s) => Array.from(document.querySelectorAll(s));

/* ════════════════════════════════════════════════════
   FYONA ADMIN UI KIT
   Language/direction system · Icons · Reusable components
   ════════════════════════════════════════════════════ */

let LANG = localStorage.getItem("fyona_admin_lang");
if (LANG !== "en") LANG = "ar";

/* English translations for chrome (nav, titles, common actions).
   Falls back to the Arabic literal when a key is missing so the direction
   system can never break a page. */
const L10N = {
  "لوحة التحكم":"Dashboard","الاشتراكات":"Subscriptions","طلبات الاشتراك":"Subscription Requests",
  "تقارير الاشتراكات":"Subscription Reports","المستخدمون":"Users","المنظمات والتجريبي":"Organizations & Trial",
  "الباقات والأسعار":"Plans & Pricing","التحكم":"Controls","الأقسام والأزرار":"Sections & Buttons",
  "الموظفون والصلاحيات":"Staff & Permissions","إيميلات الاشعارات":"Notification Emails","إيميلات اشعارات الاشتراكات":"Subscription notification emails",
  "المحاسبة الإدارية":"Admin Accounting","البنوك والعمليات":"Banks & Operations","البنوك والعمليات وصرفيات الإدارة":"Banks, operations & withdrawals",
  "التواصل":"Communication","الإشعارات":"Notifications","اللافتات":"Banners","الاقتراحات":"Suggestions",
  "نظرة عامة على النظام":"System overview","اعتماد أو رفض اشتراكات المستخدمين":"Approve or decline user subscriptions",
  "إحصائيات شاملة حسب الحالة والتاريخ":"Comprehensive status & date statistics","إدارة المستخدمين والحظر والتحقق":"Manage, verify and ban users",
  "الاشتراك التجريبي وتفعيل المنظمات":"Trial subscription & organization activation","تعديل الباقات وأسعار الاشتراك":"Edit plans and pricing",
  "التحكم في الأقسام والأزرار":"Control sections and buttons","إيقاف/تشغيل الأقسام والأزرار والصيانة":"Enable/disable sections, buttons and maintenance",
  "إنشاء موظفين ومنحهم صلاحيات محددة":"Create staff and grant permissions","من يتوصل إشعارات طلبات الاشتراك":"Who receives subscription request alerts",
  "إرسال إشعار لجميع المستخدمين":"Send a notification to all users","التحكم في لافتات الشاشة الرئيسية":"Control home-screen banners",
  "متابعة ورّد على اقتراحات العملاء":"Track and reply to customer suggestions","تسجيل الخروج":"Sign out","كونسول الإدارة":"Admin Console",
  "لوحة الإدارة":"Admin Panel","دخول":"Sign in","أهلاً بك":"Welcome","سجّل دخولك للتحكم الكامل في النظام":"Sign in to control the whole system",
  "البريد الإلكتروني":"Email","كلمة المرور":"Password","جارٍ الدخول…":"Signing in…","حفظ":"Save","إغلاق":"Close","إلغاء":"Cancel",
  "تعديل":"Edit","حذف":"Delete","إضافة":"Add","بحث":"Search","عرض الكل":"Show all","القائمة":"Menu","إغلاق القائمة":"Close menu",
  "جاهز":"Ready","جاري التحميل…":"Loading…","إعادة المحاولة":"Retry",
};
function T(s) { return LANG === "ar" ? s : (L10N[s] || s); }

function applyLang() {
  const root = document.documentElement;
  root.setAttribute("lang", LANG);
  root.setAttribute("dir", LANG === "ar" ? "rtl" : "ltr");
  root.setAttribute("data-lang", LANG);
  $$("[data-txt]").forEach((el) => { el.textContent = T(el.textContent); });
  const tb = $("#tbLogo"); if (tb) tb.style.display = "flex";
}

/* ── SVG icon set (stroke, currentColor) — professional, no emoji ── */
const SVG_ICONS = {
  dashboard: '<path d="M4 12 L4 19 M4 12 L10 12 M10 12 L16 5 M10 12 L20 12 M16 5 L20 12 M16 5 L20 19 M4 5 L10 5"/>',
  subscriptions: '<rect x="5" y="5" width="14" height="14" rx="2"/><path d="M8 9 L19 9 M8 14 L19 14"/>',
  reports: '<path d="M5 5 L19 5 M8 7 L8 19"/>',
  settings02: '<circle cx="7" cy="7" r="2.6"/><circle cx="17" cy="7" r="2.6"/><path d="M12 6 L18 6 M8 10 L16 10 M6 13 L12 13 M10 16 L16 16"/>',
  users: '<circle cx="9" cy="9" r="5.5"/><circle cx="16" cy="13" r="5.5"/><path d="M7 15 L19 15"/>',
  orgs: '<circle cx="9" cy="9" r="5"/><circle cx="15.5" cy="9" r="5"/><path d="M12 4 L12 18 M12 18 L19 18"/>',
  plans: '<path d="M9 4 L15 4 L18 9 L18 15 L12 15"/>',
  controls: '<rect x="6" y="9" width="6" height="6" rx="1"/><rect x="14" y="9" width="5" height="3" rx="1"/><path d="M14 13 L19 13"/>',
  staff: '<circle cx="9" cy="9" r="4.5"/><rect x="13" y="5" width="6" height="14" rx="1.5"/><circle cx="16" cy="8" r="2.4"/>',
  notify_emails: '<rect x="5" y="9" width="6" height="4" rx="1"/><path d="M11 9 L11 16 M15 5 L15 16 M19 7 L19 14"/>',
  accounting: '<path d="M7 5 L7 19 M19 7 L19 19 M7 12 L15 12"/>',
  notifications: '<path d="M9 6 L9 18 M19 8 L19 15"/>',
  banners: '<rect x="5" y="7" width="14" height="9" rx="1"/>',
  suggestions: '<path d="M7 18 L19 7 M15 10 L15 20 M9 5 L9 9 M9 9 L13 12"/>',
  menu: '<path d="M4 6 L20 6 M4 12 L20 12 M4 18 L20 18"/>',
  logout: '<path d="M6 5 L12 10 L6 16 M13 5 L18 10 L20 6"/>',
  globe: '<circle cx="12" cy="12" r="9"/><path d="M6 8.5 Q12 5.8 18 8.5 Q18 13 6 13.2"/><path d="M8.5 6 L14.5 6 M8.5 14.5 L14.5 14.5"/>',
  back: '<path d="M5 5 L14 5 M5 5 L5 13 M5 13 L14 13"/>',
};
function icon(name, size) {
  const s = size || 20;
  return `<span class="ic" style="width:${s}px;height:${s}px"><svg viewBox="0 0 24 24" width="${s}" height="${s}" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">${SVG_ICONS[name] || SVG_ICONS.dashboard}</svg></span>`;
}

/* ── Small reusable components ── */
function uiBtn(label, onclick, kind = "", iconName = "") {
  const ic = iconName ? icon(iconName, 16) : "";
  return `<button class="tbtn ${kind}" onclick="${onclick}">${ic}<span>${esc(T(label))}</span></button>`;
}
function uiPageHeader(title, sub) {
  return `<div class="section"><div><h2 style="font-size:var(--fs-lg);font-weight:800">${esc(T(title))}</h2><div class="muted" style="font-size:12px">${esc(T(sub || ""))}</div></div></div>`;
}
function uiEmpty(iconName, title, desc) {
  return `<div class="empty"><div class="em-ic">${icon(iconName, 26)}</div><b>${esc(T(title))}</b><span>${esc(T(desc || ""))}</span></div>`;
}
function uiSkeleton(rows) {
  const n = Math.max(rows || 4, 2);
  let html = `<div class="skeleton">`;
  for (let i = 0; i < n; i++) html += `<div class="sk-row" style="width:${92 - i * 12}%"></div>`;
  return html + "</div>";
}

/* Translate-aware status badge */
const BADGE_AR = { pending: "قيد الانتظار", approved: "معتمدة", rejected: "مرفوضة", cancelled: "ملغية", deleted: "محذوفة", active: "نشط", inactive: "معطل", banned: "محظور", trial: "تجريبي", expired: "منتهي", paid: "مدفوعة", failed: "فاشلة", in_progress: "قيد التنفيذ", proposed: "مقترح", completed: "مكتملة" };
const BADGE_EN = { pending: "Pending", approved: "Approved", rejected: "Rejected", cancelled: "Cancelled", deleted: "Deleted", active: "Active", inactive: "Inactive", banned: "Banned", trial: "Trial", expired: "Expired", paid: "Paid", failed: "Failed", in_progress: "In progress", proposed: "Proposed", completed: "Completed" };

/* Mobile-first table processor: adds data-labels so tables become cards on
   small screens (pure CSS, no per-table markup needed). */
function wrapTables() {
  $$("table").forEach((t) => {
    if (!t.parentElement || t.getAttribute("data-tblok") === "1") return;
    t.setAttribute("data-tblok", "1");
    t.classList.add("tbl-mobile");
    const headers = Array.from(t.querySelectorAll("thead th")).map((th) => th.textContent.trim());
    const rows = t.querySelectorAll("tbody tr");
    rows.forEach((r) => {
      Array.from(r.querySelectorAll("td")).forEach((td, i) => {
        if ((td.getAttribute("colspan") || "1") !== "1") { td.classList.add("is-empty"); return; }
        td.setAttribute("data-label", (headers[i] || "").replace(/[•:]/g, ""));
        if (td.querySelector(".tbtn") || td.querySelector(".btn")) td.classList.add("actions-cell");
      });
    });
    const p = t.parentElement;
    if (p && !p.classList.contains("table-wrap") && !p.classList.contains("tbl-wrap")) {
      const w = document.createElement("div");
      w.className = "tbl-wrap";
      if (p) p.insertBefore(w, t);
      w.appendChild(t);
    }
  });
}

let session = { name: "FYONA Admin", token: "" };
let current = "dashboard";

function toggleLang() {
  LANG = LANG === "ar" ? "en" : "ar";
  try { localStorage.setItem("fyona_admin_lang", LANG); } catch (e) {}
  applyLang();
  buildNav();
  $("#pageTitle").textContent = T(TITLES[current][0]);
  $("#pageSub").textContent = T(TITLES[current][1]);
  const langBtn = $("#langBtn");
  if (langBtn) langBtn.setAttribute("title", LANG === "ar" ? "English" : "العربية");
}

/* Watch #content and re-process tables (mobile data-labels) + toolbar
   whenever any renderer async-fills rows. Debounced for performance. */
let _tblTimer = null;
function scheduleWrapTables() {
  clearTimeout(_tblTimer);
  _tblTimer = setTimeout(wrapTables, 40);
}
(function mountTableObserver() {
  const c = $("#content");
  if (!c || !window.MutationObserver) return;
  const obs = new MutationObserver(() => scheduleWrapTables());
  obs.observe(c, { childList: true, subtree: true, attributes: false });
})();

applyLang();
(function wireLangButton() {
  const b = $("#langBtn");
  if (b) b.onclick = toggleLang;
})();

/* Toast helper */
function toast(msg, isErr = false) {
  const t = $("#toast");
  t.textContent = msg; t.className = "toast" + (isErr ? " err" : "");
  t.style.display = "block";
  clearTimeout(t._h); t._h = setTimeout(() => (t.style.display = "none"), 3200);
}

const MENU = [
  { group: "الرئيسية" },
  { key: "dashboard", label: "لوحة التحكم" },
  { group: "الاشتراكات" },
  { key: "subscriptions", label: "طلبات الاشتراك" },
  { key: "reports", label: "تقارير الاشتراكات" },
  { key: "users", label: "المستخدمون" },
  { key: "plans", label: "الباقات والأسعار" },
  { group: "التحكم" },
  { key: "controls", label: "الأقسام والأزرار" },
  { key: "staff", label: "الموظفون والصلاحيات" },
  { key: "notify_emails", label: "إيميلات الاشعارات" },
  { group: "المحاسبة الإدارية" },
  { key: "accounting", label: "البنوك والعمليات" },
  { group: "التواصل" },
  { key: "notifications", label: "الإشعارات" },
  { key: "banners", label: "اللافتات" },
  { key: "suggestions", label: "الاقتراحات" },
];

const TITLES = {
  dashboard: ["لوحة التحكم", "نظرة عامة على النظام"],
  subscriptions: ["طلبات الاشتراك", "اعتماد أو رفض اشتراكات المستخدمين"],
  reports: ["تقارير الاشتراكات", "إحصائيات شاملة حسب الحالة والتاريخ"],
  users: ["المستخدمون", "إدارة المستخدمين والحظر والتحقق"],
  orgs: ["المنظمات والتجريبي", "الاشتراك التجريبي وتفعيل المنظمات"],
  plans: ["الباقات والأسعار", "تعديل الباقات وأسعار الاشتراك"],
  controls: ["التحكم في الأقسام والأزرار", "إيقاف/تشغيل الأقسام والأزرار والصيانة"],
  staff: ["الموظفون والصلاحيات", "إنشاء موظفين ومنحهم صلاحيات محددة"],
  notify_emails: ["إيميلات اشعارات الاشتراكات", "من يتوصل إشعارات طلبات الاشتراك"],
  accounting: ["المحاسبة الإدارية", "البنوك والعمليات وصرفيات الإدارة"],
  notifications: ["الإشعارات", "عرض الإشعارات وإرسال إشعارات للمستخدمين"],
  banners: ["اللافتات", "التحكم في لافتات الشاشة الرئيسية"],
  suggestions: ["الاقتراحات", "متابعة ورّد على اقتراحات العملاء"],
};

const ICONS = {
  dashboard: "📊", subscriptions: "📝", users: "👥", orgs: "🏢", plans: "💎",
  accounting: "🏦", notifications: "🔔", banners: "🖼️", suggestions: "💬",
};

/* كل أزرار/شاشات التطبيق (مفاتيح route) مع الاسم العربي الظاهر في اللوحة */
const BTN_LABELS = {
  // ── القسم الشخصي ──
  "personal/banks": "البنوك والحسابات",
  "personal/transactions": "العمليات المالية",
  "personal/savings": "الادخار والأهداف",
  "personal/budget": "الميزانية",
  "personal/budget/add": "إضافة ميزانية",
  "personal/budget/edit": "تعديل ميزانية",
  "personal/budget/detail": "تفاصيل ميزانية",
  "personal/debts": "الديون",
  "personal/ai": "المساعد الذكي (زيادة)",
  "personal/suggestions": "التطوير والاقتراحات",
  "personal/analytics": "التحليلات المالية",
  "personal/reports": "التقارير",
  "personal/reports-center": "مركز التقارير",
  "personal/financial-tree": "شجرة الحسابات",
  "personal/account-tree": "شجرة الحسابات (مفصلة)",
  "personal/executive": "الملخص التنفيذي",
  "personal/bank-statement": "كشف حساب بنكي",
  "personal/all-banks-report": "تقرير جميع البنوك",
  "personal/finance-overview": "نظرة عامة مالية",
  "personal/recurring": "المدفوعات المتكررة",
  "personal/recurring/add": "إضافة متكررة",
  "personal/categories": "التصنيفات",
  "personal/categories/add": "إضافة تصنيف",
  "personal/transfer": "التحويل الداخلي",
  "personal/backup": "النسخ الاحتياطي والاستعادة",
  // ── قسم الأعمال ──
  "customers": "العملاء",
  "customers/add": "إضافة عميل",
  "suppliers": "الموردون",
  "suppliers/add": "إضافة مورد",
  "products": "المنتجات",
  "products/add": "إضافة منتج",
  "inventory": "المخزون",
  "inventory/count": "جرد المخزون",
  "sales": "المبيعات",
  "sales/add": "فاتورة مبيعات جديدة",
  "purchases": "المشتريات",
  "purchases/add": "فاتورة مشتريات جديدة",
  "payments": "المدفوعات",
  "payments/add": "تسجيل دفعة",
  "expenses": "المصروفات",
  "expenses/add": "تسجيل مصروف",
  "debts": "الديون (أعمال)",
  "debts/add": "إضافة دين",
  "accounts": "دليل الحسابات",
  "accounts/add": "إضافة حساب",
  "journal": "قيود اليومية",
  "journal/add": "قيد يومية جديد",
  "ledger": "دفتر الأستاذ",
  "trial-balance": "ميزان المراجعة",
  "profit-loss": "قائمة الأرباح والخسائر",
  "balance-sheet": "الميزانية العمومية",
  "cashflow": "التدفق النقدي",
  "fiscal-years": "السنوات المالية",
  "banks": "البنوك (أعمال)",
  "banks/add": "إضافة حساب بنكي",
  "banks/transfer": "تحويل بنكي",
  "banks/statement": "كشف حساب بنكي",
  "cheques": "الشيكات",
  "cheques/new": "شيك جديد",
  "employees": "الموظفون",
  "employees/add": "إضافة موظف",
  "attendance": "الحضور والانصراف",
  "leaves": "الإجازات",
  "payroll": "الرواتب والأجور",
  "payroll/add": "قبض رواتب",
  "contracts": "العقود",
  "contracts/add": "إضافة عقد",
  "fixed-assets": "الأصول الثابتة",
  "fixed-assets/add": "إضافة أصل ثابت",
  "reports": "التقارير",
  "sales-report": "تقرير المبيعات",
  "purchase-report": "تقرير المشتريات",
  "cashflow-report": "تقرير التدفق النقدي",
  "debt-aging": "أعمار الديون",
  "comparative-report": "التقرير المقارن",
  "custom-report": "تقرير مخصص",
  "statement": "كشف الحساب",
  "pos": "نقطة البيع (POS)",
  "projects": "المشاريع",
  "projects/add": "إضافة مشروع",
  "hr-reports": "تقارير الموارد البشرية",
  "users": "المستخدمون"
};

const SECTION_BTNS = {
  personal: [
    "personal/banks","personal/transactions","personal/savings","personal/budget",
    "personal/debts","personal/ai","personal/analytics","personal/reports",
    "personal/financial-tree","personal/executive","personal/bank-statement",
    "personal/all-banks-report","personal/finance-overview","personal/recurring",
    "personal/categories","personal/transfer","personal/backup","personal/suggestions",
  ],
  business: [
    "customers","suppliers","products","inventory","sales","purchases","payments",
    "expenses","debts","accounts","journal","ledger","trial-balance","profit-loss",
    "balance-sheet","cashflow","fiscal-years","banks","banks/transfer","banks/statement",
    "cheques","employees","attendance","leaves","payroll","contracts","fixed-assets",
    "reports","pos","projects","hr-reports","users",
  ],
};
function btnLabel(k){ return BTN_LABELS[k] || k; }

function buildNav() {
  const nav = $("#nav");
  const dnav = $("#drawerNav");
  const renderInto = (target, drawerMode) => {
    target.innerHTML = "";
    MENU.forEach((item) => {
      if (item.group) {
        target.insertAdjacentHTML("beforeend", `<div class="sb-group">${esc(T(item.group))}</div>`);
        return;
      }
      const el = document.createElement("div");
      el.className = "sb-item" + (item.key === current ? " active" : "");
      const nb = (window.__navBadges && window.__navBadges[item.key] > 0) ? `<span class="nav-badge">${window.__navBadges[item.key] > 99 ? "99+" : window.__navBadges[item.key]}</span>` : "";
      el.innerHTML = `${icon(item.key)}<span data-txt>${esc(T(item.label))}</span>${nb}`;
      el.onclick = () => { go(item.key); if (drawerMode) toggleDrawer(false); };
      target.appendChild(el);
    });
  };
  renderInto(nav, false);
  if (dnav) renderInto(dnav, true);
}

let drawerOpen = false;
function toggleDrawer(open) {
  drawerOpen = open;
  $("#appDrawer").classList.toggle("open", open);
  $("#drawerOverlay").classList.toggle("open", open);
}

async function api(path, opts = {}) {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), opts.timeout || 55000);
  let res;
  try {
    res = await fetch(`./api/${path}`, {
      method: opts.method || "GET",
      headers: opts.body ? { "Content-Type": "application/json" } : undefined,
      body: opts.body ? JSON.stringify(opts.body) : undefined,
      signal: ctrl.signal,
    });
  } catch (e) {
    clearTimeout(timer);
    if (e && e.name === "AbortError") throw new Error("انتهت المهلة — السيرفر لا يرد، تحقق من الاتصال وحاول مجدداً");
    throw e;
  }
  clearTimeout(timer);
  if (res.status === 401) {
    // No reload loop: just show the login screen.
    $("#login").style.display = "flex";
    $("#app").style.display = "none";
    throw new Error("unauthorized");
  }
  const ct = res.headers.get("content-type") || "";
  const data = ct.includes("json") ? await res.json() : { success: res.ok };
  if (!data.success && res.status >= 400) throw new Error(data.message || "خطأ");
  return data;
}

function esc(s) { return String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c])); }
function fmtMoney(n, cur = "") { const v = Number(n ?? 0); return v.toLocaleString("en", { maximumFractionDigits: 2 }) + (cur ? ` ${cur}` : ""); }
function fmtDate(s) { if (!s) return "—"; const d = new Date(s); return isNaN(d) ? "—" : d.toLocaleString(LANG === "ar" ? "ar-EG" : "en-GB", { dateStyle: "short", timeStyle: "short" }); }
function periodAr(p) { return p === "monthly" ? T("شهري") : T("سنوي"); }
function planNameAr(name) {
  if (!name) return "—";
  const n = name.toLowerCase();
  if (LANG === "ar") { const PLAN_AR = { personal: "شخصية", business: "أعمال", premium: "أعمال + شخصي", trial: "تجريبي", free: "مجاني" }; return PLAN_AR[n] || name; }
  const PLAN_EN = { personal: "Personal", business: "Business", premium: "Business + Personal", trial: "Trial", free: "Free" };
  return PLAN_EN[n] || name;
}
function badge(status) {
  const c = status || "unknown";
  const labels = LANG === "ar" ? BADGE_AR : BADGE_EN;
  const label = (labels[c] || c);
  return `<span class="badge ${c}">${esc(label)}</span>`;
}
function roleBadge(role) {
  const map = { super_admin: "المشرف العام", owner: "المالك", admin: "مدير", employee: "موظف", support: "دعم", manager: "مدير قسم", viewer: "مشاهد", accountant: "محاسب", user: "مستخدم" };
  const key = (role || "").toLowerCase();
  const label = LANG === "ar" ? (map[key] || role || "—") : ({ super_admin: "Super Admin", owner: "Owner", admin: "Admin", employee: "Employee", support: "Support", manager: "Manager", viewer: "Viewer", accountant: "Accountant", user: "User" }[key] || role || "—");
  return `<span class="role-badge ${esc(key)}">${esc(label)}</span>`;
}

/* Live nav badges (pending items per section). */
window.__navBadges = {};
function setNavBadge(key, count) { window.__navBadges[key] = Number(count) > 0 ? Number(count) : 0; }

function go(key, params = null) {
  current = key;
  // Stop the suggestions live-refresh when leaving the section.
  stopSuggestionPoll();
  buildNav();
  $("#pageTitle").textContent = T(TITLES[key][0]);
  $("#pageSub").textContent = T(TITLES[key][1]);
  const c = $("#content");
  c.innerHTML = uiSkeleton(5);
  (renderers[key] || renderDashboard)(c, params);
  const av = $("#topAvatar");
  const letter = (session.name || "F").trim().charAt(0).toUpperCase();
  if (av) av.textContent = letter;
  if ($("#sideAvatar")) $("#sideAvatar").textContent = letter;
  if ($("#sideUserName")) $("#sideUserName").textContent = session.name || "Administrator";
  if ($("#drawAvatar")) $("#drawAvatar").textContent = letter;
  if ($("#drawUserName")) $("#drawUserName").textContent = session.name || "Administrator";
}

/* ── Dashboard ── */
let dashPeriod = localStorage.getItem("fyona_dash_period") || "30d";
let dashRange = null;
try { dashRange = JSON.parse(localStorage.getItem("fyona_dash_range") || "null"); } catch (e) { dashRange = null; }
function dashSetPeriod(p) {
  dashPeriod = p;
  try { localStorage.setItem("fyona_dash_period", p); } catch (e) {}
  renderDashboard($("#content"));
}
function dashApplyCustom() {
  const f = $("#dashFrom") ? $("#dashFrom").value : "";
  const t = $("#dashTo") ? $("#dashTo").value : "";
  if (!f || !t) { toast(T("حدد من تاريخ وإلى تاريخ")); return; }
  if (t < f) { toast(T("تاريخ النهاية قبل البداية"), true); return; }
  dashRange = { from: f, to: t };
  try { localStorage.setItem("fyona_dash_range", JSON.stringify(dashRange)); } catch (e) {}
  dashSetPeriod("custom");
}
function dashPeriodLabel(p) {
  if (p === "custom" && dashRange) return `${T("مخصص")} (${esc(dashRange.from)} ← ${esc(dashRange.to)})`;
  return p === "7d" ? T("7 أيام") : p === "90d" ? T("90 يوم") : p === "12m" ? T("12 شهر") : p === "custom" ? T("مخصص") : T("30 يوم");
}
function dashOverviewUrl() {
  if (dashPeriod === "custom" && dashRange && dashRange.from && dashRange.to) {
    return `admin/analytics/overview?period=custom&from=${encodeURIComponent(dashRange.from)}&to=${encodeURIComponent(dashRange.to)}`;
  }
  return `admin/analytics/overview?period=${encodeURIComponent(dashPeriod)}`;
}
function growthChip(pct) {
  const v = Number(pct || 0);
  const up = v >= 0;
  const cls = up ? "approved" : "rejected";
  return `<span class="badge ${cls}">${up ? "▲" : "▼"} ${esc(String(v))}%</span>`;
}
const AR_MONTHS = ["يناير", "فبراير", "مارس", "أبريل", "مايو", "يونيو", "يوليو", "أغسطس", "سبتمبر", "أكتوبر", "نوفمبر", "ديسمبر"];
function fmtAxisDate(label, grain) {
  try {
    if (grain === "month" && /^\d{4}-\d{2}$/.test(label || "")) {
      const [y, m] = label.split("-").map(Number);
      return `${AR_MONTHS[m - 1]} ${String(y).slice(2)}`;
    }
    const d = new Date((label || "") + "T00:00:00");
    if (isNaN(d)) return esc(label || "");
    return `${d.getDate()} ${AR_MONTHS[d.getMonth()]}`;
  } catch (e) { return esc(label || ""); }
}
function fmtTipRange(label, grain) {
  try {
    if (grain === "month" && /^\d{4}-\d{2}$/.test(label || "")) {
      const [y, m] = label.split("-").map(Number);
      return `${AR_MONTHS[m - 1]} ${y}`;
    }
    const d = new Date((label || "") + "T00:00:00");
    if (isNaN(d)) return esc(label || "");
    if (grain === "week") {
      const e2 = new Date(d.getTime() + 6 * 864e5);
      return `${d.getDate()} ${AR_MONTHS[d.getMonth()]} — ${e2.getDate()} ${AR_MONTHS[e2.getMonth()]}`;
    }
    return `${d.getDate()} ${AR_MONTHS[d.getMonth()]} ${d.getFullYear()}`;
  } catch (e) { return esc(label || ""); }
}
function growthTipMove(ev, el) {
  try {
    const tip = document.getElementById("growthTip");
    if (!tip) return;
    tip.innerHTML = `<b>${esc(el.dataset.d || "")}</b><br>${T("جدد")}: <b>${esc(el.dataset.n || "0")}</b><br>${T("الإجمالي")}: <b>${esc(el.dataset.c || "0")}</b>`;
    tip.style.display = "block";
    const wrap = document.getElementById("growthWrap");
    const r = wrap ? wrap.getBoundingClientRect() : { left: 0, top: 0 };
    let x = (ev.clientX - r.left) + 14, y = (ev.clientY - r.top) - 10;
    x = Math.max(4, Math.min(x, r.width - 150));
    tip.style.left = x + "px";
    tip.style.top = Math.max(4, y) + "px";
  } catch (e) {}
}
function growthTipHide() {
  try { const tip = document.getElementById("growthTip"); if (tip) tip.style.display = "none"; } catch (e) {}
}
function growthChart(series, grain) {
  const data = (series || []).map((s) => ({
    label: s.label || "",
    count: Number(s.count) || 0,
    cumulative: Number(s.cumulative) || 0,
  }));
  if (!data.length) return `<div class="empty">${T("لا توجد بيانات")}</div>`;
  const W = 680, H = 268, PL = 46, PR = 14, PT = 14, PB = 32;
  const maxV = Math.max(1, ...data.map((s) => s.count));
  const step0 = maxV / 4;
  const mag = Math.pow(10, Math.floor(Math.log10(step0 || 1)));
  const norm = step0 / mag;
  const nice = norm <= 1 ? 1 : norm <= 2 ? 2 : norm <= 2.5 ? 2.5 : norm <= 5 ? 5 : 10;
  const yStep = nice * mag, yMax = yStep * 4;
  const n = data.length;
  const X = (i) => n === 1 ? PL + (W - PL - PR) / 2 : PL + (i * (W - PL - PR)) / (n - 1);
  const Y = (v) => PT + (H - PT - PB) * (1 - Math.min(v, yMax) / yMax);
  let grid = "";
  for (let g = 0; g <= 4; g++) {
    const v = yStep * g, y = Y(v);
    grid += `<line x1="${PL}" y1="${y}" x2="${W - PR}" y2="${y}" class="gx-grid"/>`
      + `<text x="${PL - 6}" y="${y + 4}" class="gx-yl" text-anchor="end">${v >= 1000 ? (v / 1000) + "k" : v}</text>`;
  }
  const pts = data.map((s, i) => [X(i), Y(s.count)]);
  const line = pts.map((p, i) => (i ? "L" : "M") + p[0].toFixed(1) + "," + p[1].toFixed(1)).join(" ");
  const area = `${line} L${pts[pts.length - 1][0].toFixed(1)},${Y(0)} L${pts[0][0].toFixed(1)},${Y(0)} Z`;
  // Sparse X labels: at most 7, always the last one, never overlapping.
  const maxLbl = 7;
  const keep = new Set();
  if (n <= maxLbl) { for (let i = 0; i < n; i++) keep.add(i); }
  else {
    const stride = (n - 1) / (maxLbl - 1);
    for (let k = 0; k < maxLbl; k++) keep.add(Math.round(k * stride));
    keep.add(n - 1);
  }
  let xl = "";
  keep.forEach((i) => {
    xl += `<text x="${X(i)}" y="${H - 10}" class="gx-xl" text-anchor="middle">${fmtAxisDate(data[i].label, grain)}</text>`;
  });
  const dots = data.map((s, i) => `<circle cx="${X(i).toFixed(1)}" cy="${Y(s.count).toFixed(1)}" r="4.5" class="gx-dot"`
    + ` data-d="${esc(fmtTipRange(s.label, grain))}" data-n="${s.count}" data-c="${s.cumulative}"`
    + ` onmousemove="growthTipMove(event,this)" onmouseleave="growthTipHide()"><title>${esc(fmtTipRange(s.label, grain))} — ${s.count}</title></circle>`).join("");
  return `<div id="growthWrap" class="gx-wrap"><svg viewBox="0 0 ${W} ${H}" class="gx-svg" onmouseleave="growthTipHide()">`
    + `<defs><linearGradient id="gxFill" x1="0" y1="0" x2="0" y2="1">`
    + `<stop offset="0" stop-color="#b1122a" stop-opacity=".45"/><stop offset="1" stop-color="#b1122a" stop-opacity=".04"/>`
    + `</linearGradient></defs>`
    + grid
    + `<path d="${area}" fill="url(#gxFill)"/>`
    + `<path d="${line}" class="gx-line" fill="none"/>`
    + xl + dots + `</svg><div id="growthTip" class="gx-tip" style="display:none"></div></div>`;
}
function barChart(rows, money) {
  const max = Math.max(1, ...rows.map((r) => Number(r.count ?? r.amount ?? 0)));
  return `<div class="bars">` + rows.map((r) => {
    const val = Number(r.count ?? r.amount ?? 0);
    const pct = Math.max(3, Math.round((val / max) * 100));
    const lbl = esc(r.label || r.month || r.currency || "");
    const disp = money ? fmtMoney(val, r.currency || "") : esc(String(val));
    return `<div class="bar-row"><span class="bar-lbl">${lbl}</span><div class="bar-track"><div class="bar-fill" style="width:${pct}%"></div></div><b class="bar-val">${disp}</b></div>`;
  }).join("") + `</div>`;
}
async function renderDashboard(c) {
  try {
    const [st, req, ov] = await Promise.all([
      api("admin/dashboard/stats"),
      api("admin/subscription-requests?status=pending"),
      api(dashOverviewUrl()).catch(() => null),
    ]);
    const d = st.data || {};
    const pending = (req.data?.requests || req.data || []).length;
    setNavBadge("subscriptions", pending);
    buildNav();
    const o = ov && ov.data ? ov.data : null;
    const pills = ["7d", "30d", "90d", "12m", "custom"].map((p) =>
      `<button class="tbtn sm ${p === dashPeriod ? "norm" : ""}" onclick="dashSetPeriod('${p}')">${p === "custom" ? T("مخصص") : dashPeriodLabel(p)}</button>`).join("");
    const customBar = dashPeriod === "custom"
      ? `<div class="filterbar" style="margin-top:8px"><input type="date" id="dashFrom" value="${esc((dashRange && dashRange.from) || "")}"><span class="muted">إلى</span><input type="date" id="dashTo" value="${esc((dashRange && dashRange.to) || "")}"><button class="btn" onclick="dashApplyCustom()">${T("تطبيق")}</button></div>`
      : "";
    c.innerHTML = `
      <div class="row">
        <div class="kpi warn"><div class="v">${pending}</div><div class="l">${T("طلبات قيد الانتظار")}</div></div>
        <div class="kpi info"><div class="v">${d.total_users ?? "—"}</div><div class="l">${T("إجمالي المستخدمين")}</div></div>
        <div class="kpi ok"><div class="v">${d.active_subscriptions ?? "—"}</div><div class="l">${T("اشتراكات نشطة")}</div></div>
        <div class="kpi warn"><div class="v">${d.pending_subscriptions ?? "—"}</div><div class="l">${T("قيد المراجعة")}</div></div>
      </div>
      <div class="card"><h3><span class="dot"></span>${T("مؤشرات الأداء")} — ${dashPeriodLabel(dashPeriod)}</h3>
        <div class="filterbar">${pills}</div>${customBar}
        <div id="dashOv">${o ? "" : `<div class="empty">${T("تعذر تحميل التحليلات")}</div>`}</div>
      </div>
      <div class="card info"><h3><span class="dot"></span>${T("أحدث طلبات الاشتراك")}</h3>
        <div class="user-card-grid" id="dashReqs"></div></div>`;
    if (o) {
      const rTrend = (o.revenue_trend || []).filter((_, i, a) => a.length <= 31 || i % Math.ceil(a.length / 31) === 0);
      const subs = (o.subscriptions?.breakdown || []).map((s) => ({ label: planNameAr(s.status) === s.status ? (BADGE_AR[s.status] || s.status) : planNameAr(s.status), count: s.count }));
      const reqs = (o.requests_in_period || []).map((s) => ({ label: (LANG === "ar" ? BADGE_AR : BADGE_EN)[s.status] || s.status, count: s.count }));
      const src = {};
      (o.subscriptions?.by_source || []).forEach((s) => { src[s.source] = s.count; });
      const grain = o.grain || "day";
      $("#dashOv").innerHTML = `
        <div class="row">
          <div class="kpi info"><div class="v">${o.users?.new_in_period ?? 0}</div><div class="l">${T("مستخدمون جدد")} ${growthChip(o.users?.growth_pct)}</div></div>
          <div class="kpi"><div class="v">${o.users?.total ?? "—"}</div><div class="l">${T("إجمالي المستخدمين")}</div></div>
          <div class="kpi ok"><div class="v">${o.subscriptions?.new_in_period ?? 0}</div><div class="l">${T("اشتراكات جديدة")}</div></div>
          <div class="kpi ok"><div class="v">${o.subscriptions?.active_total ?? 0}</div><div class="l">${T("اشتراكات نشطة")}</div></div>
          <div class="kpi"><div class="v">${src.international ?? 0}</div><div class="l">${T("اشتراكات دولية 💳")}</div></div>
          <div class="kpi"><div class="v">${src.local ?? 0}</div><div class="l">${T("اشتراكات محلية 🧾")}</div></div>
        </div>
        <div class="card" style="margin-top:14px"><h3 style="font-size:13px;margin-bottom:8px">${T("نمو المستخدمين")}</h3>${growthChart(o.users_trend, grain)}</div>
        <div class="grid2" style="margin-top:14px">
          <div><h3 style="font-size:13px;margin-bottom:8px">${T("نمو الإيرادات")}</h3>${barChart(rTrend.map((r) => ({ label: r.label, amount: r.count })), true)}</div>
          <div><h3 style="font-size:13px;margin-bottom:8px">${T("مزيج الاشتراكات")}</h3>${barChart(subs, false)}</div>
        </div>
        <div class="grid2" style="margin-top:14px">
          <div><h3 style="font-size:13px;margin-bottom:8px">${T("نتائج الطلبات")}</h3>${reqs.length ? barChart(reqs, false) : `<div class="empty">${T("لا توجد طلبات")}</div>`}</div>
          <div><h3 style="font-size:13px;margin-bottom:8px">${T("إيراد الفترة")} ${growthChip(o.revenue?.growth_pct)}</h3><div id="revBox"><div class="empty">${T("جارٍ التحميل…")}</div></div></div>
        </div>`;
      loadRevenueBox();
    }
    const rows = (req.data?.requests || []).slice(0, 6);
    $("#dashReqs").innerHTML = rows.length
      ? rows.map((r) => {
          const name = r.user_name || "—";
          const serial = String(r.id || "").slice(0, 8);
          return `<div class="user-card" onclick="openSubscription('${r.id}')" role="button" tabindex="0">
            <div class="uc-avatar">${esc(name.charAt(0))}</div>
            <div class="uc-info">
              <div class="uc-name">${esc(name)}</div>
              <div class="uc-serial">#${esc(serial)}</div>
            </div>
            <div style="display:flex;align-items:center;gap:8px;flex:0 0 auto">
              ${badge(r.status)}
              <span class="uc-arrow">←</span>
            </div>
          </div>`;
        }).join("")
      : `<div class="empty">${uiEmpty("subscriptions", "لا توجد طلبات", "")}</div>`;
  } catch (e) { c.innerHTML = `<div class="empty">تعذر تحميل اللوحة: ${esc(e.message)}</div>`; }
}

/* ── Period revenue in an admin-chosen currency ── */
// World currencies for the revenue total selector (engine converts any
// pair it has rates for; unknown ones are listed as unconverted).
const WORLD_CURRENCIES = ["USD", "SAR", "EUR", "AED", "EGP", "YER", "YER_OLD", "YER_NEW",
  "KWD", "QAR", "BHD", "OMR", "JOD", "TRY", "GBP", "INR", "CNY", "PKR", "BDT",
  "PHP", "IDR", "MYR", "THB", "VND", "KRW", "JPY", "SGD", "HKD", "TWD", "AUD",
  "CAD", "CHF", "SEK", "NOK", "DKK", "PLN", "CZK", "RON", "NGN", "KES", "ETB",
  "ZAR", "MXN", "BRL", "ILS", "LBP", "IQD", "SYP", "MAD", "TND", "DZD", "LYD", "SDG"];
let revTarget = null;
try { revTarget = localStorage.getItem("fyona_rev_target") || null; } catch (e) {}
function dashRevenueUrl(target) {
  const q = new URLSearchParams();
  q.set("currency", target);
  if (dashPeriod === "custom" && dashRange && dashRange.from && dashRange.to) {
    q.set("period", "custom");
    q.set("from", dashRange.from);
    q.set("to", dashRange.to);
  } else {
    q.set("period", dashPeriod);
  }
  return `admin/analytics/revenue-converted?${q.toString()}`;
}
function revSetTarget(cur) {
  revTarget = (cur || "USD").toUpperCase();
  try { localStorage.setItem("fyona_rev_target", revTarget); } catch (e) {}
  loadRevenueBox();
}
async function loadRevenueBox() {
  const box = $("#revBox");
  if (!box) return;
  const target = (revTarget || "USD").toUpperCase();
  try {
    const r = await api(dashRevenueUrl(target));
    const d = r.data || {};
    const lines = d.lines || [];
    const unconv = d.unconverted || [];
    const meta = d.rates_meta || {};
    const opts = WORLD_CURRENCIES.map((c) =>
      `<option value="${c}" ${c === target ? "selected" : ""}>${c}</option>`).join("");
    box.innerHTML = `
      <div class="filterbar" style="margin-bottom:8px">
        <span class="muted">${T("الإجمالي بعملة")}</span>
        <select id="revCur" onchange="revSetTarget(this.value)">${opts}</select>
      </div>
      <div class="kpi gold"><div class="v">${fmtMoney(d.total ?? 0, target)}</div><div class="l">${T("إجمالي الفترة")} (${esc(target)})</div></div>
      <div style="margin-top:8px">
        ${lines.map((x) => `<div style="display:flex;justify-content:space-between;gap:8px;padding:7px 2px;border-bottom:1px solid #202020;flex-wrap:wrap">
          <b>${esc(x.currency)} <span class="muted">${fmtMoney(x.amount)}</span></b>
          <b style="color:#7fff8b">${x.converted == null ? T("بلا سعر") : "≈ " + fmtMoney(x.converted, target)}</b>
        </div>`).join("") || `<div class="empty">${T("لا توجد إيرادات")}</div>`}
      </div>
      ${unconv.length ? `<div class="muted" style="font-size:11px;margin-top:6px">${T("غير مشمولة في الإجمالي (لا سعر صرف)")}: ${esc(unconv.map((x) => x.currency).join(", "))}</div>` : ""}
      <div class="muted" style="font-size:11px;margin-top:6px">${T("المصدر")}: ${esc(meta.global_source || "—")} · ${esc(meta.yemen_source || "—")}</div>`;
  } catch (e) {
    box.innerHTML = `<div class="empty">${esc(e.message)}</div>`;
  }
}

/* ── Subscriptions ── */
// Default view is pending review; the API uses the same default.
// Source switches dataset: manual requests (as before) vs automatic Stripe.
let subFilter = { status: "pending", from: "", to: "", source: "requests" };
const PLAN_AR = { personal: "شخصية", business: "أعمال", premium: "أعمال + شخصي", trial: "تجريبي", free: "مجاني" };
async function renderSubscriptions(c, params) {
  const box = `
    <div class="card"><h3><span class="dot"></span>تصفية الطلبات</h3>
      <div class="filterbar">
        <select id="fSource" onchange="subFilter.source=this.value;renderSubscriptions($('#content'),paramsOpen())">
          <option value="requests">يدوي (طلبات)</option>
          <option value="stripe">تلقائي (Stripe) 💳</option>
        </select>
        <select id="fStatus" onchange="subFilter.status=this.value;renderSubscriptions($('#content'),paramsOpen())">
          <option value="all">كل الحالات</option>
          <option value="pending">قيد الانتظار</option>
          <option value="approved">تم الاعتماد</option>
          <option value="rejected">مرفوض</option>
          <option value="cancelled">ملغي</option>
          <option value="deleted">محذوف</option>
        </select>
        <input type="date" id="fFrom" title="من تاريخ" onchange="subFilter.from=this.value;renderSubscriptions($('#content'),paramsOpen())">
        <span class="muted">إلى</span>
        <input type="date" id="fTo" title="إلى تاريخ" onchange="subFilter.to=this.value;renderSubscriptions($('#content'),paramsOpen())">
        <button class="btn" onclick="subFilter={status:'pending',from:'',to:'',source:'requests'};renderSubscriptions($('#content'))">إعادة تعيين</button>
      </div>
    </div>
    <div class="user-card-grid" id="subRows"></div>`;
  c.innerHTML = box;
  if (params?.open) { subFilter.status = "pending"; }
  $("#fSource").value = subFilter.source || "requests";
  $("#fStatus").value = subFilter.status || "all";
  if (subFilter.from) $("#fFrom").value = subFilter.from;
  if (subFilter.to) $("#fTo").value = subFilter.to;
  if ((subFilter.source || "requests") === "stripe") {
    await renderStripeSubscriptions();
    return;
  }
  const q = new URLSearchParams();
  q.set("status", subFilter.status || "pending");
  if (subFilter.from) q.set("from", subFilter.from);
  if (subFilter.to) q.set("to", subFilter.to);
  try {
    const r = await api(`admin/subscription-requests?${q.toString()}`);
    const rows = r.data?.requests || r.data || [];
    $("#subRows").innerHTML = rows.length
      ? rows.map((x) => {
          const name = x.user_name || "—";
          const serial = String(x.id || "").slice(0, 8);
          return `<div class="user-card" onclick="openSubscription('${x.id}')" role="button" tabindex="0">
            <div class="uc-avatar">${esc(name.charAt(0))}</div>
            <div class="uc-info">
              <div class="uc-name">${esc(name)}</div>
              <div class="uc-serial">${esc(planNameAr(x.plan_name))} · ${fmtDate(x.created_at)}</div>
            </div>
            <div style="display:flex;align-items:center;gap:8px;flex:0 0 auto">
              ${badge(x.status)}
              <span class="uc-arrow">←</span>
            </div>
          </div>`;
        }).join("")
      : `<div class="empty">${uiEmpty("subscriptions", "لا توجد طلبات اشتراك" + (subFilter.status ? " بهذه الحالة" : ""), "")}</div>`;
    if (params?.open) { $("#fStatus").value = subFilter.status || "pending"; if (rows.some((x) => x.id === params.open)) openSubscription(params.open); }
    wrapTables();
  } catch (e) { $("#subRows").innerHTML = `<tr><td colspan="8" class="empty">${esc(e.message)}</td></tr>`; }
}
function paramsOpen() { return { open: null }; }

/* ── Stripe auto-approved subscriptions (paid card invoices) ── */
async function renderStripeSubscriptions() {
  const box = $("#subRows");
  try {
    const r = await api(`admin/subscription-invoices?status=paid&payment_method=stripe`);
    const rows = r.data || [];
    window.__stripeInvs = rows;
    box.innerHTML = rows.length
      ? rows.map((x) => {
          const name = x.organization_name || x.user_email || "—";
          const serial = String(x.invoice_number || "").slice(0, 14);
          return `<div class="user-card" onclick="openStripeInvoice('${x.id}')" role="button" tabindex="0">
            <div class="uc-avatar">💳</div>
            <div class="uc-info">
              <div class="uc-name">${esc(name)}</div>
              <div class="uc-serial">${esc(PLAN_AR[x.plan_name] || x.plan_name || "")} · ${fmtMoney(x.amount, x.currency)} · ${fmtDate(x.created_at)}</div>
            </div>
            <div style="display:flex;align-items:center;gap:8px;flex:0 0 auto">
              <span class="muted" style="font-size:11px">#${esc(serial)}</span>
              <span class="uc-arrow">←</span>
            </div>
          </div>`;
        }).join("")
      : `<div class="empty">${uiEmpty("subscriptions", "لا توجد اشتراكات تلقائية مدفوعة", "")}</div>`;
    wrapTables();
  } catch (e) { box.innerHTML = `<tr><td colspan="8" class="empty">${esc(e.message)}</td></tr>`; }
}

async function openStripeInvoice(id) {
  try {
    const rows = window.__stripeInvs || [];
    const x = rows.find((v) => String(v.id) === String(id));
    if (!x) { toast("الفاتورة غير موجودة", true); return; }
    window.__curStripeInv = x;
    const days = x.period === "monthly" ? 30 : 365;
    $("#modalBox").className = "modal-box wide";
    $("#modalBox").innerHTML = `<h3>اشتراك تلقائي (Stripe) 💳</h3>
      <div class="req-head">
        <div class="uc-avatar">💳</div>
        <div class="uc-info">
          <div class="uc-name">${esc(x.organization_name || "—")}</div>
          <div class="uc-serial">${esc(x.user_email || "")} · #${esc(String(x.invoice_number || "").slice(0, 14))}</div>
        </div>
      </div>
      <div class="grid2">
        <div class="mfield"><label>الباقة</label><div><b>${esc(PLAN_AR[x.plan_name] || x.plan_name || "—")}</b></div></div>
        <div class="mfield"><label>المدة</label><div><b>${esc(periodAr(x.period))}</b></div></div>
        <div class="mfield"><label>المبلغ المحصّل</label><div><b>${fmtMoney(x.amount, x.currency)}</b></div></div>
        <div class="mfield"><label>البطاقة</label><div><b>${esc((x.card_brand || "—").toUpperCase())}</b></div></div>
        <div class="mfield"><label>بداية الاشتراك</label><div><b>${fmtDate(x.subscription_start_date)}</b></div></div>
        <div class="mfield"><label>نهاية الاشتراك</label><div><b>${fmtDate(x.subscription_end_date)}</b></div></div>
      </div>
      <div class="msg-quote">Stripe ID: ${esc(String(x.provider_payment_id || "—").slice(0, 32))}</div>
      <div class="card"><h3><span class="dot"></span>إدارة الاشتراك</h3>
        <div class="filterbar">
          <select id="stAction">
            <option value="extend">تمديد (إضافة أيام)</option>
            <option value="renew">تجديد (إعادة تفعيل)</option>
            <option value="cancel">إلغاء / إيقاف الاشتراك</option>
            <option value="change_plan">تغيير الباقة</option>
          </select>
          <input id="stDays" type="number" value="${days}" title="الأيام" style="max-width:110px">
          <select id="stPlan">
            <option value="personal">شخصي</option>
            <option value="business">أعمال</option>
            <option value="premium">أعمال + شخصي</option>
          </select>
          <button class="btn" onclick="stripeSubAction()">تنفيذ</button>
        </div>
      </div>
      <div class="m-actions"><button class="btn ghost" onclick="closeModal()">إغلاق</button></div>`;
    try { $("#stPlan").value = x.plan_name || "personal"; } catch (e) {}
    openModal();
  } catch (e) { toast(e.message, true); }
}

async function stripeSubAction() {
  const x = window.__curStripeInv || {};
  if (!x.organization_id) { toast("لا توجد منظمة مرتبطة", true); return; }
  const action = $("#stAction").value;
  const body = { action };
  if (action === "extend") body.days = parseInt($("#stDays").value, 10) || 30;
  if (action === "renew") {
    body.action = "activate";
    body.days = parseInt($("#stDays").value, 10) || (x.period === "monthly" ? 30 : 365);
    body.plan_name = $("#stPlan").value || x.plan_name;
  }
  if (action === "change_plan") body.plan_name = $("#stPlan").value;
  try {
    await api(`admin/orgs/${x.organization_id}/subscription`, { method: "PUT", body });
    toast("تم تنفيذ الإجراء");
    closeModal();
    await renderStripeSubscriptions();
  } catch (e) { toast(e.message, true); }
}

async function openSubscription(id) {
  try {
    const r = await api(`admin/subscription-requests/${id}`);
    const x = r.data || {};
    const req = x.request || x;
    window.__curReq = req;
    const proofs = (req.proof_images && req.proof_images.length ? req.proof_images
      : (req.proof_image_url ? [req.proof_image_url] : []));
    const statusIsPending = req.status === "pending";
    const amountStr = req.currency
      ? `${fmtMoney(req.amount, req.currency)}`
      : fmtMoney(req.amount, "SAR");
    const proofHtml = proofs.length
      ? `<div class="mfield"><label>سندات الإثبات المرفوعة (${proofs.length}) — اضغط لعرض</label>
          <div class="proof-grid">${proofs.map((u) => {
            const isPdf = /\.pdf$/i.test(u) || /\.pdf$/i.test(decodeURIComponent(u));
            const proxied = "./api/proxy-uploads?u=" + encodeURIComponent(u);
            return `<div class="proof-cell" onclick="openProof('${proxied}')" title="اضغط للعرض بالحجم الكامل" role="button" tabindex="0">
              ${isPdf
                ? `<div style="width:100%;height:100%;display:flex;align-items:center;justify-content:center;flex-direction:column;gap:6px"><span style="font-size:28px">📄</span><span class="pc-type">PDF</span></div>`
                : `<img src="${proxied}" loading="lazy" alt="سند" onerror="if(this.closest('.proof-cell')){this.style.display='none';this.closest('.proof-cell').innerHTML='<div style=width:100%;height:100%;display:flex;align-items:center;justify-content:center;color:#888;font-size:10px>اضغط للعرض</div>';}"><span class="pc-type">صورة</span>`}
            </div>`;
          }).join("")}</div></div>`
      : '<div class="mfield"><label>سندات الإثبات</label><div class="empty" style="padding:14px">لم يرفع المستخدم أي سندات</div></div>';
    $("#modalBox").className = "modal-box wide";
    $("#modalBox").innerHTML = `
      <div class="modal-head-row">
        <button class="back-btn" onclick="closeModal();go('subscriptions')" title="الرجوع لقائمة الطلبات">→</button>
        <h3 style="flex:1;min-width:0">تفاصيل طلب الاشتراك</h3>
        ${badge(req.status)}
      </div>
      <div class="req-head">
        <div class="rh-user">
          <div class="avatar">${esc((req.user_name || "؟").charAt(0))}</div>
          <div>
            <b>${esc(req.user_name || "—")}</b>
            <div class="muted">${esc(req.user_email || "—")}</div>
          </div>
        </div>
        <span class="req-id" title="معرّف الطلب">${esc(String(req.id || "").slice(0, 8))}</span>
      </div>
      <div class="grid2">
        <div class="sub-detail"><div class="k">الباقة / نوع الاشتراك</div><div class="v rtl">${esc(planNameAr(req.plan_name))}</div></div>
        <div class="sub-detail"><div class="k">فترة الاشتراك</div><div class="v rtl">${periodAr(req.period)}</div></div>
        <div class="sub-detail"><div class="k">قيمة الطلب</div><div class="req-amount">${amountStr}</div></div>
        <div class="sub-detail"><div class="k">الحالة</div><div class="v rtl">${badge(req.status)}</div></div>
        <div class="sub-detail"><div class="k">رقم الهاتف</div><div class="v" dir="ltr">${esc(req.user_phone || "—")}</div></div>
        <div class="sub-detail"><div class="k">البريد الإلكتروني</div><div class="v">${esc(req.user_email || "—")}</div></div>
        <div class="sub-detail"><div class="k">المنظمة</div><div class="v rtl">${esc(req.org_name || "—")}</div></div>
        <div class="sub-detail"><div class="k">تاريخ الطلب</div><div class="v">${fmtDate(req.created_at)}</div></div>
      </div>
      <div class="mfield" style="margin-top:14px"><label>ملاحظة / رسالة المستخدم</label>
        <div class="msg-quote">${esc(req.message || "لا توجد رسالة")}</div></div>
      ${req.status === "rejected" && req.rejection_reason
        ? `<div class="mfield"><label>سبب الرفض</label><div class="msg-quote" style="border-right-color:var(--danger);color:#ff8a80">${esc(req.rejection_reason)}</div></div>`
        : ""}
      ${proofHtml}
      <div class="m-actions" id="subActions"></div>`;
    const a = $("#subActions");
    if (req.status === "pending") {
      a.innerHTML = `
        <button class="btn" onclick="approveFlow('${id}')">اعتماد الاشتراك وتفعيله</button>
        <button class="btn ghost" onclick="askReject('${id}')">رفض مع ذكر السبب</button>`;
    } else if (req.status === "approved") {
      a.innerHTML = `<button class="btn ghost" onclick="extendSubscription('${id}')">تمديد الاشتراك</button>
        <button class="btn ghost" onclick="cancelSubscription('${id}')">إلغاء الاشتراك</button>`;
    } else {
      a.innerHTML = `<button class="btn ghost" onclick="closeModal()">إغلاق</button>`;
    }
    openModal();
  } catch (e) { toast(e.message, true); }
}

async function askReject(id) {
  $("#modalBox").className = "modal-box wide";
  $("#modalBox").innerHTML = `<h3>رفض طلب الاشتراك</h3>
    <p class="muted" style="margin-bottom:12px">سيصل سبب الرفض مباشرة إلى العميل في التطبيق كإشعار.</p>
    <div class="mfield"><label>سبب الرفض</label><textarea id="rejReason" rows="3" placeholder="اذكر السبب بوضوح ليصل للعميل"></textarea></div>
    <div class="m-actions"><button class="btn danger" onclick="rejectSub('${id}')">رفض نهائي</button><button class="btn ghost" onclick="openSubscription('${id}')">رجوع</button></div>`;
  openModal();
}
async function rejectSub(id) {
  const reason = $("#rejReason").value.trim();
  if (!reason) { toast("يرجى كتابة سبب الرفض ليوصل للعميل", true); return; }
  try { await api(`admin/subscription-requests/${id}/reject`, { method: "PUT", body: { reason } }); toast("تم الرفض — أُرسل السبب للعميل"); closeModal(); renderSubscriptions($("#content")); }
  catch (e) { toast(e.message, true); }
}

async function approveFlow(id) {
  const req = window.__curReq || {};
  try {
    const banks = await api("admin/accounting/banks");
    const list = banks.data?.banks || banks.data || [];
    const plansRes = await api("admin/plans");
    const plans = (plansRes.data?.plans || []).filter((p) => p.is_active && ["personal", "business", "premium"].includes(p.package_type));
    const cur = req.currency || "SAR";
    const amountInit = req.amount ? Number(req.amount) : "";
    $("#modalBox").className = "modal-box wide";
    $("#modalBox").innerHTML = `<h3>اعتماد الاشتراك — تأكيد بيانات الدفع</h3>
      <p class="muted" style="margin-bottom:14px">راجع السند، وحدّد الباقة النهائية والبنك والمبلغ والعملة. لا يتم الاعتماد قبل اكتمال كل البيانات. بعد التأكيد يُفعَّل الاشتراك فوراً ويصل للعميل إشعار + فاتورة.</p>
      <div class="mfield"><label>نوع الباقة النهائي</label><select id="apPlan">${plans.map((p) => `<option value="${p.id}">${esc(p.name)} — ${esc(String(p.price_yearly ?? ""))} ${esc(p.currency || "")}</option>`).join("")}</select></div>
      <div class="grid2">
        <div class="mfield"><label>البنك المستلم (يظهر كل بنك مرة واحدة)</label><select id="apBank" onchange="apBankChanged()">${list.map((b) => `<option value="${b.id}" ${b.currency === cur ? "selected" : ""}>${esc(b.bank_name)}</option>`).join("")}</select></div>
        <div class="mfield"><label>عملة البنك (اختيار من عملات البنك فقط)</label><select id="apCur"></select></div>
      </div>

      <div class="mfield"><label>المبلغ المدفوع (إلزامي)</label>
        <input id="apAmount" type="number" step="0.01" value="${amountInit}" placeholder="أدخل المبلغ المستلم فعلياً">
        <div class="muted" style="margin-top:5px">العملة المطلوبة من العميل: <b>${esc(cur)}</b> — المبلغ الافتراضي: <b>${esc(String(req.amount ?? ""))}</b></div>
      </div>
      <div class="m-actions">
        <button class="btn" onclick="confirmApprove('${id}')">تأكيد الاعتماد والتفعيل</button>
        <button class="btn ghost" onclick="openSubscription('${id}')">رجوع</button>
      </div>`;
    window.__apBanks = list.map((b) => ({ id: b.id, bank_name: b.bank_name, currency: b.currency, currencies: (b.currencies || []).map((c) => c.currency || c) }));
    window.__apCurWanted = cur;
    // Dedupe by bank name: one bank appears once even if several rows exist.
    const seen = new Set();
    const opts = [];
    for (const b of window.__apBanks) {
      const nm = String(b.bank_name || "").trim();
      if (!nm || seen.has(nm)) continue;
      seen.add(nm);
      opts.push(`<option value="${b.id}" ${b.currency === cur ? "selected" : ""}>${esc(nm)}</option>`);
    }
    document.getElementById("apBank").innerHTML = opts.join("");
    openModal();
    apBankChanged();
  } catch (e) { toast(e.message, true); }
}
// Fill the currency dropdown with ONLY the selected bank's currencies
// (union across same-name rows), as a SELECT — no typing.
function apBankChanged() {
  const sel = document.getElementById("apBank");
  const curSel = document.getElementById("apCur");
  if (!sel || !curSel) return;
  const chosen = (window.__apBanks || []).find((b) => String(b.id) === String(sel.value));
  const nm = chosen ? String(chosen.bank_name || "") : "";
  const sameName = (window.__apBanks || []).filter((b) => String(b.bank_name || "") === nm);
  const set = new Set();
  for (const b of sameName.length ? sameName : (chosen ? [chosen] : [])) {
    if (b.currency) set.add(String(b.currency).toUpperCase());
    for (const c of (b.currencies || [])) if (c) set.add(String(c).toUpperCase());
  }
  const curs = set.size ? [...set] : ["SAR"];
  const wanted = String(window.__apCurWanted || "").toUpperCase();
  curSel.innerHTML = curs.map((c) => `<option value="${c}" ${c === wanted ? "selected" : ""}>${c}</option>`).join("");
  curSel.onchange = apCurChanged;
  apCurChanged();
}
// When the currency changes, point the bank value at the same-name row
// that actually holds that currency so the backend validation passes.
function apCurChanged() {
  const sel = document.getElementById("apBank");
  const curSel = document.getElementById("apCur");
  if (!sel || !curSel || !curSel.value) return;
  const cur = String(curSel.value).toUpperCase();
  const chosen = (window.__apBanks || []).find((b) => String(b.id) === String(sel.value));
  const nm = chosen ? String(chosen.bank_name || "") : "";
  const row = (window.__apBanks || []).find((b) => {
    if (String(b.bank_name || "") !== nm) return false;
    const has = new Set([String(b.currency || "").toUpperCase(), ...((b.currencies || []).map((c) => String(c).toUpperCase()))]);
    return has.has(cur);
  });
  if (row) sel.value = row.id;
}
async function confirmApprove(id) {
  const bankId = $("#apBank").value;
  const planId = $("#apPlan").value;
  const amountRaw = ($("#apAmount").value || "").trim();
  const amount = amountRaw === "" ? null : parseFloat(amountRaw);
  const currency = ($("#apCur").value || "").trim().toUpperCase() || undefined;
  if (!bankId) { toast("يجب اختيار الحساب البنكي", true); return; }
  if (!planId) { toast("يجب اختيار نوع الباقة النهائي", true); return; }
  if (amount === null || !(amount > 0)) { toast("يجب إدخال المبلغ المدفوع (أكبر من صفر)", true); return; }
  if (!currency) { toast("يجب إدخال العملة", true); return; }
  try {
    await api(`admin/subscription-requests/${id}/approve`, { method: "PUT", body: { bank_account_id: bankId, plan_id: planId, currency, amount } });
    toast("تم اعتماد الاشتراك وتفعيله — أُرسل إشعار وفاتورة للعميل");
    closeModal(); renderSubscriptions($("#content"));
  } catch (e) { toast(e.message, true); }
}
async function cancelSubscription(id) {
  uiConfirm(T("إلغاء الاشتراك"), T("إلغاء اشتراك هذا المستخدم؟"), async () => {
    try { await api(`admin/subscription-requests/${id}/cancel-subscription`, { method: "PUT" }); toast("تم إلغاء الاشتراك"); closeModal(); renderSubscriptions($("#content")); }
    catch (e) { toast(e.message, true); }
  }, { danger: true });
}
async function extendSubscription(id) {
  uiPrompt(T("تمديد الاشتراك"), T("عدد الأيام للتمديد:"), 30, async (days) => {
    try { await api(`admin/subscription-requests/${id}/extend`, { method: "POST", body: { days: parseInt(days, 10) } }); toast("تم التمديد"); closeModal(); renderSubscriptions($("#content")); }
    catch (e) { toast(e.message, true); }
  });
}

/* ── Users ── */
let userFilter = { status: "" };
async function renderUsers(c) {
  c.innerHTML = `
    <div class="filterbar">
      <input id="uSearch" placeholder="${T("بحث بالاسم أو البريد…")}" onkeydown="if(event.key==='Enter')renderUsersP(1)">
      <select id="uStatus" onchange="userFilter.status=this.value;renderUsersP(1)">
        <option value="">${T("كل الحالات")}</option>
        <option value="active">${T("نشط")}</option>
        <option value="inactive">${T("غير نشط")}</option>
        <option value="pending">${T("قيد الانتظار")}</option>
        <option value="banned">${T("موقوف")}</option>
        <option value="expired">${T("منتهي الاشتراك")}</option>
      </select>
      <button class="btn" onclick="renderUsersP(1)">${T("بحث")}</button>
    </div>
    <div class="user-card-grid" id="uRows"></div>`;
  await renderUsersP(1);
}
async function renderUsersP(page) {
  const q = $("#uSearch")?.value || "";
  const params = new URLSearchParams({ page, per_page: 25 });
  if (q) params.set("search", q);
  if (userFilter.status) params.set("status", userFilter.status);
  try {
    const r = await api(`admin/users?${params.toString()}`);
    const list = (r.data?.users || r.data?.items || []);
    const rows = list.map((u) => {
      const name = u.full_name || u.name || "—";
      const serial = String(u.id || "").slice(0, 8);
      return `<div class="user-card" onclick="openUser('${u.id}')" role="button" tabindex="0">
        <div class="uc-avatar">${esc(name.charAt(0))}</div>
        <div class="uc-info">
          <div class="uc-name">${esc(name)}</div>
          <div class="uc-serial">#${esc(serial)}</div>
        </div>
        <div class="uc-arrow">←</div>
      </div>`;
    }).join("");
    $("#uRows").innerHTML = rows || `<div class="empty">${uiEmpty("users", "لا يوجد مستخدمون", "جرّب تعديل البحث أو الفلاتر")}</div>`;
  } catch (e) { $("#uRows").innerHTML = `<div class="empty">${esc(e.message)}</div>`; }
}
async function openUser(id) {
  try {
    const r = await api(`admin/users/${id}`);
    const u = r.data || {};
    window.__curUser = u;
    $("#modalBox").className = "modal-box wide";
    $("#modalBox").innerHTML = `
      <div style="height:20px"></div>
      <div class="modal-head-row"><button class="back-btn" onclick="closeModal()">✕</button><h3>${T("تفاصيل المستخدم")}</h3></div>
      <div class="tabs" id="uTabs">
        <button class="tab-btn on" data-t="info" onclick="userTab('info',this)">${T("المعلومات")}</button>
        <button class="tab-btn" data-t="sub" onclick="userTab('sub',this)">${T("الاشتراك")}</button>
        <button class="tab-btn" data-t="actions" onclick="userTab('actions',this)">${T("إجراءات")}</button>
      </div>
      <div id="uPanel"></div>`;
    openModal();
    userTab("info");
  } catch (e) { toast(e.message, true); }
}
function userTab(t) {
  const u = window.__curUser || {};
  const sub = u.subscription || {};
  const daysLeft = sub.end_date ? Math.max(0, Math.floor((new Date(sub.end_date) - new Date()) / 86400000)) : null;
  const endExpired = sub.end_date && new Date(sub.end_date) < new Date();
  $$("#uTabs .tab-btn").forEach((b) => b.classList.toggle("on", b.getAttribute("data-t") === t));
  const panel = $("#uPanel");
  if (t === "info") {
    panel.innerHTML = `
      <div class="detail-grid">
        <div><div class="k">${T("الاسم")}</div><div class="v">${esc(u.full_name || u.name)}</div></div>
        <div><div class="k">${T("البريد")}</div><div class="v" style="direction:ltr;text-align:start">${esc(u.email)}</div></div>
        <div><div class="k">${T("الهاتف")}</div><div class="v" style="direction:ltr;text-align:start">${esc(u.phone || "—")}</div></div>
        <div><div class="k">${T("حالة التحقق")}</div><div class="v">${u.email_verified ? `<span class="badge approved">✓ ${T("متحقق")}</span>` : `<span class="badge pending">${T("غير متحقق")}</span>`}</div></div>
        <div><div class="k">${T("تاريخ الإنشاء")}</div><div class="v">${fmtDate(u.created_at)}</div></div>
        <div><div class="k">${T("آخر دخول")}</div><div class="v">${fmtDate(u.last_login_at)}</div></div>
      </div>`;
  } else if (t === "sub") {
    const tint = sub.status === "active" ? "ok" : (endExpired || sub.status === "cancelled" ? "danger" : "warn");
    panel.innerHTML = `
      <div class="card tint-${sub.status === "active" ? "ok" : (endExpired ? "danger" : "warn")}" style="padding:14px">
        <div class="sub-summary">
          <div class="sub-cell"><div class="k">${T("الباقة")}</div><div class="v">${esc(planNameAr(sub.plan)) || "—"}</div></div>
          <div class="sub-cell"><div class="k">${T("الحالة")}</div><div class="v ${tint}">${esc(sub.status || "—")}</div></div>
          <div class="sub-cell"><div class="k">${T("تاريخ البداية")}</div><div class="v">${fmtDate(sub.start_date)}</div></div>
          <div class="sub-cell"><div class="k">${T("تاريخ الانتهاء")}</div><div class="v ${endExpired ? "danger" : ""}">${fmtDate(sub.end_date)}</div></div>
          <div class="sub-cell"><div class="k">${T("الأيام المتبقية")}</div><div class="v">${daysLeft !== null ? daysLeft : "—"}</div></div>
        </div>
      </div>
      <div class="card" style="padding:14px">
        <div class="mfield"><label>${T("الإجراء على الاشتراك")}</label>
          <select id="ubAction">
            <option value="extend">${T("تمديد (إضافة أيام)")}</option>
            <option value="activate">${T("تفعيل / إعادة تفعيل")}</option>
            <option value="cancel">${T("إلغاء / إيقاف الاشتراك")}</option>
            <option value="change_plan">${T("تغيير الباقة")}</option>
          </select></div>
        <div class="grid2">
          <div class="mfield"><label>${T("الأيام (للتمديد/التفعيل)")}</label><input id="ubDays" type="number" value="30" min="1"></div>
          <div class="mfield"><label>${T("الباقة (لتغيير الخطة)")}</label>
            <select id="ubPlan"><option value="personal">${T("شخصي")}</option><option value="business">${T("أعمال")}</option><option value="premium">${T("أعمال + شخصي")}</option></select></div>
        </div>
        <button class="btn" onclick="userSubAction()">${T("تنفيذ")}</button>
      </div>`;
  } else if (t === "actions") {
    panel.innerHTML = `
      <div class="m-actions">
        ${u.email_verified ? "" : `<button class="btn" onclick="verifyUser('${u.id}',true)">${T("اعتماد الدخول")}</button>`}
        <button class="btn ${u.status === "banned" ? "ok" : "danger"}" onclick="banUser('${u.id}',${u.status === "banned" ? "false" : "true"})">${u.status === "banned" ? T("رفع الحظر") : T("حظر المستخدم")}</button>
        ${u.is_platform_admin ? `<button class="tbtn norm" onclick="closeModal();go('staff')">${T("إدارة الصلاحيات")}</button>` : ""}
      </div>`;
  }
}
async function userSubAction() {
  const u = window.__curUser || {};
  if (!u.organization_id) { toast("لا توجد منظمة مرتبطة بهذا المستخدم", true); return; }
  const action = $("#ubAction").value;
  const body = { action };
  if (action === "extend" || action === "activate") body.days = parseInt($("#ubDays").value, 10) || 30;
  if (action === "activate" || action === "change_plan") body.plan_name = $("#ubPlan").value;
  try {
    await api(`admin/orgs/${u.organization_id}/subscription`, { method: "PUT", body });
    toast("تم تحديث الاشتراك");
    closeModal(); renderUsers($("#content"));
  } catch (e) { toast(e.message, true); }
}
async function verifyUser(id, v) {
  try { await api(`admin/users/${id}`, { method: "PUT", body: { email_verified: v } }); toast("تم اعتماد الحساب — يدخل المستخدم دون كود"); closeModal(); }
  catch (e) { toast(e.message, true); }
}
async function banUser(id, ban) {
  try { await api(`admin/users/${id}`, { method: "PUT", body: { status: ban ? "banned" : "active" } }); toast(ban ? "تم حظر المستخدم" : "تم رفع الحظر"); closeModal(); renderUsers($("#content")); }
  catch (e) { toast(e.message, true); }
}

/* ── Orgs / trial ── */
async function renderOrgs(c) {
  c.innerHTML = `<div class="card"><table><thead><tr><th>المنظمة</th><th>الخطة</th><th>الحالة</th><th>الأيام المتبقية</th><th></th></tr></thead><tbody id="orgRows"></tbody></table></div>`;
  try {
    const r = await api("admin/orgs");
    const rows = r.data?.organizations || r.data?.items || r.data || [];
    $("#orgRows").innerHTML = rows.length
      ? rows.map((o) => `<tr><td>${esc(o.name)}</td><td>${esc(o.subscription_plan)}</td>
          <td>${badge(o.subscription_status)}</td><td>${o.days_remaining ?? "—"}</td>
          <td><button class="tbtn norm" onclick="orgActions('${o.id}')">إجراءات</button></td></tr>`).join("")
      : '<tr><td colspan="5" class="empty">لا توجد منظمات</td></tr>';
  } catch (e) { c.innerHTML = `<div class="empty">${esc(e.message)}</div>`; }
}
function orgActions(id) {
  $("#modalBox").innerHTML = `<h3>إدارة الاشتراك التجريبي</h3>
    <div class="mfield"><label>الإجراء</label><select id="oaAction">
      <option value="activate">تفعيل الاشتراك / إيقاف التجريبي</option>
      <option value="extend">تمديد</option><option value="cancel">إلغاء</option>
    </select></div>
    <div class="mfield"><label>عدد الأيام (للتمديد)</label><input id="oaDays" type="number" value="30"></div>
    <div class="m-actions"><button class="btn" onclick="orgSubmit('${id}')">تنفيذ</button><button class="btn ghost" onclick="closeModal()">إغلاق</button></div>`;
  openModal();
}
async function orgSubmit(id) {
  const action = $("#oaAction").value;
  const days = parseInt($("#oaDays").value, 10) || 30;
  try { await api(`admin/orgs/${id}/subscription`, { method: "PUT", body: { action, days } }); toast("تم التحديث"); closeModal(); renderOrgs($("#content")); }
  catch (e) { toast(e.message, true); }
}

/* ── Plans ── */
async function updateFxRates(btn) {
  try {
    if (btn) { btn.disabled = true; btn.textContent = "جاري التحديث…"; }
    const r = await api("admin/exchange-rates/refresh", { method: "POST", body: {} });
    const d = r.data || {};
    const parts = [];
    if (d.global_source) parts.push(`العالم: ${d.global_source}`);
    if (d.yemen_source) parts.push(`اليمن: ${d.yemen_source}`);
    toast(parts.length ? `تم تحديث أسعار الصرف (${parts.join("، ")})` : "تم تحديث أسعار الصرف ✅");
  } catch (e) { toast(e.message, true); }
  finally { if (btn) { btn.disabled = false; btn.textContent = "🔄 تحديث أسعار الصرف"; } }
}
async function loadYerManualRates() {
  try {
    const r = await api("admin/exchange-rates");
    const rows = r.data || [];
    rows.forEach((x) => {
      const p = x.currency_code === "YER_OLD" ? "sanaa" : (x.currency_code === "YER_NEW" ? "aden" : null);
      if (!p) return;
      if (x.buy_rate > 0) $("#fx_" + p + "_buy").placeholder = x.buy_rate;
      if (x.sell_rate > 0) $("#fx_" + p + "_sell").placeholder = x.sell_rate;
      if (x.average_rate > 0) $("#fx_" + p + "_avg").placeholder = x.average_rate;
    });
  } catch (_) {}
}
async function saveYerManualRate(code, btn) {
  const p = code === "YER_OLD" ? "sanaa" : "aden";
  const buy = parseFloat($("#fx_" + p + "_buy").value);
  const sell = parseFloat($("#fx_" + p + "_sell").value);
  const avg = parseFloat($("#fx_" + p + "_avg").value);
  if (!(buy > 0 && sell > 0 && avg > 0)) { toast("أدخل الشراء والبيع والمتوسط (أكبر من صفر)", true); return; }
  try {
    if (btn) btn.disabled = true;
    await api("admin/exchange-rates", { method: "POST", body: { currency_code: code, base_currency: "USD", buy_rate: buy, sell_rate: sell, average_rate: avg } });
    toast(code === "YER_OLD" ? "تم حفظ سعر صنعاء ✅" : "تم حفظ سعر عدن ✅");
    ["buy", "sell", "avg"].forEach((k) => { $("#fx_" + p + "_" + k).value = ""; });
    loadYerManualRates();
  } catch (e) { toast(e.message, true); }
  finally { if (btn) btn.disabled = false; }
}
async function renderPlans(c) {
  c.innerHTML = `${uiPageHeader("الباقات والأسعار", "الأسعار الرسمية بالدولار الأمريكي ($) — تتحول تلقائياً لكل عملات العالم في التطبيق")}
    <div class="row" style="margin-bottom:14px"><button class="btn" style="width:auto" onclick="updateFxRates(this)">🔄 تحديث أسعار الصرف</button><span class="muted" style="align-self:center">يجلب أحدث الأسعار العالمية + الريال اليمني (صنعاء/عدن)</span></div>
    <div class="card" style="margin-bottom:14px"><h3><span class="dot"></span>أسعار الصرف اليدوية — الريال اليمني مقابل الدولار</h3>
      <p class="muted" style="margin-bottom:12px">تُستخدم هذه الأسعار في عرض الباقات والدفع بالبطاقة. تُكتب القيم كريال مقابل 1 دولار.</p>
      <div class="grid2">
        <div class="mfield"><label>صنعاء (قديم) — شراء / بيع / متوسط</label>
          <div style="display:flex;gap:6px"><input id="fx_sanaa_buy" type="number" placeholder="شراء"><input id="fx_sanaa_sell" type="number" placeholder="بيع"><input id="fx_sanaa_avg" type="number" placeholder="متوسط"></div>
          <button class="tbtn norm" style="margin-top:8px" onclick="saveYerManualRate('YER_OLD', this)">💾 حفظ سعر صنعاء</button></div>
        <div class="mfield"><label>عدن (جديد) — شراء / بيع / متوسط</label>
          <div style="display:flex;gap:6px"><input id="fx_aden_buy" type="number" placeholder="شراء"><input id="fx_aden_sell" type="number" placeholder="بيع"><input id="fx_aden_avg" type="number" placeholder="متوسط"></div>
          <button class="tbtn norm" style="margin-top:8px" onclick="saveYerManualRate('YER_NEW', this)">💾 حفظ سعر عدن</button></div>
      </div>
    </div>
    <div class="plan-card-grid" id="planRows"></div>`;
  try {
    const r = await api("admin/plans");
    const rows = r.data?.plans || [];
    // Preload current discounts so the plan edit modal can prefill them and
    // saving one plan never wipes the discounts of the others.
    try {
      const cr = await api("admin/controls");
      window.__discounts = (cr.data || {}).discounts || {};
    } catch (e) { window.__discounts = window.__discounts || {}; }
    $("#planRows").innerHTML = rows.map((p) => `
        <div class="plan-card ${p.is_active ? "ok" : ""}">
          <div class="pc-name"><b>${esc(p.name)}</b></div>
          <div class="pc-muted muted">${esc(p.subtitle || p.description || "")}</div>
          <div class="pc-price" style="direction:ltr;text-align:start;font-size:18px;font-weight:800">${fmtMoney(p.price_yearly, p.currency)} <span class="muted" style="font-size:11px">/ ${T("سنوي")}</span></div>
          <div class="pc-peiod muted">${T("شهري")}: ${fmtMoney(p.price_monthly, p.currency)}</div>
          <div class="pc-ar">
            <span class="badge ${p.is_active ? "approved" : "rejected"}">${p.is_active ? T("نشطة") : T("معطلة")}</span>
            <span class="tag">${esc(p.currency || "SAR")}</span>
          </div>
          <div style="margin-top:4px">
            <button class="tbtn norm" onclick='editPlan(${JSON.stringify(JSON.stringify(p)).replace(/</g, "\\u003c")})'>${T("تعديل")}</button>
          </div>
        </div>`).join("")
      || `<div class="empty">${uiEmpty("plans", "لا توجد باقات", "")}</div>`;
      wrapTables();
      loadYerManualRates();
  } catch (e) { $("#planRows").innerHTML = `<div class="empty">${esc(e.message)}</div>`; }
}
function editPlan(pJson) {
  let p = {};
  try { p = typeof pJson === "string" ? JSON.parse(pJson) : pJson; } catch (e) {}
  const planKey = (p.package_type || String(p.id) || "").toString();
  window.__activePlanKey = planKey;
  const disc = (window.__discounts || {})[planKey] || {};
  $("#modalBox").innerHTML = `<h3>تعديل الباقة</h3>
      <div class="mfield"><label>الاسم</label><input id="pName" value="${esc(p.name)}"></div>
      <div class="mfield"><label>الاسم (إنجليزي)</label><input id="pNameEn" value="${esc(p.name_en || "")}"></div>
      <div class="grid2"><div class="mfield"><label>السعر السنوي ($) بالدولار الأمريكي</label><input id="pYear" type="number" step="0.01" value="${p.price_yearly || 0}"></div>
      <div class="mfield"><label>السعر الشهري ($) بالدولار الأمريكي</label><input id="pMonth" type="number" step="0.01" value="${p.price_monthly || 0}"></div></div>
      <div class="mfield"><label>العملة الرسمية (ثابتة)</label><input id="pCur" value="USD" disabled><div class="muted" style="margin-top:4px">الدولار هو العملة الرسمية — يتحول السعر تلقائياً لكل عملات العالم في التطبيق</div></div>
      <div class="card" style="border:1px solid var(--border);padding:10px;margin-top:6px"><h3 style="font-size:13px;color:var(--text)">💰 الخصم الاختياري على الباقة</h3>
        <div class="grid2">
          <div class="mfield"><label>الخصم % (0 = بدون خصم)</label><input id="pDiscPct" type="number" min="0" max="90" value="${disc.percent || 0}"></div>
          <div class="mfield"><label>تاريخ بدء الخصم</label><input type="date" id="pDiscStart" value="${esc(disc.starts_on || "")}"></div>
        </div>
        <div class="mfield"><label>تاريخ انتهاء الخصم (بعدها يعود السعر الأصلي)</label><input type="date" id="pDiscEnd" value="${esc(disc.ends_on || "")}"></div>
      </div>
      <div class="mfield"><label>الوصف</label><textarea id="pDesc" rows="2">${esc(p.description || "")}</textarea></div>
      <div class="m-actions"><button class="btn" onclick="savePlan('${p.id}','${esc(p.currency || "SAR")}')">حفظ</button><button class="btn ghost" onclick="closeModal()">إغلاق</button></div>`;
  openModal();
}
async function savePlan(id, cur) {
  try {
    await api(`admin/plans/${id}`, { method: "PUT", body: {
      name: $("#pName").value, name_en: $("#pNameEn").value,
      price_yearly: parseFloat($("#pYear").value) || 0, price_monthly: parseFloat($("#pMonth").value) || 0,
      currency: "USD", description: $("#pDesc").value,
    } });
    // Persist the optional discount (per plan) through platform controls.
    const pct = parseInt($("#pDiscPct")?.value) || 0;
    let disc = window.__discounts || {};
    const key = (window.__activePlanKey || mapPlanKey(id) || "").toString();
    if (pct > 0) {
      disc[key] = { percent: Math.min(90, pct), starts_on: $("#pDiscStart")?.value || "", ends_on: $("#pDiscEnd")?.value || "" };
    } else {
      delete disc[key];
    }
    await api("admin/controls", { method: "PUT", body: { discounts: disc } });
    window.__discounts = disc;
    toast("تم حفظ الباقة مع الخصم — طُبق فوراً على التطبيق"); closeModal(); renderPlans($("#content"));
  } catch (e) { toast(e.message, true); }
}
function mapPlanKey(id) {
  if (!id) return "";
  const s = String(id).toLowerCase();
  if (s.includes("personal") || s.includes("شخصي")) return "personal";
  if (s.includes("business") || s.includes("أعمال") && !s.includes("شخصي")) return "business";
  if (s.includes("premium") || s.includes("ذهبي")) return "premium";
  return s;
}

/* ── Accounting (banks + operations) ── */
let acct = { bank: "", currency: "" };
let bankCurSel = {};    // bank id -> selected currency code (in-card switcher)
let bankDeckIdx = 0;    // active card in the stacked deck
function bankPick(id, cur) { bankCurSel[id] = cur; renderAccounting($("#content")); }
function bankDeckSync() {
  const vp = $("#bankViewport");
  if (!vp) return;
  const cards = Array.from(vp.querySelectorAll(".bank-pro"));
  if (!cards.length) return;
  const mid = vp.scrollLeft + vp.clientWidth / 2;
  let best = 0, bestDist = 1e12;
  cards.forEach((el, i) => {
    const c = el.offsetLeft + el.clientWidth / 2;
    const dist = Math.abs(c - mid);
    if (dist < bestDist) { bestDist = dist; best = i; }
  });
  bankDeckIdx = best;
  cards.forEach((el, i) => el.classList.toggle("active", i === best));
  $$("#bankDots .bdot").forEach((d, i) => d.classList.toggle("on", i === best));
  const cnt = $("#bankCount");
  if (cnt) cnt.textContent = `${best + 1} / ${cards.length}`;
  const cur = $("#bankDeckCur");
  const rows = window.__bankRows || [];
  const b = rows[best];
  if (cur && b) {
    const curs = (b.currencies && b.currencies.length) ? b.currencies : [{ currency: b.currency }];
    const sel = bankCurSel[b.id] || (curs[0] && curs[0].currency) || b.currency;
    cur.textContent = sel;
  }
}
function bankDeckGo(i) {
  const vp = $("#bankViewport");
  if (!vp) return;
  const cards = vp.querySelectorAll(".bank-pro");
  if (!cards.length) return;
  const n = cards.length;
  bankDeckIdx = ((i % n) + n) % n;
  cards[bankDeckIdx].scrollIntoView({ behavior: "smooth", inline: "center", block: "nearest" });
  setTimeout(bankDeckSync, 350);
}
function bankDeckCurStep(dir) {
  const rows = window.__bankRows || [];
  const b = rows[bankDeckIdx];
  if (!b) return;
  bankPickStep(b.id, dir);
}
function bankPickStep(id, dir) {
  const order = (window.__bankCurs && window.__bankCurs[id]) || [];
  if (!order.length) return;
  let idx = order.indexOf(bankCurSel[id] || order[0]);
  if (idx < 0) idx = 0;
  idx = (idx + dir + order.length) % order.length;
  bankCurSel[id] = order[idx];
  renderAccountingData();
}
async function renderAccounting(c) {
  c.innerHTML = `
    ${uiPageHeader("المحاسبة الإدارية", "البنوك والعمليات وصرفيات الإدارة")}
    <div class="row" style="grid-template-columns:repeat(auto-fill,minmax(160px,1fr))">
      <button class="btn" onclick="newBank()">+ ${T("إضافة بنك")}</button>
      <button class="btn ghost" onclick="newOperation('deposit')">+ ${T("إيداع")}</button>
      <button class="btn ghost" onclick="newOperation('withdraw')">− ${T("صرفية")}</button>
    </div>
    <div class="card"><h3><span class="dot"></span>${T("الحسابات البنكية")}</h3>
      <div id="bankGrid"></div>
    </div>
    <div class="card"><h3><span class="dot"></span>${T("العمليات الأخيرة")}</h3>
      <div class="tx-list" id="txList"></div>
    </div>`;
  await renderAccountingData();
}
function txRow(t) {
  const out = t.kind === "withdraw";
  const rev = t.kind === "revenue";
  const icCls = out ? "out" : (rev ? "info" : "in");
  const amtCls = out ? "out" : "in";
  const label = out ? T("صرفية") : (rev ? T("إيراد اشتراك") : T("إيداع"));
  const badgeTxt = out ? `<span class="badge rejected">${label}</span>` : `<span class="badge approved">${label}</span>`;
  return `<div class="tx-row">
    <div class="tx-ic ${icCls}">${out ? "▾" : "▴"}</div>
    <div class="tx-mid">
      <div class="tx-title">${esc(t.title || label)}</div>
      <div class="tx-sub">${esc(t.sub || "—")}${t.note ? " · " + esc(t.note) : ""} · ${fmtDate(t.at)}</div>
    </div>
    <div class="tx-right">
      <div class="tx-amt ${amtCls}">${out ? "−" : "+"}${fmtMoney(t.amount, t.currency)}</div>
      <div class="tx-badges">${badgeTxt}</div>
    </div>
  </div>`;
}
async function renderAccountingData() {
  try {
    const banks = await api("admin/accounting/banks");
    const entries = await api("admin/accounting/entries?limit=60");
    const ops = await api("admin/accounting/operations?limit=60");
    const bRows = banks.data?.banks || banks.data || [];
    const grid = $("#bankGrid");
    const bankCurs = {};
    window.__bankRows = bRows;
    if (bankDeckIdx >= bRows.length) bankDeckIdx = Math.max(0, bRows.length - 1);
    const cards = bRows.length
      ? bRows.map((b, i) => {
          const curs = (b.currencies && b.currencies.length) ? b.currencies : [{ currency: b.currency, balance: b.balance, opening_balance: b.opening_balance || 0, booked: 0, ops_in: 0, ops_out: 0 }];
          bankCurs[b.id] = curs.map((x) => x.currency);
          const sel = bankCurSel[b.id] || (curs[0] && curs[0].currency) || b.currency;
          const cur = curs.find((x) => x.currency === sel) || curs[0] || { currency: sel, balance: 0, opening_balance: 0, booked: 0, ops_in: 0, ops_out: 0 };
          const sysBadge = b.is_system ? `<span class="bp-sys">${T("نظام")}</span>` : "";
          // Every currency gets its own chip — never one mixed number.
          const chips = curs.map((x) => `<span class="bp-chip${x.currency === cur.currency ? " on" : ""}" onclick="event.stopPropagation();bankPick('${b.id}','${esc(x.currency)}')">${esc(x.currency)}: ${fmtMoney(x.balance, "")}</span>`).join("");
          return `<div class="bank-pro${i === bankDeckIdx ? " active" : ""}" data-name="${esc(b.bank_name)}" onclick="openBankDetail('${b.id}')">
  <div class="bp-top">
    <div><div class="bp-name">${esc(b.bank_name)} ${sysBadge}</div>
      <div class="bp-holder">${esc(b.account_holder_name || "حساب إداري")}${b.account_number ? " · " + esc(b.account_number) : ""}</div></div>
    <div class="bp-bankico"><span class="status-dot ${b.is_active ? "ok" : "muted"}"></span></div>
  </div>
  <div class="bp-balance">
    <div class="lbl">${T("الرصيد")}</div>
    <div class="val">${fmtMoney(cur.balance, cur.currency)}</div>
  </div>
  <div class="bp-chips">${chips}</div>
  <div class="bp-cur-switch">
    <button class="bp-arrow-sm" onclick="event.stopPropagation();bankPickStep('${b.id}',-1)">‹</button>
    <span class="bp-currency">${esc(cur.currency)}</span>
    <button class="bp-arrow-sm" onclick="event.stopPropagation();bankPickStep('${b.id}',1)">›</button>
  </div>
  <div class="bp-foot">
    <button class="tbtn" onclick="event.stopPropagation();newOperation('deposit','${b.id}','${esc(cur.currency)}')">${T("إيداع")}</button>
    <button class="tbtn" onclick="event.stopPropagation();newOperation('withdraw','${b.id}','${esc(cur.currency)}')">${T("صرفية")}</button>
    <button class="tbtn" style="flex:1" onclick="event.stopPropagation();editBank('${b.id}')">${T("تعديل")}</button>
  </div>
</div>`;
        }).join("")
      : "";
    grid.innerHTML = bRows.length
      ? `<div class="bank-stack">
          <div class="bank-deck-top">
            <button class="bp-arrow-sm" onclick="bankDeckCurStep(-1)">‹</button>
            <span class="bank-deck-cur" id="bankDeckCur">—</span>
            <button class="bp-arrow-sm" onclick="bankDeckCurStep(1)">›</button>
          </div>
          <div class="bank-viewport" id="bankViewport" onscroll="bankDeckSync()">${cards}</div>
          <div class="bank-dots" id="bankDots">${bRows.map((_, i) => `<span class="bdot${i === bankDeckIdx ? " on" : ""}" onclick="bankDeckGo(${i})"></span>`).join("")}</div>
          <div class="bank-count" id="bankCount">${bankDeckIdx + 1} / ${bRows.length}</div>
        </div>`
      : `<div class="empty">${uiEmpty("accounting", "لا توجد بنوك بعد", "أضف أول حساب بنكي")}</div>`;
    const vp = $("#bankViewport");
    if (vp) {
      const cards0 = vp.querySelectorAll(".bank-pro");
      if (cards0[bankDeckIdx]) cards0[bankDeckIdx].scrollIntoView({ inline: "center", block: "nearest" });
      setTimeout(bankDeckSync, 60);
    }
    window.__bankCurs = bankCurs;
    // Unify: subscription revenues (entries) + admin deposit/withdraw operations.
    const eRows = (entries.data?.entries || entries.data?.items || entries.data || []).map((e) => ({ kind: "revenue", title: e.plan_name || T("إيراد اشتراك"), sub: e.bank_name || "", amount: Number(e.amount) || 0, currency: e.currency, at: e.created_at, note: e.note || "" }));
    const opList = (ops.data?.operations || ops.data?.items || ops.data || []);
    const oRows = opList.map((o) => ({ kind: o.type === "withdraw" ? "withdraw" : "deposit", title: o.type === "withdraw" ? T("صرفية") : T("إيداع"), sub: o.bank_name || "", amount: Number(o.amount) || 0, currency: o.currency, at: o.created_at, note: o.description || o.person_name || "" }));
    const allTx = eRows.concat(oRows).sort((a, b) => (new Date(b.at || 0)) - (new Date(a.at || 0)));
    const txEl = $("#txList");
    txEl.innerHTML = allTx.length
      ? allTx.map((t) => txRow(t)).join("")
      : `<div class="empty">${uiEmpty("reports", "لا توجد عمليات بعد", "")}</div>`;
    wrapTables();
  } catch (e) {
    const grid = $("#bankGrid"); if (grid) grid.innerHTML = `<div class="empty">${esc(e.message)}</div>`;
    const tx = $("#txList"); if (tx) tx.innerHTML = `<div class="empty">${esc(e.message)}</div>`;
  }
}

/* ── Bank statement page: every operation of one bank ── */
async function openBankDetail(id) {
  const c = $("#content");
  $("#pageTitle").textContent = T("كشف حساب البنك");
  $("#pageSub").textContent = T("كل العمليات والمبالغ الداخلة بتفاصيلها");
  c.innerHTML = uiSkeleton(5);
  try {
    const [banks, entries, ops] = await Promise.all([
      api("admin/accounting/banks"),
      api(`admin/accounting/entries?limit=500&bank_id=${encodeURIComponent(id)}`),
      api(`admin/accounting/operations?limit=500&bank_id=${encodeURIComponent(id)}`),
    ]);
    const bRows = banks.data?.banks || banks.data || [];
    const b = bRows.find((x) => x.id === id);
    if (!b) { c.innerHTML = `<div class="empty">${T("البنك غير موجود")}</div>`; return; }
    const curs = (b.currencies && b.currencies.length) ? b.currencies : [{ currency: b.currency, balance: b.balance, opening_balance: b.opening_balance || 0, booked: 0 }];
    const eRows = (entries.data?.entries || entries.data?.items || entries.data || []).map((e) => ({
      kind: "revenue", title: e.plan_name || T("إيراد اشتراك"),
      user: e.user_name || e.org_name || "", sub: e.bank_name || "",
      amount: Number(e.amount) || 0, currency: e.currency, at: e.created_at,
      note: e.note || "", raw: e,
    }));
    const oRows = ((ops.data?.operations || ops.data?.items || ops.data || [])).map((o) => ({
      kind: o.type === "withdraw" ? "withdraw" : "deposit",
      title: o.type === "withdraw" ? T("صرفية") : T("إيداع"),
      user: o.created_by_name || o.person_name || "",
      sub: o.bank_name || "", amount: Number(o.amount) || 0,
      currency: o.currency, at: o.created_at,
      note: o.description || o.person_name || "", raw: o,
    }));
    const allTx = eRows.concat(oRows).sort((a, b2) => (new Date(b2.at || 0)) - (new Date(a.at || 0)));
    window.__stmtTx = allTx;
    // Per-currency in/out from THIS page's loaded log — never mixed across
    // currencies. Backend `currencies[]` carries opening/booked/ops/balance.
    const inByCur = {};
    const outByCur = {};
    allTx.forEach((t) => {
      const k = (t.currency || "SAR").toUpperCase();
      if (t.kind === "withdraw") outByCur[k] = (outByCur[k] || 0) + t.amount;
      else inByCur[k] = (inByCur[k] || 0) + t.amount;
    });
    const sumRows = curs.map((x) => {
      const k = (x.currency || "").toUpperCase();
      return `<div class="stmt-cur"><span class="cc">${esc(x.currency)}</span>
        <span class="cb">${T("الداخل")}: <b class="ok">+${fmtMoney(inByCur[k] || 0, x.currency)}</b></span>
        <span class="cb">${T("الصرف")}: <b class="danger">−${fmtMoney(outByCur[k] || 0, x.currency)}</b></span></div>`;
    }).join("");
    const sysNote = b.is_system ? `<div class="card tint-info" style="padding:10px 14px">${T("بنك نظامي — يُدار تلقائيًا ولا يمكن حذفه أو تعطيله")}</div>` : "";
    c.innerHTML = `
      <div class="stmt-head">
        <button class="stmt-back" onclick="go('accounting')">→</button>
        <div><h2 style="font-size:var(--fs-lg);font-weight:800">${esc(b.bank_name)}</h2>
        <div class="muted" style="font-size:12px">${esc(b.account_holder_name || "")}${b.account_number ? " · " + esc(b.account_number) : ""}${b.iban ? " · IBAN " + esc(b.iban) : ""}</div></div>
      </div>
      <div class="card tint-ok" style="padding:14px">
        <div class="sub-summary">
          <div class="sub-cell"><div class="k">${T("عدد العمليات")}</div><div class="v">${allTx.length}</div></div>
        </div>
        <div style="margin-top:10px">${sumRows}</div>
      </div>
      ${sysNote}
      <div class="card"><h3><span class="dot"></span>${T("الأرصدة حسب العملة")}</h3>
        ${curs.map((x) => `<div class="stmt-cur"><span class="cc">${esc(x.currency)}</span>
          <span class="cb">${T("افتتاحي")}: <b>${fmtMoney(x.opening_balance, x.currency)}</b></span>
          <span class="cb">${T("محجوز")}: <b>${fmtMoney(x.booked, x.currency)}</b></span>
          <span class="cb">${T("إيداع")}: <b class="ok">+${fmtMoney(x.ops_in || 0, x.currency)}</b></span>
          <span class="cb">${T("صرفية")}: <b class="danger">−${fmtMoney(x.ops_out || 0, x.currency)}</b></span>
          <span class="cb">${T("الرصيد")}: <b>${fmtMoney(x.balance, x.currency)}</b></span></div>`).join("")}
      </div>
      <div class="card"><h3><span class="dot"></span>${T("سجل العمليات")} (${allTx.length})</h3>
        <div id="stmtList">${allTx.length ? allTx.map((t, i) => stmtRow(t, i)).join("") : `<div class="empty">${T("لا توجد عمليات لهذا البنك بعد")}</div>`}</div>
      </div>`;
    wrapTables();
  } catch (e) { c.innerHTML = `<div class="empty">${esc(e.message)}</div>`; }
}
function stmtRow(t, i) {
  const out = t.kind === "withdraw";
  const rev = t.kind === "revenue";
  const icCls = out ? "out" : (rev ? "info" : "in");
  const label = out ? T("صرفية") : (rev ? T("إيراد اشتراك") : T("إيداع"));
  const badgeTxt = out ? `<span class="badge rejected">${label}</span>` : `<span class="badge approved">${label}</span>`;
  return `<div class="stmt-row" onclick="stmtOpDetail(${i})">
    <div class="tx-ic ${icCls}">${out ? "▾" : "▴"}</div>
    <div class="tx-mid" style="flex:1">
      <div class="tx-title">${esc(t.title || label)}</div>
      <div class="stmt-user">${t.user ? "👤 " + esc(t.user) : ""}${t.user && t.at ? " · " : ""}${t.at ? fmtDate(t.at) : ""}</div>
    </div>
    <div class="tx-right" style="text-align:end">
      <div class="tx-amt ${out ? "out" : "in"}">${out ? "−" : "+"}${fmtMoney(t.amount, t.currency)}</div>
      <div class="tx-badges">${badgeTxt}</div>
    </div>
  </div>`;
}
function stmtOpDetail(i) {
  const t = (window.__stmtTx || [])[i];
  if (!t) return;
  const out = t.kind === "withdraw";
  const label = out ? T("صرفية") : (t.kind === "revenue" ? T("إيراد اشتراك") : T("إيداع"));
  $("#modalBox").className = "modal-box wide";
  $("#modalBox").innerHTML = `
    <div style="height:20px"></div>
    <div class="modal-head-row"><button class="back-btn" onclick="closeModal()">✕</button><h3>${esc(t.title || label)}</h3></div>
    <div class="kv"><span class="k">${T("نوع العملية")}</span><span class="v">${label}</span></div>
    <div class="kv"><span class="k">${T("المبلغ")}</span><span class="v" style="color:${out ? "var(--danger)" : "var(--ok)"}">${out ? "−" : "+"}${fmtMoney(t.amount, t.currency)}</span></div>
    <div class="kv"><span class="k">${T("العملة")}</span><span class="v">${esc(t.currency || "—")}</span></div>
    <div class="kv"><span class="k">${T("المستخدم")}</span><span class="v">${esc(t.user || "—")}</span></div>
    <div class="kv"><span class="k">${T("التاريخ والوقت")}</span><span class="v">${t.at ? fmtDate(t.at) : "—"}</span></div>
    <div class="kv"><span class="k">${T("التفاصيل")}</span><span class="v">${esc(t.note || t.sub || "—")}</span></div>`;
  openModal();
}
const CURRENCIES = ["SAR","USD","EUR","YER","YER_OLD","YER_NEW","AED","EGP","KWD","QAR","BHD","OMR","TRY","GBP","INR","CNY"];
function bankChips(){ return CURRENCIES; }
function _curOptions(sel){ return CURRENCIES.map((c) => `<option ${c === sel ? "selected" : ""}>${c}</option>`).join(""); }
function currencyEditorHtml(rows) {
  rows = rows || [{ currency: "SAR", opening_balance: 0 }];
  return `<div id="curRows">${rows.map((r, i) => `<div class="cur-row" style="display:flex;gap:8px;margin-bottom:8px;align-items:center">
    <select style="flex:1;min-width:0" onchange="curRowCur(this)">${_curOptions(r.currency)}</select>
    <input type="number" step="0.01" value="${r.opening_balance || 0}" style="flex:1;min-width:0" placeholder="الرصيد الافتتاحي" oninput="curRowBal(this)">
    <button class="tbtn danger" onclick="this.closest('.cur-row').remove()">✕</button>
  </div>`).join("")}</div>`;
}
function addCurRow(cur, bal) {
  const rows = $("#curRows");
  if (!rows) return;
  const div = document.createElement("div");
  div.className = "cur-row";
  div.style.cssText = "display:flex;gap:8px;margin-bottom:8px;align-items:center";
  div.innerHTML = `<select style="flex:1;min-width:0">${_curOptions(cur || "SAR")}</select>
    <input type="number" step="0.01" value="${bal || 0}" style="flex:1;min-width:0" placeholder="الرصيد الافتتاحي">
    <button class="tbtn danger" onclick="this.closest('.cur-row').remove()">✕</button>`;
  rows.appendChild(div);
}
function curRowCur(el){ /* keep sync simple: nothing to do */ }
function curRowBal(el){ /* keep sync simple */ }
function collectCurrencies() {
  const rows = document.querySelectorAll("#curRows .cur-row");
  const out = [];
  rows.forEach((r) => {
    const c = r.querySelector("select").value;
    const bal = parseFloat(r.querySelector("input[type=number]").value) || 0;
    out.push({ currency: c, opening_balance: bal });
  });
  return out;
}
async function newBank() {
  $("#modalBox").innerHTML = `<h3>إضافة حساب بنكي إداري</h3>
    <div class="mfield"><label>اسم البنك</label><input id="nbName"></div>
    <div class="mfield"><label>اسم صاحب الحساب</label><input id="nbHolder"></div>
    <div class="grid2">
      <div class="mfield"><label>العملة الافتراضية</label><select id="nbCur">${_curOptions("SAR")}</select></div>
      <div class="mfield"><label>رقم الحساب</label><input id="nbAccNum"></div>
    </div>
    <div class="mfield"><label>رقم الآيبان</label><input id="nbIban"></div>
    <div class="mfield"><label>ملاحظات</label><input id="nbNotes"></div>
    <div class="mfield"><label>العملات — لكل عملة رصيد افتتاحي خاص بها</label>
      ${currencyEditorHtml([{ currency: "SAR", opening_balance: 0 }])}
      <button class="tbtn norm" onclick="addCurRow()">+ إضافة عملة</button>
    </div>
    <div class="m-actions"><button class="btn" onclick="saveBank()">حفظ</button><button class="btn ghost" onclick="closeModal()">إغلاق</button></div>`;
  openModal();
}
async function saveBank() {
  try {
    const body = {
      bank_name: $("#nbName").value,
      account_holder_name: $("#nbHolder") ? $("#nbHolder").value : "",
      currency: $("#nbCur").value,
      account_number: $("#nbAccNum") ? $("#nbAccNum").value : "",
      iban: $("#nbIban") ? $("#nbIban").value : "",
      notes: $("#nbNotes") ? $("#nbNotes").value : "",
      currencies: collectCurrencies(),
    };
    await api("admin/accounting/banks", { method: "POST", body }); toast("تم إنشاء الحساب"); closeModal(); bankDeckIdx = 1e9; renderAccounting($("#content"));
  }
  catch (e) { toast(e.message, true); }
}
async function editBank(id) {
  try {
    const banks = (await api("admin/accounting/banks")).data?.banks || [];
    const b = banks.find((x) => x.id === id);
    if (!b) { toast("البنك غير موجود", true); return; }
    const curs = (b.currencies && b.currencies.length) ? b.currencies : [{ currency: b.currency, opening_balance: b.opening_balance || 0 }];
    const sysLock = b.is_system ? "disabled" : "";
    const sysHint = b.is_system ? `<div class="muted" style="font-size:12px">بنك نظامي — الاسم والحالة محميان ولا يمكن تغييرهما</div>` : "";
    $("#modalBox").innerHTML = `<h3>تعديل الحساب البنكي</h3>${sysHint}
      <div class="mfield"><label>اسم البنك</label><input id="nbName" value="${esc(b.bank_name)}" ${sysLock}></div>
      <div class="mfield"><label>اسم صاحب الحساب</label><input id="nbHolder" value="${esc(b.account_holder_name || "")}"></div>
      <div class="grid2">
        <div class="mfield"><label>العملة الافتراضية</label><select id="nbCur">${_curOptions(b.currency)}</select></div>
        <div class="mfield"><label>رقم الحساب</label><input id="nbAccNum" value="${esc(b.account_number || "")}"></div>
      </div>
      <div class="mfield"><label>رقم الآيبان</label><input id="nbIban" value="${esc(b.iban || "")}"></div>
      <div class="mfield"><label>ملاحظات</label><input id="nbNotes" value="${esc(b.notes || "")}"></div>
      <div class="mfield"><label>العملات — لكل عملة رصيد افتتاحي خاص بها</label>
        ${currencyEditorHtml(curs)}
        <button class="tbtn norm" onclick="addCurRow()">+ إضافة عملة</button>
      </div>
      <div class="mfield"><label style="display:flex;align-items:center;gap:10px">مفعّل ${b.is_active ? "" : "— معطل"}<span class="switch ${b.is_active ? "on" : ""}" id="nbActive" ${b.is_system ? "" : `onclick="this.classList.toggle('on')"`}></span></label></div>
      <div class="m-actions"><button class="btn" onclick="saveEditBank('${id}')">حفظ التعديلات</button><button class="btn ghost" onclick="closeModal()">إلغاء</button></div>`;
    openModal();
  } catch (e) { toast(e.message, true); }
}
async function saveEditBank(id) {
  const sw = $("#nbActive");
  try {
    await api(`admin/accounting/banks/${id}`, { method: "PUT", body: {
      bank_name: $("#nbName").value,
      account_holder_name: $("#nbHolder").value,
      currency: $("#nbCur").value,
      account_number: $("#nbAccNum").value,
      iban: $("#nbIban").value,
      notes: $("#nbNotes").value,
      currencies: collectCurrencies(),
      is_active: sw ? sw.classList.contains("on") : true,
    } });
    toast("تم حفظ التعديلات"); closeModal(); renderAccounting($("#content"));
  } catch (e) { toast(e.message, true); }
}
async function newOperation(type, bankId = "", currency = "") {
  try {
    const banks = (await api("admin/accounting/banks")).data?.banks || [];
    if (!bankId) { bankId = banks[0]?.id || ""; currency = banks[0]?.currency || ""; }
    $("#modalBox").innerHTML = `<h3>${type === "deposit" ? "إيداع في حساب إداري" : "سحب صرفية"}</h3>
      <div class="mfield"><label>اسم البنك</label><select id="opBank" onchange="opCurSync()">${banks.map((b) => `<option value="${b.id}" ${b.id === bankId ? "selected" : ""}>${esc(b.bank_name)} — ${esc(b.currency)}</option>`).join("")}</select></div>
      <div class="mfield"><label>العملة</label><input id="opCur" value="${esc(currency)}" readonly></div>
      ${type === "withdraw" ? `<div class="mfield"><label>اسم الشخص المستفيد</label><input id="opPerson" placeholder="من يستلم الصرفية"></div>` : ""}
      <div class="mfield"><label>المبلغ</label><input id="opAmount" type="number" placeholder="0.00"></div>
      <div class="mfield"><label>${type === "deposit" ? "البيان (اختياري)" : "سبب الصرفية"}</label><input id="opDesc" placeholder="${type === "deposit" ? "إيداع…" : "اذكر سبب الصرفية"}"></div>
      <div class="m-actions"><button class="btn" onclick='doOperation( "${type}" )'>${type === "deposit" ? "إيداع" : "تنفيذ الصرفية"}</button><button class="btn ghost" onclick="closeModal()">إغلاق</button></div>`;
    openModal();
  } catch (e) { toast(e.message, true); }
}
async function opCurSync() {
  try {
    const banks = (await api("admin/accounting/banks")).data?.banks || [];
    const b = banks.find((x) => x.id === $("#opBank").value);
    $("#opCur").value = b?.currency || "";
  } catch (e) {}
}
async function doOperation(type) {
  const body = { bank_account_id: $("#opBank").value, currency: $("#opCur").value, amount: parseFloat($("#opAmount").value) || 0, description: $("#opDesc").value, person_name: $("#opPerson")?.value || "" };
  try {
    const r = await api("admin/accounting/operations", { method: "POST", body: { ...body, type } });
    toast(r.message || (type === "deposit" ? "تم الإيداع" : "تم تنفيذ الصرفية"));
    closeModal(); renderAccounting($("#content"));
  } catch (e) { toast(e.message, true); }
}

/* ── Notifications (admin center) ── */
let notifFilter = "all";
async function renderNotifications(c) {
  c.innerHTML = `
    <div class="card" style="display:flex;align-items:center;gap:12px;margin-bottom:14px;cursor:pointer" onclick="go('dashboard')">
      <span style="font-size:20px">→</span>
      <b>الرجوع</b>
    </div>
    <div class="card">
      <h3><span class="dot"></span>إرسال إشعار لجميع المستخدمين</h3>
      <div class="grid2">
        <div class="mfield"><label>${T("العنوان")}</label><input id="ntTitle"></div>
        <div class="mfield"><label>${T("النوع")}</label><select id="ntKind"><option value="info">${T("معلومات")}</option><option value="warning">${T("تحذير")}</option><option value="success">${T("نجاح")}</option></select></div>
      </div>
      <div class="mfield"><label>${T("الرسالة")}</label><textarea id="ntMsg" rows="3" placeholder="اكتب الرسالة هنا…"></textarea></div>
      <button class="btn" onclick="sendNotif()">${icon("notifications", 16)} ${T("إرسال الإشعار")}</button>
    </div>
    <div class="card" style="margin-top:14px">
      <h3><span class="dot"></span>أحدث الأنشطة والإشعارات</h3>
      <div class="bell-filters" id="bellFilters" style="padding:8px 0;border-bottom:1px solid var(--border)">
        <button class="tbtn sm bell-f danger" data-f="all" onclick="bellFilter('all',this)">الكل</button>
        <button class="tbtn sm bell-f" data-f="subscriptions" onclick="bellFilter('subscriptions',this)">الطلبات</button>
        <button class="tbtn sm bell-f" data-f="suggestions" onclick="bellFilter('suggestions',this)">الاقتراحات</button>
        <button class="tbtn sm bell-f" data-f="users" onclick="bellFilter('users',this)">المستخدمون</button>
        <button class="tbtn sm bell-f" data-f="banks" onclick="bellFilter('banks',this)">البنوك</button>
      </div>
      <div class="bell-list" id="bellList" style="max-height:calc(100vh - 420px)"></div>
    </div>`;
  loadBellFeed(true);
}
async function loadAdminNotifs() {
  const feed = [];
  try {
    const req = await api("admin/subscription-requests");
    (req.data?.requests || []).slice(0, 12).forEach((r) => {
      const st = r.status || "pending";
      const kind = st === "pending" ? "warn" : (st === "approved" ? "ok" : (st === "rejected" ? "danger" : "info"));
      const ttl = st === "pending" ? T("طلب اشتراك جديد") : (st === "approved" ? T("تم اعتماد اشتراك") : (st === "rejected" ? T("تم رفض اشتراك") : T("طلب اشتراك")));
      feed.push({ group: "subscriptions", kind, icon: "subscriptions", title: `${ttl} — ${planNameAr(r.plan_name)}`, desc: `${r.user_name || "—"} · ${fmtMoney(r.amount, r.currency)}`, at: r.created_at, status: st });
    });
  } catch (_) {}
  try {
    const u = await api("admin/users?page=1&per_page=8");
    (u.data?.users || u.data?.items || []).forEach((x) => feed.push({ group: "users", kind: "info", icon: "users", title: `${T("مستخدم")} — ${x.full_name || x.name}`, desc: x.email || "", at: x.created_at, status: x.status || "active" }));
  } catch (_) {}
  try {
    const s = await api("suggestions/conversations?per_page=8");
    (s.data?.items || s.data?.conversations || []).forEach((x) => feed.push({ group: "suggestions", kind: "warn", icon: "suggestions", title: `💡 ${T("اقتراح")} — ${x.user_name || x.name}`, desc: x.last_message || "", at: x.last_message_at, status: x.last_status || "pending" }));
  } catch (_) {}
  try {
    const o = await api("admin/accounting/operations?limit=8");
    (o.data?.operations || o.data?.items || o.data || []).forEach((x) => feed.push({ group: "banks", kind: x.type === "withdraw" ? "danger" : "ok", icon: "accounting", title: `${x.type === "withdraw" ? T("صرفية") : T("إيداع")} — ${x.bank_name || ""}`, desc: `${x.description || x.person_name || ""} · ${fmtMoney(x.amount, x.currency)}`, at: x.created_at, status: x.type === "withdraw" ? "rejected" : "approved" }));
  } catch (_) {}
  const el = $("#notifFeed");
  if (!el) return;
  const filtered = notifFilter === "all" ? feed : feed.filter((n) => n.group === notifFilter);
  filtered.sort((a, b) => (new Date(b.at || 0)) - (new Date(a.at || 0)));
  el.innerHTML = filtered.length
    ? filtered.map(notifItem).join("")
    : `<div class="empty">${uiEmpty("notifications", "لا توجد إشعارات بعد", "")}</div>`;
}
function notifItem(n) {
  const unread = n.status === "pending" || n.status === "withdraw";
  return `<div class="notif-item ${unread ? "unread" : ""}">
    <div class="notif-ic kind-${n.kind}">${icon(n.icon, 20)}</div>
    <div class="notif-mid">
      <div class="n-title">${esc(n.title)}</div>
      <div class="n-desc">${esc(n.desc || "")}</div>
      <div class="n-meta"><span class="tag">${esc(T(n.group === "subscriptions" ? "الاشتراكات" : (n.group === "users" ? "المستخدمون" : (n.group === "banks" ? "البنوك" : "الاقتراحات")) ))}</span><span>${fmtDate(n.at)}</span>${badge(n.status)}</div>
    </div>
  </div>`;
}

/* ════════════════════════════════════════════════════
   Admin notification bell (top header) — separate from
   the "send notification to users" composer.
   ════════════════════════════════════════════════════ */
let __bellFilter = "all";
let __bellFeed = [];
function toggleBell(force) {
  go("notifications");
}
function bellFilter(f, btn) {
  __bellFilter = f;
  $$("#bellFilters .bell-f").forEach((b) => b.classList.toggle("danger", b.getAttribute("data-f") === f));
  renderBellList();
}
function bellClick(n) {
  if (n.group === "subscriptions" && n.target) { go("subscriptions"); setTimeout(() => openSubscription(n.target), 220); }
  else if (n.group === "users" && n.target) { go("users"); setTimeout(() => openUser(n.target), 220); }
  else if (n.group === "suggestions" && n.target) { go("suggestions"); setTimeout(() => { const c = sugCache.find((x) => x.user_id === n.target); openChat(n.target, c?.user_name || "العميل"); }, 260); }
  else { go(n.group === "banks" ? "accounting" : "subscriptions"); }
}
function renderBellList() {
  const el = $("#bellList");
  if (!el) return;
  const items = __bellFeed.filter((n) => __bellFilter === "all" || n.group === __bellFilter);
  el.innerHTML = items.length
    ? items.map((n) => `<div class="bell-item" onclick="bellClick(${n.js})">
        <div class="notif-ic kind-${n.kind}">${icon(n.icon, 18)}</div>
        <div class="notif-mid"><div class="n-title" style="font-size:13px">${esc(n.title)}</div><div class="n-desc">${esc(n.desc || "")}</div><div class="n-meta"><span class="tag">${esc(T(n.group === "subscriptions" ? "الطلبات" : (n.group === "users" ? "المستخدمون" : (n.group === "banks" ? "البنوك" : "الاقتراحات"))))}</span><span>${fmtDate(n.at)}</span></div></div>
      </div>`).join("")
    : `<div class="empty">${uiEmpty("notifications", "لا توجد إشعارات", "")}</div>`;
}
async function loadBellFeed(silent) {
  const feed = [];
  try {
    const req = await api("admin/subscription-requests?status=pending");
    (req.data?.requests || []).slice(0, 8).forEach((r) => {
      feed.push({ group: "subscriptions", kind: "warn", icon: "subscriptions", title: `${T("طلب اشتراك جديد")} — ${planNameAr(r.plan_name)}`, desc: `${r.user_name || "—"} · ${fmtMoney(r.amount, r.currency)}`, at: r.created_at, target: r.id });
    });
    setNavBadge("subscriptions", (req.data?.requests || []).length);
  } catch (_) {}
  try {
    const s = await api("suggestions/conversations?per_page=8");
    (s.data?.items || s.data?.conversations || []).forEach((x) => {
      const uid = x.user_id || x.sender_id || "";
      feed.push({ group: "suggestions", kind: "warn", icon: "suggestions", title: `${T("اقتراح جديد")} — ${x.user_name || x.name}`, desc: (x.last_message || "") , at: x.last_message_at || x.updated_at, target: uid });
    });
  } catch (_) {}
  try {
    const u = await api("admin/users?page=1&per_page=6");
    (u.data?.users || u.data?.items || []).forEach((x) => feed.push({ group: "users", kind: "info", icon: "users", title: `${T("مستخدم جديد")} — ${x.full_name || x.name}`, desc: x.email || "", at: x.created_at, target: x.id }));
  } catch (_) {}
  try {
    const o = await api("admin/accounting/operations?limit=6");
    (o.data?.operations || o.data?.items || o.data || []).forEach((x) => feed.push({ group: "banks", kind: x.type === "withdraw" ? "danger" : "ok", icon: "accounting", title: `${x.type === "withdraw" ? T("صرفية") : T("إيداع")} — ${x.bank_name || ""}`, desc: `${x.description || x.person_name || ""} · ${fmtMoney(x.amount, x.currency)}`, at: x.created_at, target: x.id }));
  } catch (_) {}
  feed.sort((a, b) => (new Date(b.at || 0)) - (new Date(a.at || 0)));
  __bellFeed = feed.slice(0, 30);
  feed.forEach((n) => n.js = JSON.stringify({ group: n.group, target: n.target }).replace(/"/g, "&quot;"));
  const unread = feed.filter((n) => n.group === "subscriptions" || n.group === "suggestions").length;
  const badge = $("#bellBadge");
  if (badge) { badge.style.display = unread > 0 ? "flex" : "none"; badge.textContent = unread > 99 ? "99+" : unread; }
  renderBellList();
  buildNav();
}

/* Replace browser dialogs with in-app custom modal. */
function uiConfirm(title, msg, onYes, opt) {
  opt = opt || {};
  openModal();
  $("#modalBox").innerHTML = `<h3>${esc(title)}</h3>
    <p class="muted" style="margin-bottom:14px;line-height:1.7">${esc(msg)}</p>
    <div class="m-actions">
      <button class="btn ${opt.danger ? "btn danger" : "btn"}" onclick="const f=window.__confirmFn; window.__confirmFn=null; closeModal(); if(f)f();">${esc(T("تأكيد"))}</button>
      <button class="btn ghost" onclick="window.__confirmFn=null;closeModal()">${esc(T("إلغاء"))}</button>
    </div>`;
  window.__confirmFn = onYes;
}
/* In-app prompt replacement (e.g. extend days). */
function uiPrompt(title, label, value, onOk) {
  openModal();
  $("#modalBox").innerHTML = `<h3>${esc(title)}</h3>
    <div class="mfield"><label>${esc(label)}</label><input id="uiPromptVal" type="number" value="${esc(String(value ?? ""))}"></div>
    <div class="m-actions">
      <button class="btn" onclick="const p=$('#uiPromptVal').value; const f=window.__promptFn; window.__promptFn=null; closeModal(); if(f&&p!=='')f(p);">${esc(T("تأكيد"))}</button>
      <button class="btn ghost" onclick="window.__promptFn=null;closeModal()">${esc(T("إلغاء"))}</button>
    </div>`;
  window.__promptFn = onOk;
}
async function sendNotif() {
  try { await api("admin/notifications", { method: "POST", body: { title: $("#ntTitle").value, message: $("#ntMsg").value, type: $("#ntKind").value || "info", target: "all" } }); toast("أُرسل الإشعار لجميع المستخدمين"); renderNotifications($("#content")); }
  catch (e) { toast(e.message, true); }
}

/* ── Banners ── */
async function renderBanners(c) {
  c.innerHTML = `<div class="row"><button class="btn" style="width:auto" onclick="newBanner()">➕ لافتة جديدة</button></div>
    <div class="card"><div id="bannerRows"></div></div>`;
  try {
    const r = await api("admin/banners");
    const rows = r.data?.banners || r.data || [];
    $("#bannerRows").innerHTML = rows.length
      ? rows.map((b) => {
          const raw = b.image_url || b.media_url || "";
          const thumb = raw.startsWith("/uploads/")
            ? `./api/proxy-uploads?u=${encodeURIComponent(raw)}`
            : raw;
          const isVideo = /\.(mp4|webm|ogg)$/i.test(raw);
          return `<div class="banner-row">
          ${raw ? (isVideo
            ? `<span class="tag">${T("فيديو")}</span>`
            : `<img src="${thumb}" style="width:54px;height:36px;border-radius:8px;object-fit:cover;border:1px solid var(--border);flex:0 0 auto" onerror="this.style.display='none'">`)
            : `<span style="width:54px;height:36px;border-radius:8px;background:var(--surface-2);display:flex;align-items:center;justify-content:center;flex:0 0 auto">${icon("banners", 20)}</span>`}
          <b style="flex:1;min-width:120px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">${esc(b.title_key)}</b>
          <span class="muted" style="white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:180px">${esc(b.text || b.subtitle_key || "")}</span>
          <span class="tag">${b.duration_days ? `${b.duration_days} ${T("يوم")}` : T("دائم")}</span>
          <span class="badge ${b.is_active ? "approved" : "rejected"}">${b.is_active ? T("ظاهرة") : T("مخفية")}</span>
          <div class="chat-actions">
            <button class="tbtn norm" onclick="editBanner('${b.id}')">${T("تعديل")}</button>
            <button class="tbtn norm" onclick="bannerStats('${b.id}')">${T("إحصائيات")}</button>
            <button class="tbtn danger" onclick="deleteBanner('${b.id}')">${T("حذف")}</button>
          </div>
        </div>`;
        }).join("")
      : '<div class="empty">لا توجد لافتات</div>';
  } catch (e) { c.innerHTML = `<div class="empty">${esc(e.message)}</div>`; }
}
async function bannerStats(id) {
  try {
    const r = await api(`admin/banners/${id}/stats`);
    const d = r.data || {};
    $("#modalBox").innerHTML = `<h3>إحصائيات اللافتة</h3>
      <div class="row">
        <div class="kpi"><div class="v">${d.view_count ?? 0}</div><div class="l">مرات الظهور</div></div>
        <div class="kpi gold"><div class="v">${d.click_count ?? 0}</div><div class="l">نقرات</div></div>
        <div class="kpi green"><div class="v">${d.watch_hours ?? 0}</div><div class="l">ساعات المشاهدة</div></div>
      </div>
      <div class="m-actions"><button class="btn ghost" onclick="closeModal()">إغلاق</button></div>`;
    openModal();
  } catch (e) { toast(e.message, true); }
}

async function deleteBanner(id) {
  uiConfirm(T("حذف اللافتة"), T("حذف هذه اللافتة نهائياً؟ لا يمكن التراجع عن هذا الإجراء."), async () => {
    try {
      await api(`admin/banners/${id}`, { method: "DELETE" });
      toast("تم حذف اللافتة");
      closeModal();
      renderBanners($("#content"));
    } catch (e) { toast(e.message, true); }
  }, { danger: true });
}

let bnState = { x: 0, y: 0, w: 100, h: 100 }; // % of stage
function bannerMediaSrc(raw) {
  if (!raw) return "";
  // Saved banner media are backend paths (/uploads/...) — the browser can't
  // read them directly, so route them through the admin proxy like proofs.
  if (raw.startsWith("/uploads/") && !raw.startsWith("http")) {
    return `./api/proxy-uploads?u=${encodeURIComponent(raw)}`;
  }
  return raw; // blob: previews & absolute URLs pass through unchanged
}
function bannerLive() {
  const t = $("#bKey")?.value || "";
  const txt = $("#bText")?.value || "";
  const c1 = $("#bC1")?.value || "#a01530";
  const c2 = $("#bC2")?.value || "#7a1020";
  const media = $("#bMedia")?.value || "";
  const stage = $("#bannerStage");
  if (!stage) return;
  // apply background gradient & overlay text layer only, media child is managed by sync
  stage.style.background = `linear-gradient(135deg,${c1},${c2})`;
  const txtEl = stage.querySelector(".banner-overlay");
  if (txtEl) {
    txtEl.innerHTML = `<div style="position:relative;z-index:2;padding:14px 16px;width:100%;background:linear-gradient(to top, rgba(0,0,0,.55), transparent)">
        <div style="color:#fff;font-weight:900;font-size:15px">${esc(t || "عنوان اللافتة")}</div>
        <div style="color:#ffe6e6;font-size:11px">${esc(txt || "وصف مختصر للافتة…")}</div></div>`;
  }
  syncBannerMedia(media);
  syncPhonePreview();
  bannerMarkDots();
}
function syncBannerMedia(media) {
  // (Re)render the media layer from current URL + bnState (keeps drag/resize state).
  const stage = $("#bannerStage");
  if (!stage) return;
  let mEl = stage.querySelector(".banner-media");
  const hasMedia = !!media;
  if (hasMedia && !mEl) {
    mEl = document.createElement("div");
    mEl.className = "banner-media";
    mEl.style.touchAction = "none";
    mEl.style.cursor = "grab";
    stage.insertBefore(mEl, stage.querySelector(".banner-overlay"));
    mEl.addEventListener("pointerdown", bannerDragStart);
  }
  if (!hasMedia && mEl) { mEl.remove(); mEl = null; }
  if (!mEl) return;
  const src = bannerMediaSrc(media);
  const isVideo = media.startsWith("data:video") || /\.mp4|\.webm|\.ogg/i.test(media);
  if (isVideo) {
    if (!mEl.querySelector("video")) { mEl.innerHTML = `<video muted autoplay loop playsinline src="${src}"></video>`; }
    else mEl.querySelector("video").src = src;
  } else {
    if (!mEl.querySelector("img")) { mEl.innerHTML = `<img src="${src}">`; }
    else mEl.querySelector("img").src = src;
  }
  if (mEl.querySelector("video") && src) mEl.querySelector("video").src = src;
  if (mEl.querySelector("img") && src) mEl.querySelector("img").src = src;
  // Resize handles (always attached, pointer-events enabled)
  if (!mEl.querySelector(".resize-h")) {
    ["corner-se","corner-ne","corner-sw","corner-nw"].forEach((cn) => {
      const h = document.createElement("span");
      h.className = `resize-h ${cn}`;
      h.addEventListener("pointerdown", bannerResizeStart(cn));
      mEl.appendChild(h);
    });
  }
  applyBannerMediaTransform();
  updateBannerDimsUI();
}
function applyBannerMediaTransform() {
  const mEl = document.querySelector(".banner-media");
  if (!mEl) return;
  mEl.style.width = `${bnState.w}%`;
  mEl.style.height = `${bnState.h}%`;
  mEl.style.left = `${bnState.x}%`;
  mEl.style.top = `${bnState.y}%`;
}
function updateBannerDimsUI() {
  const st = $("#bnSize"), pos = $("#bnPos");
  if (st) st.textContent = `${Math.round(bnState.w)}% × ${Math.round(bnState.h)}%`;
  if (pos) pos.textContent = `موضع: ${Math.round(bnState.x)}% ، ${Math.round(bnState.y)}%`;
}
function bannerDragStart(e) {
  if (e.target.closest(".resize-h")) return;
  e.preventDefault(); e.stopPropagation();
  const mEl = e.currentTarget;
  const stage = $("#bannerStage");
  const sRect = stage.getBoundingClientRect();
  const startX = bnState.x, startY = bnState.y;
  const px = e.clientX, py = e.clientY;
  let dragging = false;
  const move = (ev) => {
    const dx = ev.clientX - px;
    const dy = ev.clientY - py;
    if (!dragging && (Math.abs(dx) < 4 && Math.abs(dy) < 4)) return;
    dragging = true;
    mEl.style.cursor = "grabbing";
    const rawX = startX + (dx / sRect.width) * 100;
    const rawY = startY + (dy / sRect.height) * 100;
    bnState.x = Math.max(0, Math.min(100 - bnState.w, rawX));
    bnState.y = Math.max(0, Math.min(100 - bnState.h, rawY));
    applyBannerMediaTransform(); updateBannerDimsUI(); syncPhonePreview();
  };
  const up = () => {
    mEl.style.cursor = "grab";
    window.removeEventListener("pointermove", move);
    window.removeEventListener("pointerup", up);
    window.removeEventListener("pointercancel", up);
  };
  window.addEventListener("pointermove", move);
  window.addEventListener("pointerup", up);
  window.addEventListener("pointercancel", up);
}
function bannerResizeStart(corner) {
  return (e) => {
    e.preventDefault(); e.stopPropagation();
    const mEl = e.currentTarget.closest(".banner-media");
    if (!mEl) return;
    const stage = $("#bannerStage");
    const sRect = stage.getBoundingClientRect();
    const start = { ...bnState };
    const px = e.clientX, py = e.clientY;
    let resizing = false;
    const move = (ev) => {
      const dx = ev.clientX - px;
      const dy = ev.clientY - py;
      if (!resizing && (Math.abs(dx) < 4 && Math.abs(dy) < 4)) return;
      resizing = true;
      const dxPct = (dx / sRect.width) * 100;
      const dyPct = (dy / sRect.height) * 100;
      const nx = corner.includes("e") ? start.w + dxPct : start.w - dxPct;
      const ny = corner.includes("s") ? start.h + dyPct : start.h - dyPct;
      bnState.w = Math.max(15, Math.min(120, nx));
      bnState.h = Math.max(15, Math.min(120, ny));
      applyBannerMediaTransform(); updateBannerDimsUI(); syncPhonePreview();
    };
    const up = () => { window.removeEventListener("pointermove", move); window.removeEventListener("pointerup", up); };
    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", up);
  };
}
function bannerRevealMedia() {
  bnState.x = 0; bnState.y = 0; bnState.w = 100; bnState.h = 100;
  applyBannerMediaTransform(); updateBannerDimsUI(); syncBannerRanges(); syncPhonePreview();
}
function bannerFillMedia() {
  bnState.x = 0; bnState.y = 0; bnState.w = 100; bnState.h = 100;
  applyBannerMediaTransform(); updateBannerDimsUI(); syncBannerRanges(); syncPhonePreview();
}
function bannerCenterMedia() {
  bnState.x = (100 - bnState.w) / 2;
  bnState.y = (100 - bnState.h) / 2;
  applyBannerMediaTransform(); updateBannerDimsUI(); syncBannerRanges(); syncPhonePreview();
}
function bannerOnRange(prop) {
  const v = parseFloat(event.target.value) || 0;
  bnState[prop] = v;
  applyBannerMediaTransform(); updateBannerDimsUI(); syncBannerRanges(); syncPhonePreview();
}
function syncBannerRanges() {
  ["bX","bY","bW","bH"].forEach((id) => {
    const el = document.getElementById(id);
    if (el) {
      const prop = id.slice(1).toLowerCase();
      el.value = Math.round(bnState[prop] * 10) / 10;
      const lbl = document.getElementById(id + "v");
      if (lbl) lbl.textContent = (Math.round(bnState[prop] * 10) / 10) + "%";
    }
  });
}
function syncPhonePreview() { /* phone mock removed — stage itself is the true-size preview */ }
function bannerRangeBlock() {
  return `<div class="banner-ctrl-grid" id="bannerCtrls">
    <label class="bctrl"><span>الموضع أفقي</span><input type="range" min="0" max="100" step="1" id="bX" oninput="bannerOnRange('x')"><b class="bval" id="bXv">0%</b></label>
    <label class="bctrl"><span>الموضع عمودي</span><input type="range" min="0" max="100" step="1" id="bY" oninput="bannerOnRange('y')"><b class="bval" id="bYv">0%</b></label>
    <label class="bctrl"><span>العرض</span><input type="range" min="20" max="140" step="1" id="bW" oninput="bannerOnRange('w')"><b class="bval" id="bWv">100%</b></label>
    <label class="bctrl"><span>الارتفاع</span><input type="range" min="20" max="140" step="1" id="bH" oninput="bannerOnRange('h')"><b class="bval" id="bHv">100%</b></label>
  </div>`;
}
function bannerBuildStage() {
  return `
    <div class="banner-stage-wrap">
      <div class="banner-stage" id="bannerStage">
        <div class="banner-overlay" style="position:absolute;inset:0;display:flex;align-items:flex-end;pointer-events:none"></div>
      </div>
      <span class="muted">🖐️ اسحب الصورة داخل المستطيل لتحريكها — بنفس مقاس اللافتة في التطبيق تماماً</span>
    </div>`;
}
/* ── Banner color dots (circular palette + custom native picker) ── */
const BANNER_PALETTE = ["#000000","#434343","#7a1020","#a01530","#d32f2f","#e67e22","#f1c40f","#ffd700","#27ae60","#16a085","#1b7ad4","#1565c0","#6a1b9a","#8e24aa","#e91e63","#ffffff"];
function bannerColorDots(inputId) {
  const dots = BANNER_PALETTE.map((c) => `<span class="cdot" data-c="${c}" title="${c}" style="background:${c}" onclick="bannerSetColor('${inputId}','${c}')"></span>`).join("");
  return `<span class="cdots" id="${inputId}dots">${dots}<span class="cdot custom" title="لون مخصص" onclick="document.getElementById('${inputId}').click()"></span></span>`;
}
function bannerSetColor(inputId, hex) {
  const el = document.getElementById(inputId);
  if (el) el.value = hex;
  bannerLive();
}
function bannerMarkDots() {
  ["bC1","bC2"].forEach((id) => {
    const v = ((document.getElementById(id) || {}).value || "").toLowerCase();
    const dots = document.getElementById(id + "dots");
    if (!dots) return;
    dots.querySelectorAll(".cdot[data-c]").forEach((d) => {
      d.classList.toggle("sel", (d.getAttribute("data-c") || "").toLowerCase() === v);
    });
  });
}
function newBanner() {
  bnState = { x: 0, y: 0, w: 100, h: 100 };
  $("#modalBox").innerHTML = `<h3>لافتة جديدة — معاينة تفاعلية</h3>
    ${bannerBuildStage()}
    <div class="banner-tools">
      <button class="tbtn norm" onclick="bannerFillMedia()">ملء الإطار</button>
      <button class="tbtn norm" onclick="bannerCenterMedia()">توسيط</button>
      <button class="tbtn norm" onclick="bannerRevealMedia()">إعادة تعيين</button>
    </div>
    ${bannerRangeBlock()}
    <div class="blive-ctrls">
      <div class="mfield"><label>العنوان (مفتاح) + تخصيص لون البداية</label>
        <div class="brow"><input id="bKey" oninput="bannerLive()">${bannerColorDots("bC1")}</div>
        <input id="bC1" class="native-hidden" type="color" value="#a01530" oninput="bannerLive()">
      </div>
      <div class="mfield"><label>النص الظاهر + تخصيص لون النهاية</label>
        <div class="brow"><input id="bText" oninput="bannerLive()">${bannerColorDots("bC2")}</div>
        <input id="bC2" class="native-hidden" type="color" value="#7a1020" oninput="bannerLive()">
      </div>
    </div>
    <div class="mfield"><label>الرابط عند الضغط</label><input id="bUrl"></div>
    <div class="grid2">
      <div class="mfield"><label>مدة الظهور (أيام)</label><input id="bDays" type="number" value="0"></div>
      <div class="mfield"><label>سرعة التقلب (ثواني)</label><input id="bSpeed" type="number" value="4"></div>
    </div>
    <div class="mfield"><label>صورة من الاستوديو أو فيديو متحرك</label>
      <input type="file" id="bMediaFile" accept="image/*,video/*" onchange="uploadBannerMedia('')">
      <div class="muted" style="margin-top:4px">أو الصق رابط مباشر أدناه</div>
      <input id="bMedia" oninput="bannerLive()" placeholder="رابط صورة/فيديو">
    </div>
    <div class="banner-editor-tip">💡 اسحب الصورة داخل الإطار لتحريكها، واسحب مقابض الزوايا البيضاء لتغيير المقاس، أو استخدم المنزلقات للدقة الكاملة</div>
    <div class="m-actions"><button class="btn" onclick="saveBanner('')">حفظ</button><button class="btn ghost" onclick="closeModal()">إغلاق</button></div>`;
  openModal();
  requestAnimationFrame(() => {
    const stage = $("#bannerStage");
    stage.style.background = "linear-gradient(135deg,#a01530,#7a1020)";
    bannerLive();
    syncBannerRanges();
  });
}
async function uploadBannerMedia(id, file) {
  const f = file || $("#bMediaFile").files[0];
  if (!f) return;
  window.__pendingBannerFile = f;
  bnState = { x: 0, y: 0, w: 100, h: 100 };
  _doBannerUpload(id, f);
}
async function _doBannerUpload(id, f) {
  try {
    $("#bMedia").value = URL.createObjectURL(f);
    bannerLive();
    if (id) {
      const isImage = f.type && f.type.startsWith("image/");
      const fd = new FormData();
      fd.append(isImage ? "image" : "media", f);
      const ep = isImage
        ? `./api/admin/banners/${id}/upload-image`
        : `./api/admin/banners/${id}/upload-media`;
      const res = await fetch(ep, { method: "POST", body: fd });
      const j = await res.json();
      if (j.success) {
        const b = j.data?.banner || j.data || {};
        const direct = b.image_url || b.media_url || "";
        if (direct) $("#bMedia").value = direct;
      } else toast(j.message || "فشل الرفع", true);
      bannerLive();
    }
  } catch (e) { toast(e.message, true); }
}
async function editBanner(id) {
  try {
    const r = await api(`admin/banners/${id}`);
    const b = r.data || {};
    bnState = { x: b.media_x != null ? Number(b.media_x) : 0, y: b.media_y != null ? Number(b.media_y) : 0, w: b.media_w != null ? Number(b.media_w) : 100, h: b.media_h != null ? Number(b.media_h) : 100 };
    $("#modalBox").innerHTML = `<h3>تعديل اللافتة — معاينة تفاعلية</h3>
      ${bannerBuildStage()}
      <div class="banner-tools">
        <button class="tbtn norm" onclick="bannerFillMedia()">ملء الإطار</button>
        <button class="tbtn norm" onclick="bannerCenterMedia()">توسيط</button>
        <button class="tbtn norm" onclick="bannerRevealMedia()">إعادة تعيين</button>
      </div>
      ${bannerRangeBlock()}
      <div class="blive-ctrls">
        <div class="mfield"><label>العنوان (مفتاح) + تخصيص لون البداية</label>
          <div class="brow"><input id="bKey" value="${esc(b.title_key)}" oninput="bannerLive()">${bannerColorDots("bC1")}</div>
          <input id="bC1" class="native-hidden" type="color" value="${esc(b.color_start || "#a01530")}" oninput="bannerLive()">
        </div>
        <div class="mfield"><label>النص الظاهر + تخصيص لون النهاية</label>
          <div class="brow"><input id="bText" value="${esc(b.text || "")}" oninput="bannerLive()">${bannerColorDots("bC2")}</div>
          <input id="bC2" class="native-hidden" type="color" value="${esc(b.color_end || "#7a1020")}" oninput="bannerLive()">
        </div>
      </div>
      <div class="mfield"><label>الرابط</label><input id="bUrl" value="${esc(b.click_url || "")}"></div>
      <div class="grid2">
        <div class="mfield"><label>مدة الظهور (أيام)</label><input id="bDays" type="number" value="${b.duration_days || 0}"></div>
        <div class="mfield"><label>سرعة التقلب (ثواني)</label><input id="bSpeed" type="number" value="${b.carousel_seconds || 4}"></div>
      </div>
      <div class="mfield"><label>صورة من الاستوديو / فيديو متحرك</label>
        <input type="file" id="bMediaFile" accept="image/*,video/*" onchange="uploadBannerMedia('${id}')">
        <input id="bMedia" value="${esc(b.media_url || b.image_url || "")}" oninput="bannerLive()" placeholder="رابط صورة/فيديو">
      </div>
      <div class="mfield"><label>مفعّلة</label><label class="switch ${b.is_active ? "on" : ""}" id="bSw"></label></div>
      <div class="banner-editor-tip">💡 اسحب الصورة داخل الإطار لتحريكها، واسحب مقابض الزوايا البيضاء لتغيير المقاس، أو استخدم المنزلقات للدقة الكاملة</div>
      <div class="m-actions"><button class="btn" onclick="saveBanner('${id}')">حفظ</button><button class="btn ghost" onclick="closeModal()">إغلاق</button></div>`;
    $("#bSw").onclick = () => $("#bSw").classList.toggle("on");
    const media = b.media_url || b.image_url || "";
    requestAnimationFrame(() => {
      const stage = $("#bannerStage");
      stage.style.background = `linear-gradient(135deg,${b.color_start || "#a01530"},${b.color_end || "#7a1020"})`;
      $("#bMedia").value = media;
      bannerLive();
      syncBannerRanges();
    });
    openModal();
  } catch (e) { toast(e.message, true); }
}
async function saveBanner(id) {
  const saveBtn = document.querySelector("#modalBox .m-actions .btn");
  const origTxt = saveBtn ? saveBtn.textContent : "";
  if (saveBtn) { saveBtn.disabled = true; saveBtn.textContent = "جاري الحفظ…"; }
  try {
    let media = $("#bMedia")?.value || null;
    // A live object-URL preview must never be persisted — it's reset after the
    // real upload completes below.
    if (media && media.startsWith("blob:")) media = null;
    const hasPending = !!window.__pendingBannerFile;
    const mediaBox = (media || hasPending) ? { media_x: Math.round((bnState.x || 0) * 100) / 100, media_y: Math.round((bnState.y || 0) * 100) / 100, media_w: Math.round((bnState.w || 100) * 100) / 100, media_h: Math.round((bnState.h || 100) * 100) / 100 } : {};
    // When a real file is pending, omit media_url from create so the DB never
    // stores the temp blob; the upload below sets the true URL.
    const body = { title_key: $("#bKey").value, text: $("#bText").value, click_url: $("#bUrl").value, color_start: $("#bC1").value, color_end: $("#bC2").value, duration_days: parseInt($("#bDays")?.value || "0", 10) || 0, carousel_seconds: parseInt($("#bSpeed")?.value || "4", 10) || 4, media_url: hasPending ? null : media, is_active: $("#bSw")?.classList.contains("on") ?? true, ...mediaBox };
    let finalId = id, needsUpload = false, mediaName = "";
    if (window.__pendingBannerFile) { needsUpload = true; mediaName = window.__pendingBannerFile.name; }
    if (id) {
      await api(`admin/banners/${id}`, { method: "PUT", body });
    } else {
      const created = await api("admin/banners", { method: "POST", body });
      finalId = (created.data && created.data.id) || "";
      if (!finalId && media) finalId = (media.split("/").pop() || "").split("_")[0];
    }
    // Persist the freshly-picked file to the banner's media.
    if (needsUpload && finalId && window.__pendingBannerFile) {
      const f = window.__pendingBannerFile;
      const isImage = f.type && f.type.startsWith("image/");
      const fd = new FormData();
      fd.append(isImage ? "image" : "media", f);
      const ep = isImage
        ? `./api/admin/banners/${finalId}/upload-image`
        : `./api/admin/banners/${finalId}/upload-media`;
      const upCtrl = new AbortController();
      const upTimer = setTimeout(() => upCtrl.abort(), 55000);
      let upRes;
      try { upRes = await fetch(ep, { method: "POST", body: fd, signal: upCtrl.signal }); }
      catch (e) { clearTimeout(upTimer); throw new Error(e && e.name === "AbortError" ? "انتهت مهلة رفع الصورة — جرّب صورة أصغر حجماً" : (e.message || "فشل الرفع")); }
      clearTimeout(upTimer);
      const upJson = await upRes.json().catch(() => ({}));
      if (upJson.success && finalId) {
        const b = upJson.data?.banner || upJson.data || {};
        const direct = b.image_url || b.media_url || "";
        // Keep the saved banner's URL pointing at the fresh upload.
        const body2 = direct
          ? { [isImage ? "image_url" : "media_url"]: direct }
          : {};
        if (Object.keys(body2).length) {
          await api(`admin/banners/${finalId}`, { method: "PUT", body: body2 }).catch(() => {});
        }
      }
    }
    window.__pendingBannerFile = null;
    toast("تم حفظ اللافتة"); closeModal(); renderBanners($("#content"));
  } catch (e) { console.error("saveBanner failed:", e); toast((e && e.message) || "فشل الحفظ", true); }
  finally { if (saveBtn) { saveBtn.disabled = false; saveBtn.textContent = origTxt; } }
}

/* ── Suggestions (WhatsApp-style) ── */
let selUser = null, sugTimer = null, sugChatTimer = null, sugFilterStatus = "", sugCache = [];
// Ticket selected inside the open chat (one user may own several tickets;
// messages are always filtered to this ticket, replies attach to it).
let selTicket = null;
const SUG_STATUS = {
  pending:     { label: "قيد المراجعة", cls: "pending" },
  proposed:    { label: "مقترح", cls: "proposed" },
  in_progress: { label: "قيد التنفيذ", cls: "in_progress" },
  completed:   { label: "تم تنفيذه", cls: "completed" },
  rejected:    { label: "مرفوض", cls: "rejected" },
};
const SUG_FILTERS = [
  ["", "الكل"],
  ["pending", "قيد المراجعة"],
  ["proposed", "مقترح"],
  ["in_progress", "قيد التنفيذ"],
  ["completed", "تم تنفيذه"],
  ["rejected", "مرفوض"],
];
function sugStatusBadge(st) {
  const s = SUG_STATUS[st] || { label: st, cls: "pending" };
  return `<span class="badge ${s.cls}">${esc(s.label)}</span>`;
}
function supTime(iso) {
  if (!iso) return "";
  const d = new Date(iso);
  if (isNaN(d)) return "";
  const now = new Date();
  const sameDay = d.toDateString() === now.toDateString();
  if (sameDay) return d.toLocaleTimeString("ar-EG", { hour: "2-digit", minute: "2-digit" });
  return d.toLocaleDateString("ar-EG", { day: "2-digit", month: "2-digit" });
}
function stopSuggestionPoll() {
  if (sugTimer) { clearInterval(sugTimer); sugTimer = null; }
  if (sugChatTimer) { clearInterval(sugChatTimer); sugChatTimer = null; }
}

async function renderSuggestions(c) {
  selUser = null; selTicket = null; sugFilterStatus = ""; sugCache = [];
  c.innerHTML = `
    <div class="sug-layout">
      <div class="sug-side" id="sugSide">
        <div class="sug-search">
          <input id="sugSearch" placeholder="${T("بحث بالاسم…")}" onkeydown="if(event.key==='Enter')loadSuggestionUsers()">
        </div>
        <div class="sug-filters" id="sugFilters">
          ${SUG_FILTERS.map(([v, l]) => `<button class="sug-chip ${v === "" ? "on" : ""}" data-f="${v}" onclick="sugSetFilter('${v}', this)">${l}</button>`).join("")}
        </div>
        <div class="sug-users" id="sugUsers"><div class="empty">${T("جاري التحميل…")}</div></div>
      </div>
      <div class="sug-main" id="sugMain">
        <div class="sug-empty" id="sugEmpty">
          <div class="se-badge">${icon("suggestions", 30)}</div>
          <b>${T("مركز اقتراحات العملاء")}</b>
          <span>${T("اختر محادثة من القائمة")}</span>
        </div>
        <div class="chat-head" id="sugHead" style="display:none">
          <button class="back-btn" id="sugBackBtn" onclick="sugBackToList()" title="${T("رجوع")}" style="display:none">←</button>
          <div class="avatar" id="sugHeadAvatar">؟</div>
          <div class="ch-info">
            <b id="sugHeadName">—</b>
            <span class="ch-sub" id="sugHeadSub"></span>
          </div>
          <div class="chat-head-right">
            <span class="online-dot" id="sugOnlineDot" style="display:none"></span>
            <span class="online-label" id="sugOnlineLabel" style="display:none">${T("متصل")}</span>
            <button class="status-sel" id="sugHeadStatus" onclick="askSugStatusModal()">${T("الحالة")}</button>
          </div>
        </div>
        <div class="sug-chat" id="sugChat" style="display:none"></div>
        <div class="attach-chip" id="attachChip"></div>
        <div class="sug-replybar" id="sugReplyBar" style="display:none">
          <button class="icon-btn" onclick="openChatAttach()" title="${T("إرفاق صورة/فيديو")}" aria-label="${T("إرفاق")}">
            <svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="1.8"><rect x="3" y="5" width="14" height="14" rx="2"/><circle cx="16" cy="9" r="2"/><path d="M3 17l4-4 3 3 4-4 5 5"/></svg>
          </button>
          <button class="icon-btn" id="voiceBtn" onclick="toggleVoiceRecord()" title="${T("تسجيل صوت")}" aria-label="${T("تسجيل صوت")}">
            <svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="1.8"><rect x="9" y="2" width="6" height="11" rx="3"/><path d="M5 10v1a7 7 0 0014 0v-1"/><path d="M12 18v4"/></svg>
          </button>
          <span class="voice-timer" id="voiceTimer"><span class="rec-dot"></span><span id="voiceSecs">0:00</span></span>
          <input id="sugMsg" placeholder="${T("اكتب رسالة…")}" onkeydown="if(event.key==='Enter')sendReply()">
          <button class="btn sug-send-btn" onclick="sendReply()">
            <svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="2"><path d="M22 2L11 13"/><path d="M22 2L15 22L11 13L2 9L22 2Z"/></svg>
          </button>
        </div>
      </div>
    </div>`;
  stopSuggestionPoll();
  await loadSuggestionUsers();
  // Users list: light 6s refresh. Open ticket: faster 3s refresh so new
  // user messages (and the other ticket's activity) land almost instantly.
  sugTimer = setInterval(() => { loadSuggestionUsers(true); }, 6000);
  sugChatTimer = setInterval(() => { if (selUser) openChat(selUser.id, selUser.name, true); }, 3000);
}
function sugSetFilter(v) {
  sugFilterStatus = v;
  $$("#sugFilters .sug-chip").forEach((ch) => ch.classList.toggle("on", ch.getAttribute("data-f") === v));
  loadSuggestionUsers();
}
function sugBackToList() {
  $("#sugChat").style.display = "none";
  $("#sugReplyBar").style.display = "none";
  const e = $("#sugEmpty"); if (e) e.style.display = "";
  // On mobile, show the side list again.
  document.querySelector(".sug-layout")?.classList.remove("chat-open");
}
async function loadSuggestionUsers(silent) {
  try {
    const params = new URLSearchParams();
    const q = $("#sugSearch")?.value.trim() || "";
    if (q) params.set("search", q);
    if (sugFilterStatus) params.set("status", sugFilterStatus);
    const r = await api(`suggestions/conversations?${params.toString()}`);
    const data = r.data || {};
    const rows = data.items || data.conversations || [];
    sugCache = rows;
    if (silent && !$("#sugUsers")) return;
    $("#sugUsers").innerHTML = rows.length
      ? rows.map((u) => {
          const uid = u.user_id || u.sender_id || u.id || "";
          const name = u.user_name || u.name || "عميل";
          const last = u.last_message || "";
          const time = supTime(u.last_message_at);
          const active = selUser && selUser.id === uid;
          const st = u.last_status || "pending";
          return `<div class="sug-user ${active ? "active" : ""}" onclick="openChat('${uid}','${esc(name)}')">
            <div class="avatar">${esc(name.charAt(0))}</div>
            <div class="su-mid">
              <div class="su-top"><b>${esc(name)}</b><span class="su-time">${time}</span></div>
              <div class="su-sub">
                <span class="su-preview">${esc(u.last_is_from_admin ? "أنت: " + last : last)}</span>
                ${u.unread_count > 0 ? `<span class="unread">${u.unread_count}</span>` : ""}
              </div>
            </div>
            <span class="su-status">${sugStatusBadge(st)}</span>
          </div>`;
        }).join("")
      : ('<div class="empty">لا توجد محادثات' + (sugFilterStatus ? " بهذه الحالة" : "") + "</div>");
  } catch (e) {
    if (!$("#sugUsers")) return;
    $("#sugUsers").innerHTML = `<div class="empty">${esc(e.message)}</div>`;
  }
}
function sugMaybeScrollDown(force) {
  const el = $("#sugChat");
  if (!el) return;
  if (force) { el.scrollTop = el.scrollHeight; return; }
  const nearBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 120;
  if (nearBottom) el.scrollTop = el.scrollHeight;
}
function sugOpenLayout() {
  document.querySelector(".sug-layout")?.classList.add("chat-open");
}
async function openChat(uid, name, silent) {
  const switched = !selUser || selUser.id !== uid;
  selUser = { id: uid, name };
  if (switched) selTicket = null;
  if (switched && !silent && (__pendingAttach || $("#attachChip")?.classList.contains("show"))) {
    __pendingAttach = null; renderAttachChip();
  }
  const row = (sugCache || []).find((c) => (c.user_id || c.sender_id || c.id) === uid);
  const st = (row && (row.status || row.last_status)) || "pending";
  const serial = String(uid || "").slice(0, 8);
  window.__curUid = uid;
  window.__curSug = (row && (row.suggestion_id || row.conversation_id || row.id)) || "";
  const e = $("#sugEmpty"); if (e) e.style.display = "none";
  const head = $("#sugHead"); if (head) head.style.display = "";
  const backBtn = $("#sugBackBtn"); if (backBtn) backBtn.style.display = window.innerWidth <= 940 ? "" : "none";
  if ($("#sugHeadAvatar")) $("#sugHeadAvatar").textContent = (name || "?").charAt(0);
  if ($("#sugHeadName")) $("#sugHeadName").textContent = name;
  if ($("#sugHeadSub")) $("#sugHeadSub").textContent = `#${serial}`;
  const stb = $("#sugHeadStatus");
  if (stb) stb.innerHTML = `${sugStatusBadge(st)}`;
  window.__curSugStatus = st;
  const onDot = $("#sugOnlineDot");
  const onLbl = $("#sugOnlineLabel");
  if (onDot) onDot.style.display = "";
  if (onLbl) onLbl.style.display = "";
  $("#sugChat").style.display = "";
  $("#sugReplyBar").style.display = "";
  sugOpenLayout();
  try { api(`suggestions/conversations/${uid}/read`, { method: "POST" }); } catch (_) {}
  try {
    const r = await api(`suggestions/conversations/${uid}/messages`);
    const data = r.data || {};
    const all = (data.items || data.messages || []).slice();
    all.sort((a, b) => (new Date(a.created_at || 0)) - (new Date(b.created_at || 0)));
    // Per-ticket isolation: one user may own several tickets; each ticket
    // keeps its own message stream. Track ids->body for the edit action.
    window.__sugMsgs = {};
    for (const m of all) { if (m && m.id) window.__sugMsgs[m.id] = m.body || ""; }
    const tids = [...new Set(all.map((m) => m.suggestion_id).filter(Boolean))];
    if (!tids.includes(selTicket)) selTicket = pickLatestTicket(all, tids);
    window.__curSug = selTicket || window.__curSug;
    const sugRow = all.find((m) => m.kind === "suggestion" && m.suggestion_id === selTicket);
    const tst = (sugRow && sugRow.status) || st;
    window.__curSugStatus = tst;
    if (stb) stb.innerHTML = `${sugStatusBadge(tst)}`;
    const shown = selTicket ? all.filter((m) => m.suggestion_id === selTicket) : all;
    const tabs = tids.length > 1 ? buildTicketTabs(tids, all) : "";
    $("#sugChat").innerHTML = tabs + (shown.length ? buildChat(shown) : `<div class="empty" style="padding:40px"><div class="em-ic">${icon("suggestions",26)}</div><b>${T("لا توجد رسائل بعد")}</b><span>${T("ابدأ الرد مع العميل")}</span></div>`);
    sugMaybeScrollDown(!silent);
  } catch (err) {
    $("#sugChat").innerHTML = `<div class="empty">${esc(err.message)}</div>`;
  }
}
function pickLatestTicket(msgs, tids) {
  let best = "", bestTs = "";
  for (const tid of tids) {
    const s = msgs.find((m) => m.kind === "suggestion" && m.suggestion_id === tid);
    const ts = (s && s.created_at) || "";
    if (ts >= bestTs) { bestTs = ts; best = tid; }
  }
  return best || tids[0] || null;
}
function buildTicketTabs(tids, msgs) {
  const tabs = tids.map((tid) => {
    const s = msgs.find((m) => m.kind === "suggestion" && m.suggestion_id === tid);
    const label = ((s && (s.title || s.body)) || tid.slice(0, 8)).toString().slice(0, 22);
    const on = tid === selTicket ? "on" : "";
    return `<button class="sug-chip ${on}" onclick="selTicket='${tid}';if(selUser)openChat(selUser.id,selUser.name,true)">${esc(label)}</button>`;
  }).join("");
  return `<div class="sug-tickets" style="display:flex;gap:6px;flex-wrap:wrap;padding:8px 12px 0">${tabs}</div>`;
}
function dayKey(iso) { const d = new Date(iso || 0); return isNaN(d) ? "?" : d.toDateString(); }
function buildChat(msgs) {
  let lastDay = ""; let html = "";
  msgs.forEach((m) => {
    const dk = dayKey(m.created_at);
    if (dk !== lastDay) { html += `<div class="day-divider">${fmtDate(m.created_at)}</div>`; lastDay = dk; }
    html += buildSugBubble(m);
  });
  return html;
}
function setSugFromHead(status) {
  const sid = window.__curSug || "";
  const uid = window.__curUid || "";
  if (!sid) { toast("تعذر تحديد الطلب المرتبط", true); return; }
  setSugStatus(sid, uid, status);
}
function askSugStatusModal() {
  const cur = window.__curSugStatus || "pending";
  openModal();
  $("#modalBox").innerHTML = `<h3>${T("تغيير حالة الاقتراح")}</h3>
    <p class="muted" style="margin-bottom:14px">${T("اختر الحالة الجديدة للاقتراح")}</p>
    <div class="toggles">
      ${Object.entries(SUG_STATUS).map(([k, s]) => `<button class="sug-chip ${k === cur ? "on" : ""}" data-k="${k}" onclick="$$('.modal-box .sug-chip').forEach(x=>x.classList.remove('on'));this.classList.add('on');window.__sugNewStatus='${k}'">${s.label}</button>`).join("")}
    </div>
    <div class="m-actions">
      <button class="btn" onclick="const st=window.__sugNewStatus; closeModal(); if(st) setSugFromHead(st);">${T("حفظ التغييرات")}</button>
      <button class="btn ghost" onclick="closeModal()">${T("إلغاء")}</button>
    </div>`;
  window.__sugNewStatus = cur;
}
const __SUG_PLAY_SVG = `<svg viewBox="0 0 24 24"><path d="M6 5h4v14h-4M6 12h3M12 5h4v14h-4M18 12" fill="currentColor"/></svg>`;
const __SUG_PAUSE_SVG = `<svg viewBox="0 0 24 24"><path d="M7 5h5v14h-5M17 5h-2v14" fill="currentColor"/></svg>`;
const __SUG_AUD_BARS = [3,5,7,9,11,9,7,5,3,6,9,11,7,4,8,11,9,6,4,7,10,8,5,3];
function sugAudioBars(played) { return __SUG_AUD_BARS.map((h,i)=>`<span data-i="${i}" style="height:${h}px" class="${i<=played?'played':''}"></span>`).join(""); }
function sugFmt(sec){ sec=Math.max(0,Math.round(sec||0)); return `${Math.floor(sec/60)}:${String(sec%60).padStart(2,"0")}`; }
function SUG_AUDIO_BUBBLE(a, fromAdmin) {
  const url = `./api/proxy-uploads?u=/uploads/suggestion_audios/${encodeURIComponent(a)}`;
  return `<div class="sug-audio ${fromAdmin?'out':'in'}" data-aud="${encodeURIComponent(a)}" data-url="${encodeURIComponent(url)}">
    <button class="sug-audio-btn" onclick="event.stopPropagation();sugToggleAudio(this)">${__SUG_PLAY_SVG}</button>
    <div class="sug-audio-wave">${sugAudioBars(-1)}</div>
    <div class="sug-audio-time"><span class="t">0:00</span><small>0:00</small></div>
  </div>`;
}
function sugToggleAudio(btn){
  const el = btn.parentElement;
  const url = decodeURIComponent(el.dataset.url || "");
  const all = document.querySelectorAll(".sug-audio");
  all.forEach(o => { if (o !== el && o._au && !o._au.paused) o._au.pause(); });
  if (!el._au) {
    const au = new Audio();
    au.preload = "none";
    au.src = url;
    au.onerror = () => {};
    el._au = au;
    const wave = el.querySelector(".sug-audio-wave");
    if (!wave.querySelectorAll("span").length) wave.innerHTML = sugAudioBars(-1);
  }
  const au = el._au;
  const wave = el.querySelector(".sug-audio-wave");
  const tEl = el.querySelector(".sug-audio-time .t");
  const dEl = el.querySelector(".sug-audio-time small");
  if (au.paused) {
    au.play();
    btn.innerHTML = __SUG_PAUSE_SVG;
  } else if (au.currentTime > 0 && !au.ended) {
    au.pause();
    btn.innerHTML = __SUG_PLAY_SVG;
  } else {
    au.ontimeupdate = () => {
      const p = au.currentTime, d = au.duration || 0;
      if (!isNaN(p)) tEl.textContent = sugFmt(p);
      if (d && !isNaN(d)) dEl.textContent = sugFmt(d);
      if (d && !isNaN(d)) {
        const frac = p / d;
        wave.querySelectorAll("span").forEach((s,i)=>{ s.classList.toggle("played", (i*1.0)/(__SUG_AUD_BARS.length-1) <= frac); });
      }
    };
    au.onended = () => {
      btn.innerHTML = __SUG_PLAY_SVG;
      tEl.textContent = "0:00";
      wave.querySelectorAll("span").forEach(s=>s.classList.remove("played"));
    };
    btn.innerHTML = __SUG_PAUSE_SVG;
    au.play();
  }
}
function buildSugBubble(m) {
  const fromAdmin = m.is_from_admin || m.sender === "admin" || m.role === "admin";
  const sender = fromAdmin ? T("الإدارة") : (selUser?.name || T("العميل"));
  const id = m.id || "";
  const imgs = (m.images || []).map((img) => `<img class="bub-img" src="./api/proxy-uploads?u=/uploads/suggestion_images/${encodeURIComponent(img)}" onclick="window.open(this.src)" onerror="this.style.display='none'">`).join("");
  const vids = (m.videos || []).map((v) => `<video class="bub-img" controls preload="none" src="./api/proxy-uploads?u=/uploads/suggestion_videos/${encodeURIComponent(v)}"></video>`).join("");
  const auds = (m.audios || []).map((a) => SUG_AUDIO_BUBBLE(a, fromAdmin)).join("");
  const editedTag = m.is_edited ? `<span class="bub-edited">${T("معدّلة")}</span>` : "";
  const acts = id
    ? `<span class="bub-acts"><button class="bub-edit" onclick="event.stopPropagation();editSugMsg('${id}')" title="${T("تعديل")}">✎</button><button class="bub-del" onclick="event.stopPropagation();deleteSugMsg('${id}')" title="${T("حذف")}">✕</button></span>`
    : "";
  return `<div class="bub ${fromAdmin ? "out" : "in"}"><div class="bub-body">
      <span class="bub-sender ${fromAdmin ? "admin" : "user"}">${fromAdmin ? T("الإدارة") : esc(sender)}</span>
      ${acts}
      ${m.body ? `<div>${esc(m.body)}</div>` : ""}
      ${imgs}${vids}${auds}
      <div class="bub-meta">${fmtDate(m.created_at)}${editedTag}</div>
    </div></div>`;
}
async function editSugMsg(id) {
  if (!id) return;
  const cur = (window.__sugMsgs && window.__sugMsgs[id]) || "";
  openModal();
  $("#modalBox").innerHTML = `<h3>${T("تعديل الرسالة")}</h3>
    <div class="m-field"><textarea id="sugEditText" rows="4" style="width:100%">${esc(cur)}</textarea></div>
    <div class="m-actions">
      <button class="btn" onclick="saveSugMsgEdit('${id}')">${T("حفظ التعديلات")}</button>
      <button class="btn ghost" onclick="closeModal()">${T("إلغاء")}</button>
    </div>`;
}
async function saveSugMsgEdit(id) {
  const ta = $("#sugEditText");
  const body = (ta?.value || "").trim();
  if (!body) { toast(T("نص الرسالة فارغ"), true); return; }
  try {
    await api(`suggestions/messages/${id}`, { method: "PATCH", body: { body } });
    closeModal();
    toast(T("تم تعديل الرسالة"));
    if (window.__sugMsgs) window.__sugMsgs[id] = body;
    if (selUser) openChat(selUser.id, selUser.name, true);
  } catch (e) { toast(e.message, true); }
}
let __pendingAttach = null;
function openChatAttach() {
  openModal();
  $("#modalBox").innerHTML = `<h3>${T("إرفاق في الرد")}</h3>
    <p class="muted" style="margin-bottom:14px">اختر نوع الملف لإرفاقه مع ردك</p>
    <div class="toggles">
      <button class="toggle" onclick="pickChatMedia('image')">📷 صورة</button>
      <button class="toggle" onclick="pickChatMedia('video')">🎬 فيديو</button>
      <button class="toggle" onclick="pickChatMedia('audio')">🎵 ملف صوتي</button>
    </div>
    <div class="m-actions"><button class="btn ghost" onclick="closeModal()">${T("إلغاء")}</button></div>`;
}
function renderAttachChip() {
  const chip = $("#attachChip");
  if (!chip) return;
  if (!__pendingAttach) { chip.classList.remove("show"); chip.innerHTML = ""; return; }
  const ic = __pendingAttach.kind === "image" ? "🖼️" : (__pendingAttach.kind === "video" ? "🎬" : "🎤");
  const kb = __pendingAttach.file && __pendingAttach.file.size ? `(${( __pendingAttach.file.size / 1024).toFixed(0)} KB)` : "";
  chip.innerHTML = `<span class="a-ic">${ic}</span><span class="a-name">${esc(__pendingAttach.name)} ${kb} — اضغط إرسال</span><button class="a-x" onclick="clearAttach()" aria-label="إزالة">✕</button>`;
  chip.classList.add("show");
}
function clearAttach() { __pendingAttach = null; renderAttachChip(); }
function pickChatMedia(kind) {
  const input = document.createElement("input");
  input.type = "file";
  input.accept = kind === "image" ? "image/*" : (kind === "video" ? "video/*" : "audio/*");
  input.onchange = () => {
    const f = input.files && input.files[0];
    closeModal();
    if (!f) return;
    if (f.size > 25 * 1024 * 1024) { toast("الملف كبير جداً (الحد 25MB)", true); return; }
    __pendingAttach = { kind, file: f, name: f.name || "ملف" };
    renderAttachChip();
    // Send media the moment it's picked — no extra click needed.
    const msg = ($("#sugMsg")?.value || "").trim();
    if (!msg) { toast("جاري إرسال المرفق…"); sendReply(true); }
    else { toast("تم تجهيز المرفق — اضغط إرسال لإرساله مع النص"); const mi = $("#sugMsg"); if (mi) mi.focus(); }
  };
  input.click();
}
async function deleteSugMsg(id) {
  if (!id) return;
  uiConfirm(T("حذف الرسالة"), T("هل أنت متأكد من حذف هذه الرسالة؟"), async () => {
    try {
      await api(`suggestions/messages/${id}`, { method: "DELETE" });
      toast("تم حذف الرسالة");
      if (selUser) openChat(selUser.id, selUser.name, true);
    } catch (e) { toast(e.message, true); }
  }, { danger: true });
}
let __mediaRecorder = null;
let __audioChunks = [];
let __voiceActive = false;
let __voiceTimerId = null;
let __voiceStartAt = 0;
let __voiceMime = "";
function pickVoiceMime() {
  if (typeof MediaRecorder === "undefined") return "";
  const cands = ["audio/webm;codecs=opus", "audio/webm", "audio/mp4", "audio/mpeg"];
  for (const m of cands) {
    try { if (MediaRecorder.isTypeSupported && MediaRecorder.isTypeSupported(m)) return m.split(";")[0]; } catch (_) {}
  }
  return "";
}
function voiceExt(mime) {
  if (mime === "audio/mp4") return "m4a";
  if (mime === "audio/mpeg") return "mp3";
  return "webm";
}
function voiceTick() {
  const s = Math.floor((Date.now() - __voiceStartAt) / 1000);
  const el = $("#voiceSecs");
  if (el) el.textContent = `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
}
function voiceUI(on) {
  const btn = $("#voiceBtn"); if (btn) btn.classList.toggle("recording", !!on);
  const tm = $("#voiceTimer"); if (tm) tm.classList.toggle("show", !!on);
  if (on) { __voiceStartAt = Date.now(); voiceTick(); __voiceTimerId = setInterval(voiceTick, 500); }
  else { clearInterval(__voiceTimerId); __voiceTimerId = null; }
}
function toggleVoiceRecord() {
  if (__voiceActive) { stopVoiceRecord(); return; }
  if (typeof MediaRecorder === "undefined") { toast("هذا المتصفح لا يدعم تسجيل الصوت — أرفق ملفاً صوتياً جاهزاً من زر الإرفاق", true); return; }
  if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
    const insecure = location.protocol !== "https:" && location.hostname !== "localhost" && location.hostname !== "127.0.0.1";
    toast(insecure ? "التسجيل المباشر يحتاج اتصالاً آمناً (HTTPS) — أرفق ملفاً صوتياً جاهزاً من زر الإرفاق" : "تسجيل الصوت غير مدعوم في هذا المتصفح", true);
    return;
  }
  const mime = pickVoiceMime();
  navigator.mediaDevices.getUserMedia({ audio: true }).then((stream) => {
    __audioChunks = [];
    try {
      __mediaRecorder = mime ? new MediaRecorder(stream, { mimeType: mime }) : new MediaRecorder(stream);
    } catch (e) {
      stream.getTracks().forEach((t) => t.stop());
      toast("تعذر بدء التسجيل في هذا المتصفح", true); return;
    }
    __voiceMime = __mediaRecorder.mimeType || mime || "";
    __mediaRecorder.ondataavailable = (e) => { if (e.data && e.data.size > 0) __audioChunks.push(e.data); };
    __mediaRecorder.onerror = () => { try { stream.getTracks().forEach((t) => t.stop()); } catch (_) {} };
    __mediaRecorder.onstop = () => {
      try { stream.getTracks().forEach((t) => t.stop()); } catch (_) {}
      __voiceActive = false;
      voiceUI(false);
      if (__audioChunks.length === 0) { toast("التسجيل فارغ — اضغط وسجّل لمدة أطول ثم أوقف", true); return; }
      const type = (__voiceMime || "audio/webm").split(";")[0];
      const blob = new Blob(__audioChunks, { type });
      if (!blob.size) { toast("التسجيل فارغ — حاول مجدداً", true); return; }
      const file = new File([blob], `voice_${Date.now()}.${voiceExt(type)}`, { type });
      __pendingAttach = { kind: "audio", file, name: "تسجيل صوتي" };
      renderAttachChip();
      toast("تم تجهيز التسجيل — جاري الإرسال…");
      sendReply(true);
    };
    try { __mediaRecorder.start(); } catch (e) { toast("تعذر بدء التسجيل", true); return; }
    __voiceActive = true;
    voiceUI(true);
    toast("جاري التسجيل… اضغط مرة أخرى للإيقاف والإرسال");
  }).catch(() => toast("تم رفض إذن الميكروفون — اسمح بالوصول من إعدادات المتصفح", true));
}
function stopVoiceRecord() {
  try { if (__mediaRecorder && __mediaRecorder.state === "recording") __mediaRecorder.stop(); }
  catch (_) { __voiceActive = false; voiceUI(false); }
}
let __sending = false;
async function sendReply(withMedia) {
  // Re-entrancy guard: Enter key + button click must never double-send,
  // and the button can never be left stuck disabled.
  if (__sending) return;
  const msg = ($("#sugMsg")?.value || "").trim();
  if (!selUser || (!msg && !__pendingAttach)) return;
  const sendBtn = document.querySelector("#sugReplyBar .sug-send-btn");
  __sending = true;
  if (sendBtn) sendBtn.disabled = true;
  try {
    // Replies always attach to the ticket open on screen (never silently to
    // the user's latest ticket).
    const sid = selTicket || window.__curSug || "";
    if (__pendingAttach) {
      toast("جاري إرسال المرفق…");
      const fd = new FormData();
      if (msg) fd.append("body", msg);
      if (sid) fd.append("suggestion_id", sid);
      fd.append(__pendingAttach.kind === "image" ? "images" : (__pendingAttach.kind === "video" ? "videos" : "audios"), __pendingAttach.file, __pendingAttach.file.name || "file");
      await postSugMedia(fd, (pct) => {
        const chip = $("#attachChip .a-name");
        if (chip) chip.textContent = `جاري الإرسال ${pct}٪…`;
      });
      __pendingAttach = null;
      renderAttachChip();
      toast("تم إرسال الرد ✅ ووصل للمستخدم");
    } else {
      if (sid) {
        await api(`suggestions/${sid}/reply`, { method: "POST", body: { body: msg } });
      } else {
        await api(`suggestions/conversations/${selUser.id}/reply`, { method: "POST", body: { body: msg } });
      }
      toast("تم إرسال الرد ✅");
    }
    if ($("#sugMsg")) $("#sugMsg").value = "";
    await openChat(selUser.id, selUser.name, true);
    loadSuggestionUsers(true);
  } catch (e) { console.error("sendReply failed:", e); toast((e && e.message) || "فشل الإرسال", true); }
  finally { __sending = false; if (sendBtn && document.contains(sendBtn)) sendBtn.disabled = false; }
}
/// Multipart upload with progress + timeout (fetch has no upload progress,
// voice notes would otherwise look hung with the button showing 🚫).
function postSugMedia(fd, onProgress) {
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    const timer = setTimeout(() => { try { xhr.abort(); } catch (_) {} reject(new Error("انتهت مهلة الإرسال — تحقق من الاتصال وحاول مجدداً")); }, 60000);
    xhr.upload.onprogress = (e) => {
      if (e.lengthComputable && onProgress) {
        try { onProgress(Math.round((e.loaded / e.total) * 100)); } catch (_) {}
      }
    };
    xhr.onload = () => {
      clearTimeout(timer);
      if (xhr.status === 401) {
        try { $("#login").style.display = "flex"; $("#app").style.display = "none"; } catch (_) {}
        reject(new Error("unauthorized"));
        return;
      }
      let j = null;
      try { j = JSON.parse(xhr.responseText); } catch (_) {}
      if (xhr.status < 200 || xhr.status >= 300) {
        reject(new Error((j && (j.message || j.detail)) || `فشل الإرسال (خطأ ${xhr.status})`));
        return;
      }
      if (j && j.success === false) { reject(new Error(j.message || "فشل الإرسال")); return; }
      resolve(j);
    };
    xhr.onerror = () => { clearTimeout(timer); reject(new Error("تعذر الاتصال بالسيرفر")); };
    xhr.onabort = () => { clearTimeout(timer); reject(new Error("انتهت مهلة الإرسال — تحقق من الاتصال وحاول مجدداً")); };
    xhr.open("POST", `./api/suggestions/conversations/${selUser.id}/reply-media`);
    xhr.send(fd);
  });
}
async function setSugStatus(sid, uid, status) {
  try {
    await api(`suggestions/${sid}`, { method: "PATCH", body: { status } });
    toast("تم تحديث الحالة: " + (SUG_STATUS[status]?.label || status));
    if (uid) openChat(uid, selUser?.name || "", true);
    loadSuggestionUsers(true);
  } catch (e) { toast(e.message, true); }
}
/* ── Platform controls (sections/buttons/trial/force) ── */
let controlsTab = "personal";
let controlsDisCache = { personal: [], business: [] };
async function renderControls(c) {
  c.innerHTML = '<div class="empty">جاري التحميل…</div>';
  try {
    const r = await api("admin/controls");
    const d = r.data || {};
    const maint = d.maintenance || {};
    const trial = d.trial || {};
    const disPre = d.disabled_buttons || {};
    const isSugDisabled = (disPre.personal || []).includes("personal/suggestions");
    c.innerHTML = `
      <div class="filterbar" style="align-items:center;justify-content:space-between">
        <b style="font-size:14px;color:var(--text)">⚙️ إعدادات التحكم في النظام</b>
        <button class="btn" style="width:auto" onclick="saveControls(true)">💾 حفظ التغييرات وتطبيقها فوراً</button>
      </div>
      <div class="card"><h3><span class="dot"></span>وضع الصيانة</h3>
        <p class="muted" style="margin-bottom:12px">فعّل الصيانة على أي قسم — المستخدمون داخل القسم سيُخرجون فوراً، ولا يمكن الدخول إليه حتى إلغائها.</p>
        <div class="toggles">
          <label class="toggle"><b>القسم الشخصي</b><span class="switch ${(maint.personal ? "on" : "")}" id="mPer"></span></label>
          <label class="toggle"><b>قسم الأعمال</b><span class="switch ${(maint.business ? "on" : "")}" id="mBiz"></span></label>
          <label class="toggle"><b>التطبيق كله</b><span class="switch ${(maint.all ? "on" : "")}" id="mAll"></span></label>
          <label class="toggle"><b>التطوير والاقتراحات</b><span class="switch ${(isSugDisabled ? "on" : "")}" id="mSug"></span><small>إيقاف قسم التطوير والاقتراحات</small></label>
        </div>
        <div class="mfield" style="margin-top:14px"><label>رسالة الصيانة التي تظهر للمستخدم</label><input id="mMessage" value="${esc(maint.message || "")}" placeholder="نقوم بالصيانة حالياً…"></div>
        <button class="btn" style="margin-top:10px" onclick="saveControls()">حفظ إعدادات الصيانة</button>
      </div>
      <div class="card"><h3><span class="dot"></span>الأزرار حسب القسم</h3>
        <div class="filterbar">
          <button class="btn" onclick="controlsTabSwitch('personal')">القسم الشخصي</button>
          <button class="btn ghost" onclick="controlsTabSwitch('business')">قسم الأعمال</button>
        </div>
        <div id="btnToggles"></div>
        <button class="btn" style="margin-top:12px" onclick="saveControls()">حفظ الأزرار المعطلة</button>
      </div>
      <div class="card"><h3><span class="dot"></span>الاشتراك التجريبي والإجبار</h3>
        <label class="toggle"><b>تفعيل التجريبي</b><span class="switch ${(trial.enabled === false ? "" : "on")}" id="trOn"></span></label>
        <div class="mfield" style="margin-top:14px"><label>مدة الاشتراك التجريبي</label>
          <div style="display:flex;gap:8px;align-items:center">
            <input id="trValue" type="number" min="1" value="${trial.value ?? trial.hours ?? 24}" style="max-width:120px">
            <select id="trUnit" style="max-width:140px">
              ${["hours","days","weeks","months"].map((u) => `<option value="${u}" ${((trial.unit || "hours") === u) ? "selected" : ""}>${({hours:"ساعات",days:"أيام",weeks:"أسابيع",months:"أشهر"})[u]}</option>`).join("")}
            </select>
          </div>
        </div>
        <label class="toggle" style="margin-top:12px"><b>إجبار الاشتراك المدفوع (لا تجريبي)</b>
          <span class="switch ${(d.force_paid_subscription ? "on" : "")}" id="forcePaid"></span></label>
        <button class="btn" style="margin-top:12px" onclick="saveControls()">حفظ إعدادات الاشتراك</button>
      </div>
      <div class="card"><h3><span class="dot"></span>عداد القلق والمستخدمين (في صفحة الباقات)</h3>
        <p class="muted" style="margin-bottom:12px">(الخصومات على الأسعار تُدار من قسم "الباقات والأسعار" عند تعديل كل باقة)</p>
        <label class="toggle" style="margin-top:12px"><b>تفعيل عداد القلق (تنازلي وهمي)</b>
          <span class="switch ${((d.urgency_countdown?.enabled) ? "on" : "")}" id="urgOn"></span></label>
        <div class="grid2">
          <div class="mfield"><label>الشخصية (ثانية ≥ 60)</label><input id="urgPersonal" type="number" min="60" value="${(d.urgency_countdown?.personal) ?? 540}"></div>
          <div class="mfield"><label>الأعمال (ثانية ≥ 60)</label><input id="urgBusiness" type="number" min="60" value="${(d.urgency_countdown?.business) ?? 480}"></div>
        </div>
        <div class="mfield"><label>أعمال+شخصي (ثانية ≥ 60)</label><input id="urgPremium" type="number" min="60" value="${(d.urgency_countdown?.premium) ?? 420}"></div>
        <label class="toggle" style="margin-top:14px"><b>تفعيل عداد المستخدمين المدفوعين (وهمي)</b>
          <span class="switch ${((d.subscriber_counter?.enabled) ? "on" : "")}" id="subCountOn"></span></label>
        <div class="grid2">
          <div class="mfield"><label>البداية (كم مستخدم)</label><input id="subBase" type="number" min="1" value="${(d.subscriber_counter?.base) ?? 1240}"></div>
          <div class="mfield"><label>الزيادة كل (ثانية)</label><input id="subInterval" type="number" min="1" value="${(d.subscriber_counter?.interval_seconds) ?? 10}"></div>
        </div>
        <div class="mfield"><label>كم يزداد في كل مرة</label><input id="subStep" type="number" min="1" value="${(d.subscriber_counter?.step) ?? 1}"></div>
        <button class="btn" style="margin-top:12px" onclick="saveControls()">حفظ إعدادات التسويق</button>
      </div>`;
    const dis = d.disabled_buttons || {};
    controlsDisCache = {
      personal: [...(dis.personal || [])],
      business: [...(dis.business || [])],
    };
    const currentDisabled = controlsTab === "personal" ? (dis.personal || []) : (dis.business || []);
    const names = SECTION_BTNS[controlsTab] || [];
    $("#btnToggles").innerHTML = names.length ? names.map((b) => {
        const inList = currentDisabled.includes(b);
        return `<label class="toggle"><b>${esc(btnLabel(b))}</b><span class="switch ${inList ? "on" : ""}" onclick="this.classList.toggle('on')" data-k="${b}" data-m="${controlsTab}"></span></label>`;
      }).join("") : '<div class="empty">لا توجد أزرار</div>';
    const hook = (id, cb) => { const el = $(id); if (el) el.onclick = () => { el.classList.toggle("on"); cb(); }; };
    hook("#mPer", () => { if ($("#mPer").classList.contains("on")) $("#mAll").classList.remove("on"); });
    hook("#mBiz", () => { if ($("#mBiz").classList.contains("on")) $("#mAll").classList.remove("on"); });
    hook("#mAll", () => { ["#mPer", "#mBiz"].forEach((s) => $(s).classList.remove("on")); });
    hook("#trOn", () => {});
    hook("#forcePaid", () => { if ($("#forcePaid").classList.contains("on")) $("#trOn").classList.remove("on"); });
    hook("#urgOn", () => {});
    hook("#subCountOn", () => {});
    hook("#mSug", () => {});
  } catch (e) { c.innerHTML = `<div class="empty">${esc(e.message)}</div>`; }
}
function controlsCollectDom() {
  const out = { personal: [], business: [] };
  $$("#btnToggles .switch").forEach((s) => {
    if (s.classList.contains("on")) {
      const m = s.getAttribute("data-m");
      const k = s.getAttribute("data-k");
      if (out[m]) out[m].push(k);
    }
  });
  return out;
}
function controlsTabSwitch(tab) {
  if ($("#btnToggles") && $$("#btnToggles .switch").length) {
    controlsDisCache[controlsTab] = controlsCollectDom()[controlsTab];
  }
  controlsTab = tab;
  renderControls($("#content"));
}
function discObj(percentId, endId, startId) {
  const pct = parseInt($(percentId)?.value) || 0;
  if (pct <= 0) return null;
  const endVal = $(endId)?.value || "";
  const startVal = (startId && $(startId)?.value) || "";
  return { percent: Math.min(90, pct), starts_on: startVal, ends_on: endVal };
}

async function saveControls(showSuccess = false) {
  try {
    // Preserve discounts which are managed from the plans section.
    let liveDiscounts = window.__discounts || {};
    try {
      const cur = await api("admin/controls");
      liveDiscounts = ((cur.data || {}).discounts || {});
      window.__discounts = liveDiscounts;
    } catch (e) {}
    const dom = controlsCollectDom();
    const hasDom = $$("#btnToggles .switch").length > 0;
    const dis = {
      personal: hasDom ? dom.personal : controlsDisCache.personal,
      business: hasDom ? dom.business : controlsDisCache.business,
    };
    // Handle suggestions maintenance toggle
    const sugToggle = $("#mSug");
    if (sugToggle) {
      const sugOn = sugToggle.classList.contains("on");
      const hasSug = dis.personal.includes("personal/suggestions");
      if (sugOn && !hasSug) dis.personal.push("personal/suggestions");
      if (!sugOn && hasSug) dis.personal = dis.personal.filter((k) => k !== "personal/suggestions");
    }
    const body = {
      maintenance: {
        personal: $("#mPer").classList.contains("on"),
        business: $("#mBiz").classList.contains("on"),
        all: $("#mAll").classList.contains("on"),
        message: $("#mMessage").value,
      },
      disabled_buttons: dis,
      trial: (() => {
        // Canonical shape {unit, value} + mirrored legacy keys so every
        // reader (backend, current app, older builds) agrees on one duration.
        const unit = ($("#trUnit") || {}).value || "hours";
        let val = parseInt(($("#trValue") || {}).value) || 1;
        if (val < 1) val = 1;
        let legHours = val, legDays = 1;
        if (unit === "hours") { legHours = val; legDays = Math.max(1, Math.ceil(val / 24)); }
        else if (unit === "days") { legHours = val * 24; legDays = val; }
        else if (unit === "weeks") { legHours = val * 168; legDays = val * 7; }
        else { legHours = val * 720; legDays = val * 30; }
        return { enabled: $("#trOn").classList.contains("on"), unit, value: val, hours: legHours, days: legDays };
      })(),
      force_paid_subscription: $("#forcePaid").classList.contains("on"),
      // Discounts live in the plans section and are preserved here as-is.
      discounts: (window.__discounts || {}),
      // ── Marketing extras (urgency / paid counter) ──
      urgency_countdown: {
        enabled: !!(typeof $("#urgOn") !== "undefined" && $("#urgOn").classList.contains("on")),
        personal: Math.max(60, parseInt($("#urgPersonal")?.value) || 540),
        business: Math.max(60, parseInt($("#urgBusiness")?.value) || 480),
        premium: Math.max(60, parseInt($("#urgPremium")?.value) || 420),
      },
      subscriber_counter: {
        enabled: !!(typeof $("#subCountOn") !== "undefined" && $("#subCountOn").classList.contains("on")),
        base: parseInt($("#subBase")?.value) || 1240,
        step: parseInt($("#subStep")?.value) || 1,
        interval_seconds: parseInt($("#subInterval")?.value) || 10,
      },
    };
    await api("admin/controls", { method: "PUT", body });
    toast(showSuccess ? "تم حفظ التغييرات وتطبيقها على جميع المستخدمين فوراً" : "تم حفظ الإعدادات — طُبقت على التطبيق");
    if (showSuccess) renderControls($("#content"));
  } catch (e) { toast(e.message, true); }
}

/* ── Subscription reports ── */
async function renderReports(c) {
  c.innerHTML = `<div class="card"><h3><span class="dot"></span>التقرير</h3>
    <div class="filterbar">
      <input type="date" id="repFrom"><input type="date" id="repTo">
      <button class="btn" onclick="loadReport()">عرض التقرير</button>
    </div>
    <div id="repBody"></div></div>`;
  await loadReport();
}
async function loadReport() {
  const q = new URLSearchParams();
  if ($("#repFrom").value) q.set("from", $("#repFrom").value);
  if ($("#repTo").value) q.set("to", $("#repTo").value);
  try {
    const [r, p] = await Promise.all([
      api(`admin/subscription-requests/report?${q.toString()}`),
      api(`admin/subscriptions/payment-report?${q.toString()}`),
    ]);
    const d = r.data || {};
    const st = d.by_status || {};
    const kur = d.amounts_by_currency || {};
    const pay = p.data || {};
    const intl = pay.international_by_currency || [];
    const plans = pay.plan_distribution || [];
    const logs = pay.recent_payments || [];
    const planAr = { personal: "شخصية", business: "أعمال", premium: "أعمال + شخصي" };
    $("#repBody").innerHTML = `
      <div class="row">
        <div class="kpi gold"><div class="v">${d.total || 0}</div><div class="l">إجمالي الطلبات</div></div>
        ${Object.entries(st).map(([k, v]) => `<div class="kpi"><div class="v">${v}</div><div class="l">${esc(k)}</div></div>`).join("")}
      </div>
      <div class="card"><h3><span class="dot"></span>المبالغ حسب العملة</h3>
        ${Object.entries(kur).map(([k, v]) => `<div style="display:flex;justify-content:space-between;padding:8px;border-bottom:1px solid #202020"><b>${esc(k)}</b><b style="color:#7fff8b">${fmtMoney(v, k)}</b></div>`).join("") || '<div class="empty">لا توجد مبالغ</div>'}
      </div>
      <div class="card"><h3><span class="dot"></span>الاشتراكات المدفوعة — محلي مقابل دولي</h3>
        <div class="row">
          <div class="kpi info"><div class="v">${pay.local_paid_count ?? 0}</div><div class="l">مدفوعة محليًا (سند + اعتماد)</div></div>
          <div class="kpi ok"><div class="v">${pay.international_paid_count ?? 0}</div><div class="l">مدفوعة دوليًا (بطاقات)</div></div>
        </div>
      </div>
      <div class="card"><h3><span class="dot"></span>المبالغ الدولية حسب العملة</h3>
        ${intl.map((x) => `<div style="display:flex;justify-content:space-between;padding:8px;border-bottom:1px solid #202020"><b>${esc(x.currency)} <span class="muted">(${x.count})</span></b><b style="color:#7fff8b">${fmtMoney(x.amount, x.currency)}</b></div>`).join("") || '<div class="empty">لا توجد مدفوعات دولية</div>'}
      </div>
      <div class="card"><h3><span class="dot"></span>توزيع الاشتراكات حسب الخطة</h3>
        <div class="row">
          ${plans.map((x) => `<div class="kpi"><div class="v">${x.count}</div><div class="l">${esc(planAr[x.plan] || x.plan)}</div></div>`).join("") || '<div class="empty">لا توجد بيانات</div>'}
        </div>
      </div>
      <div class="card"><h3><span class="dot"></span>سجل عمليات الدفع (${pay.total || 0})</h3>
        ${logs.map((x) => `<div style="display:flex;justify-content:space-between;gap:8px;padding:8px;border-bottom:1px solid #202020;flex-wrap:wrap">
          <span><b>${esc(x.invoice_number || "—")}</b> <span class="muted">${x.channel === "international" ? "دولي 💳" : "محلي 🧾"}</span><br>
          <span class="muted">${esc(x.user_name || x.org_name || "")} · ${esc(planAr[x.plan_name] || x.plan_name || "")}</span></span>
          <b style="color:#7fff8b">${fmtMoney(x.amount, x.currency)}</b></div>`).join("") || '<div class="empty">لا توجد عمليات</div>'}
      </div>`;
  } catch (e) { $("#repBody").innerHTML = `<div class="empty">${esc(e.message)}</div>`; }
}

/* ── Admin notify emails ── */
async function renderNotifyEmails(c) {
  c.innerHTML = '<div class="empty">جاري التحميل…</div>';
  try {
    const r = await api("admin/notify-emails");
    const list = r.data?.emails || [];
    c.innerHTML = `<div class="card"><h3><span class="dot"></span>إيميلات يتم إشعارها بطلبات الاشتراك</h3>
      <div id="neList"></div>
      <div style="display:flex;gap:8px;margin-top:12px">
        <input id="neInput" placeholder="admin@example.com">
        <button class="btn" style="width:auto" onclick="addNe()">إضافة</button>
      </div>
      <button class="btn" style="margin-top:10px" onclick="saveNe()">حفظ القائمة</button></div>`;
    renderNeList(list);
    window.__neList = list.slice();
  } catch (e) { c.innerHTML = `<div class="empty">${esc(e.message)}</div>`; }
}
function renderNeList(list) {
  $("#neList").innerHTML = list.length
    ? list.map((e, i) => `<div style="display:flex;justify-content:space-between;padding:8px;border-bottom:1px solid #202020"><span>${esc(e)}</span><button class="tbtn danger" onclick="removeNe(${i})">حذف</button></div>`).join("")
    : '<div class="empty">لا توجد إيميلات</div>';
}
function addNe() {
  const v = $("#neInput").value.trim();
  if (!v || !window.__neList.includes(v)) window.__neList.push(v);
  $("#neInput").value = "";
  renderNeList(window.__neList);
}
function removeNe(i) { window.__neList.splice(i, 1); renderNeList(window.__neList); }
async function saveNe() {
  try { await api("admin/notify-emails", { method: "PUT", body: { emails: window.__neList || [] } }); toast("تم حفظ إيميلات الاشعار"); }
  catch (e) { toast(e.message, true); }
}

/* ── Staff & permissions ── */
async function renderStaff(c) {
  c.innerHTML = '<div class="empty">جاري التحميل…</div>';
  try {
    const perms = await api("admin/admin-permissions/catalog");
    const cat = perms.data?.catalog || {};
    window.__permCat = cat;
    const r = await api("admin/admin-permissions");
    const staff = r.data?.users || [];
    c.innerHTML = `
      <div class="card" style="display:flex;align-items:center;gap:12px;margin-bottom:14px;cursor:pointer" onclick="go('dashboard')">
        <span style="font-size:20px">→</span>
        <b>الرجوع</b>
      </div>
      <div class="card"><h3><span class="dot"></span>الموظفون الإداريون</h3>
        <div id="staffRows"></div>
        <div class="card" style="background:var(--surface2);border:1px solid var(--border);margin-top:14px">
          <div style="display:flex;gap:10px;justify-content:space-between;align-items:center;margin-bottom:12px;flex-wrap:wrap">
            <b style="font-size:14px">➕ إضافة موظف جديد</b>
            <span class="muted">بعد الإنشاء تفتح صلاحياته مباشرة</span>
          </div>
          <div class="grid2">
            <div class="mfield"><label>اسم الموظف</label><input id="stName" placeholder="مثال: أحمد محمد"></div>
            <div class="mfield"><label>اسم المستخدم / البريد للدخول</label><input id="stEmail" type="email" placeholder="employee@fyona.erp"></div>
          </div>
          <div class="grid2">
            <div class="mfield"><label>كلمة المرور</label><input id="stPass" type="password" placeholder="••••••••"></div>
            <div class="mfield"><label>الاختصاص الوظيفي</label><select id="stSection">
              <option value="all">كل الأقسام</option>
              <option value="personal">القسم الشخصي فقط</option>
              <option value="business">قسم الأعمال فقط</option>
            </select></div>
          </div>
          <button class="btn" style="width:auto" onclick="createStaff()">إنشاء الموظف</button>
        </div></div>
      <div class="card" id="permCard" style="display:none"><h3><span class="dot"></span>صلاحيات الموظف</h3>
        <div class="filterbar">
          <span class="muted" style="font-size:12px">اختصار سريع:</span>
          <button class="tbtn norm" onclick="applyPermPreset('all')">كل الصلاحيات</button>
          <button class="tbtn warn" onclick="clearPerms()">مسح الكل</button>
        </div>
        <div id="permBox"></div>
        <button class="btn" style="margin-top:12px" onclick="saveStaffPerms()">حفظ الصلاحيات</button>
      </div>`;
    renderStaffRows(staff, cat);
  } catch (e) { c.innerHTML = `<div class="empty">${esc(e.message)}</div>`; }
}
function renderStaffRows(staff, cat) {
  $("#staffRows").innerHTML = staff.length
    ? staff.map((u) => {
        const perms = u.admin_permissions || [];
        const isAll = !perms.length;
        return `<div class="staff-card" onclick="openStaffPerms('${u.id}')">
          <div class="avatar-sm">${esc((u.full_name || "؟").charAt(0))}</div>
          <div class="tx-mid" style="min-width:130px">
            <b style="color:var(--text);font-size:13.5px;word-break:break-word;overflow-wrap:anywhere">${esc(u.full_name || "—")}</b>
            <div style="direction:ltr;text-align:start;font-size:11.5px;color:var(--text-3);margin-top:2px;word-break:break-word">${esc(u.email || "")}</div>
          </div>
          <div class="tx-chips">${roleBadge(u.role || "admin")} <span class="tag">${isAll ? T("كل الصلاحيات") : perms.length + " " + T("صلاحية")}</span></div>
        </div>`;
      }).join("")
    : (uiEmpty("staff", "لا يوجد موظفون", ""));
}
const ACT_AR = { create: "إنشاء", read: "عرض", update: "تعديل", delete: "حذف" };
/* Permission buttons mirror EXACTLY the admin panel sections (MENU keys) —
   nothing more, nothing less. Each section maps to the backend resources its
   pages actually call, so granting a button makes that button work. */
const PERM_SECTIONS = [
  { key: "dashboard", label: "لوحة التحكم", resources: ["dashboard", "subscription_requests"] },
  { key: "subscriptions", label: "طلبات الاشتراك", resources: ["subscription_requests"] },
  { key: "reports", label: "تقارير الاشتراكات", resources: ["subscription_requests"] },
  { key: "users", label: "المستخدمون", resources: ["admin_users", "organizations"] },
  { key: "plans", label: "الباقات والأسعار", resources: ["plans", "admin_controls", "exchange_rates"] },
  { key: "controls", label: "الأقسام والأزرار", resources: ["admin_controls"] },
  { key: "staff", label: "الموظفون والصلاحيات", resources: ["admin_permissions", "admin_users"] },
  { key: "notify_emails", label: "إيميلات الاشعارات", resources: ["admin_settings"] },
  { key: "accounting", label: "البنوك والعمليات", resources: ["accounting"] },
  { key: "notifications", label: "الإشعارات", resources: ["notifications"] },
  { key: "banners", label: "اللافتات", resources: ["banners"] },
  { key: "suggestions", label: "الاقتراحات", resources: ["suggestions"] },
];
function permResourceAr(res, cat) {
  const ar = { dashboard: "لوحة التحكم", plans: "الباقات", subscription_requests: "طلبات الاشتراك", accounting: "المحاسبة والبنوك", api_keys: "مفاتيح API", notifications: "الإشعارات", trash: "سلة المهملات", export: "التصدير", organizations: "المنظمات", settings: "إعدادات النظام", admin_settings: "إعدادات الإدارة", admin_controls: "التحكم بالأزرار", currencies: "العملات", banners: "اللافتات", admin_users: "المستخدمون", admin_roles: "الأدوار", branches: "الفروع", modules: "الوحدات", audit: "سجل التدقيق", email: "إعدادات البريد", backups: "النسخ الاحتياطي", maintenance: "الصيانة", health: "حالة النظام", system: "معلومات النظام", admin_permissions: "صلاحيات المشرفين", exchange_rates: "أسعار الصرف", personal_finance: "البيانات الشخصية", suggestions: "الاقتراحات" };
  return ar[res] || (cat && cat.title) || res;
}
async function openStaffPerms(id) {
  window.__staffId = id;
  const cat = window.__permCat || {};
  try {
    const r = await api("admin/admin-permissions");
    const u = (r.data?.users || []).find((x) => x.id === id);
    const perms = u?.admin_permissions || []; // e.g. ["plans:read","plans:update"]
    const hasAll = !u?.admin_permissions || u.admin_permissions.length === 0;
    $("#permCard").style.display = "block";
    $("#permCard").scrollIntoView({ behavior: "smooth", block: "start" });
    $("#permBox").innerHTML = PERM_SECTIONS.map((sec) => {
      const toggles = sec.resources.map((res) => {
        const info = cat[res] || {};
        return (info.actions || ["read"]).map((a) => {
          const code = `${res}:${a}`;
          const on = hasAll || perms.includes(code);
          return `<label class="toggle" style="padding:7px 11px"><b>${esc(ACT_AR[a] || a)}${sec.resources.length > 1 ? ` · ${esc(permResourceAr(res, info))}` : ""}</b><span class="switch ${on ? "on" : ""}" onclick="this.classList.toggle('on')" data-code="${code}"></span></label>`;
        }).join("");
      }).join("");
      return `<div class="perm-group" data-sec="${sec.key}">
          <div class="perm-group-head">
            <b>${icon("settings02", 16)} ${esc(sec.label)}</b>
            <div class="chat-actions">
              <button class="tbtn sm norm" onclick="permGroupSecAll('${sec.key}')">${T("تحديد الكل")}</button>
              <button class="tbtn sm norm" onclick="permGroupSecNone('${sec.key}')">${T("إفراغ")}</button>
            </div>
          </div>
          <div class="toggles">${toggles}</div>
        </div>`;
    }).join("");
  } catch (e) { toast(e.message, true); }
}
function permGroupSecCodes(secKey) {
  const sec = PERM_SECTIONS.find((s) => s.key === secKey);
  if (!sec) return [];
  const cat = window.__permCat || {};
  const out = [];
  sec.resources.forEach((res) => {
    ((cat[res] || {}).actions || ["read"]).forEach((a) => out.push(`${res}:${a}`));
  });
  return out;
}
function permGroupSecAll(secKey) {
  const want = new Set(permGroupSecCodes(secKey));
  $$("#permBox .switch").forEach((s) => {
    if (want.has(s.getAttribute("data-code"))) s.classList.add("on");
  });
}
function permGroupSecNone(secKey) {
  const want = new Set(permGroupSecCodes(secKey));
  $$("#permBox .switch").forEach((s) => {
    if (want.has(s.getAttribute("data-code"))) s.classList.remove("on");
  });
}
async function saveStaffPerms() {
  const codes = window.__staffId ? [] : [];
  $$("#permBox .switch").forEach((s) => { if (s.classList.contains("on")) codes.push(s.getAttribute("data-code")); });
  // group into { resource: [actions] }
  const map = {};
  codes.forEach((c) => { const [res, act] = c.split(":"); (map[res] = map[res] || []).push(act); });
  try {
    await api(`admin/admin-permissions/${window.__staffId}`, { method: "PUT", body: { is_platform_admin: true, permissions: Object.entries(map).map(([res, actions]) => ({ resource: res, actions })) } });
    toast("تم حفظ الصلاحيات"); $("#permCard").style.display = "none"; renderStaff($("#content"));
  } catch (e) { toast(e.message, true); }
}
function applyPermPreset(section) {
  const cat = window.__permCat || {};
  // Only the neutral presets remain (sections are toggled per admin button
  // above): all catalog codes, or clear via clearPerms().
  const codes = Object.entries(cat).reduce((acc, [r, info]) => { (info.actions || ["read"]).forEach((a) => acc.push(`${r}:${a}`)); return acc; }, []);
  const wanted = section === "all" ? codes : [];
  $$("#permBox .switch").forEach((s) => {
    const code = s.getAttribute("data-code");
    s.classList.toggle("on", wanted.includes(code));
  });
}
function clearPerms() {
  $$("#permBox .switch").forEach((s) => s.classList.remove("on"));
}
function permGroupAll(btn, res) {
  $$("#permBox .switch").forEach((s) => { if (s.getAttribute("data-code").startsWith(res + ":")) s.classList.add("on"); });
}
function permGroupNone(btn, res) {
  $$("#permBox .switch").forEach((s) => { if (s.getAttribute("data-code").startsWith(res + ":")) s.classList.remove("on"); });
}
async function createStaff() {
  const nameEl = $("#stName"), emailEl = $("#stEmail"), passEl = $("#stPass"), sectEl = $("#stSection");
  if (!nameEl || !emailEl || !passEl || !sectEl) { toast("الرجاء إعادة تحميل الصفحة", true); return; }
  const name = nameEl.value.trim(), email = emailEl.value.trim(), pass = passEl.value.trim();
  const section = sectEl.value;
  if (!name || !email || !pass) { toast("أكمل اسم الموظف ويوزر الدخول وكلمة المرور", true); return; }
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) { toast("أدخل بريداً صحيحاً ليكون يوزر الدخول", true); return; }
  try {
    const r = await api("admin/users", { method: "POST", body: { full_name: name, email, password: pass, role: "admin", is_platform_admin: true, admin_section: section } });
    const uid = r.data?.id || r.data?.user?.id;
    toast(section === "all" ? "تم إنشاء الموظف بكل الصلاحيات" : "تم إنشاء الموظف — اضبط صلاحياته الآن");
    if (uid) {
      await openStaffPerms(uid);
      if (section !== "all") applyPermPreset(section);
    }
    renderStaff($("#content"));
  } catch (e) { toast(e.message, true); }
}

/* ── Modal helpers ── */
function openModal() { $("#modal").classList.add("open"); document.body.classList.add("modal-open"); }
function closeModal() { $("#modal").classList.remove("open"); document.body.classList.remove("modal-open"); }
$("#modal").addEventListener("click", (e) => { if (e.target.id === "modal") closeModal(); });

/* ── Proof lightbox (reliable preview inside the page, no window.open) ── */
async function openProof(url) {
  const lb = $("#lightbox");
  const content = $("#lbContent");
  if (!lb || !content) return;
  const isPdf = /\.pdf$/i.test(url) || /\.pdf$/i.test(decodeURIComponent(decodeURIComponent(url)));
  lb.classList.add("open");
  content.innerHTML = '<div class="lb-empty">جاري تحميل السند…</div>';
  try {
    // For images: let the browser load the URL directly (same-origin proxy) —
    // far more reliable than fetch+blob on mobile. For PDFs we try fetch+blob
    // so we can render inside an <iframe>; if that fails we still offer a
    // direct link as last resort.
    if (!isPdf) {
      content.innerHTML = `<img src="${url}" alt="سند" onload="this.closest('.lb-content').classList.add('ready')" onerror="this.parentElement.innerHTML='<div class=lb-empty>تعذر تحميل الصورة — اضغط هنا لفتحها مباشرة</div>'">`;
      // Re-check a moment later: if neither load nor error fired, try blob path.
      const img = content.querySelector('img');
      setTimeout(() => {
        if (img && !img.complete) {
          fallbackProofFetch(url, content, isPdf);
        }
      }, 6000);
      return;
    }
    await fallbackProofFetch(url, content, isPdf);
  } catch (e) {
    content.innerHTML =
      `<div class="lb-empty">تعذر تحميل السند — <a href="${url}" target="_blank" style="color:#fff;text-decoration:underline">افتحه هنا ↗</a></div>`;
  }
}

async function fallbackProofFetch(url, content, isPdf) {
  try {
    const res = await fetch(url);
    if (!res.ok) throw new Error('HTTP ' + res.status);
    const type = res.headers.get("content-type") || "";
    const blob = await res.blob();
    const objUrl = URL.createObjectURL(blob);
    setTimeout(() => URL.revokeObjectURL(objUrl), 180000);
    if (isPdf || type.includes("pdf")) {
      content.innerHTML = `<iframe src="${objUrl}" title="سند PDF"></iframe>`;
    } else {
      content.innerHTML = `<img src="${objUrl}" alt="سند">`;
    }
  } catch (e) {
    content.innerHTML =
      `<div class="lb-empty">تعذر تحميل السند — <a href="${url}" target="_blank" style="color:#fff;text-decoration:underline">افتحه هنا ↗</a></div>`;
  }
}
function closeLightbox() {
  $("#lightbox").classList.remove("open");
  $("#lbContent").innerHTML = "";
}
document.addEventListener("keydown", (e) => { if (e.key === "Escape") { closeLightbox(); closeModal(); } });

const renderers = {
  dashboard: renderDashboard, subscriptions: renderSubscriptions, users: renderUsers,
  orgs: renderOrgs, plans: renderPlans, accounting: renderAccounting,
  notifications: renderNotifications, banners: renderBanners, suggestions: renderSuggestions,
  controls: renderControls, reports: renderReports, staff: renderStaff, notify_emails: renderNotifyEmails,
};

/* ── Login / logout ── */
async function doLogin() {
  $("#loginErr").style.display = "none";
  $("#loginBtn").disabled = true;
  $("#loginBtn").innerHTML = '<span class="spin"></span> جارٍ الدخول…';
  try {
    const r = await api("login", { method: "POST", body: { email: $("#loginEmail").value, password: $("#loginPass").value } });
    if (r.success) { session.name = r.data?.name || "FYONA Admin"; enterApp(); }
    else { showLoginErr(r.message); }
  } catch (e) { showLoginErr(e.message); }
  $("#loginBtn").disabled = false;
  $("#loginBtn").innerHTML = "دخول";
}
function showLoginErr(m) { const el = $("#loginErr"); el.textContent = m; el.style.display = "block"; }
function enterApp() {
  $("#login").style.display = "none";
  $("#app").style.display = "flex";
  go("dashboard");
  // Admin bell: live badge + feed; poll periodically.
  loadBellFeed(true);
  setInterval(() => { loadBellFeed(true); }, 60000);
}
async function logout() {
  try { await api("logout", { method: "POST" }); } catch (e) {}
  location.reload();
}

// Cold boot: auto-enter only if an authenticated session exists.
(async () => {
  try {
    const v = await api("admin/controls");
    if (v.success) enterApp();
  } catch (e) { /* stay on login */ }
})();