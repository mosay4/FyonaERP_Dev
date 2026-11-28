"""Two test databases for FYONA's smart import:
 1) FYONA-Import-Ready.db  — tables and columns exactly as FYONA's import expects (everything goes in, nothing refused)
 2) FYONA-Import-Other-App.db — another (Arabic) program: different tables/columns, branches, currency ids,
    unit prices, history tables and a few deliberately wrong rows."""
import os, random, sqlite3, struct, sys, zlib, json

OUT = sys.argv[1]
random.seed(7)

def png(seed, label_color):
    """A real 96x96 PNG: soft gradient card with a round 'product' badge."""
    w = h = 96
    r0, g0, b0 = label_color
    rows = []
    for y in range(h):
        row = bytearray([0])
        for x in range(w):
            dx, dy = x - 48, y - 52
            inside = dx * dx + dy * dy < 30 * 30
            t = y / h
            if inside:
                r, g, b = int(r0 * .85), int(g0 * .85), int(b0 * .85)
                if dx * dx + (dy + 12) ** 2 < 8 * 8:
                    r, g, b = 255, 255, 255
            else:
                r = int(255 - (255 - r0) * .25 * t); g = int(255 - (255 - g0) * .25 * t); b = int(255 - (255 - b0) * .25 * t)
            row += bytes((r, g, b))
        rows.append(bytes(row))
    raw = zlib.compress(b''.join(rows), 9)
    def chunk(t, d):
        return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) + chunk(b'IDAT', raw) + chunk(b'IEND', b'')

CATS = [('الأرز والحبوب', (196, 160, 90), ['أرز بسمتي', 'أرز مصري', 'عدس أحمر', 'فول مدمس', 'حمص حب', 'برغل']),
        ('الزيوت والسمن', (220, 180, 40), ['زيت دوار الشمس', 'زيت ذرة', 'زيت زيتون', 'سمن نباتي', 'سمن بلدي']),
        ('الألبان', (90, 150, 220), ['حليب طويل الأجل', 'لبن زبادي', 'جبنة بيضاء', 'جبنة شيدر', 'قشطة']),
        ('المشروبات', (200, 60, 60), ['مياه معدنية', 'عصير برتقال', 'عصير مانجو', 'مشروب غازي', 'شاي أسود', 'قهوة عربية']),
        ('المعلبات', (120, 120, 120), ['تونة', 'فول معلب', 'ذرة حلوة', 'معجون طماطم', 'بازلاء']),
        ('الحلويات', (230, 110, 160), ['شوكولاتة', 'بسكويت', 'كعك', 'حلاوة طحينية', 'مربى فراولة']),
        ('المنظفات', (60, 170, 150), ['مسحوق غسيل', 'سائل جلي', 'معطر أرضيات', 'مناديل', 'صابون يد']),
        ('البهارات', (170, 90, 40), ['كمون', 'فلفل أسود', 'كركم', 'هيل', 'قرفة'])]
BRANDS = ['الوطني', 'المراعي', 'أفق', 'الريف', 'الذهبي', 'النخبة', 'السعادة', 'الأصيل']
SIZES = [('500 جم', 'كيس'), ('1 كجم', 'كيس'), ('2 كجم', 'كيس'), ('5 كجم', 'كيس'), ('330 مل', 'علبة'), ('1 لتر', 'علبة'), ('1.5 لتر', 'قارورة'), ('200 جم', 'علبة')]

def products(n):
    out, names = [], set()
    i = 0
    while len(out) < n:
        i += 1
        ci = i % len(CATS)
        cat, color, items = CATS[ci]
        base = items[(i // len(CATS)) % len(items)]
        brand = BRANDS[(i // 3) % len(BRANDS)]
        size, unit = SIZES[(i * 7) % len(SIZES)]
        name = f'{base} {brand} {size}'
        if name in names:
            name = f'{name} - {i}'
        names.add(name)
        cost = round(random.uniform(1.5, 80), 2)
        sale = round(cost * random.uniform(1.15, 1.45), 2)
        out.append(dict(id=len(out) + 1, name=name, cat=ci + 1, color=color, unit=unit, cost=cost, sale=sale,
                        stock=random.randint(5, 400), barcode=f'628{len(out) + 1:010d}', sku=f'SKU-{len(out) + 1:05d}'))
    return out

FIRST = ['محمد', 'أحمد', 'علي', 'خالد', 'سالم', 'عبدالله', 'فهد', 'ناصر', 'سعيد', 'يوسف', 'عمر', 'حسن']
LAST = ['الحربي', 'العتيبي', 'القحطاني', 'الشهري', 'الزهراني', 'الغامدي', 'المطيري', 'الدوسري', 'اليمني', 'الحضرمي']
def people(n, prefix=''):
    out = set()
    while len(out) < n:
        out.add(f'{prefix}{random.choice(FIRST)} {random.choice(FIRST)} {random.choice(LAST)}')
    return sorted(out)

# ───────────── 1) ready for FYONA ─────────────
def ready(path, n=400):
    if os.path.exists(path): os.remove(path)
    c = sqlite3.connect(path)
    c.executescript('''
    CREATE TABLE categories (id INTEGER PRIMARY KEY, name TEXT);
    CREATE TABLE products (id INTEGER PRIMARY KEY, name TEXT, barcode TEXT, sku TEXT, unit TEXT, sale_price REAL, cost_price REAL,
                           stock REAL, category_id INTEGER, min_stock REAL, description TEXT, expiry TEXT, notes TEXT);
    CREATE TABLE product_units (id INTEGER PRIMARY KEY, product_id INTEGER, name TEXT, factor REAL, barcode TEXT, sale_price REAL, cost_price REAL);
    CREATE TABLE product_barcodes (id INTEGER PRIMARY KEY, product_id INTEGER, barcode TEXT);
    CREATE TABLE product_images (id INTEGER PRIMARY KEY, product_id INTEGER, image BLOB);
    CREATE TABLE product_prices (id INTEGER PRIMARY KEY, product_id INTEGER, currency TEXT, price REAL, cost REAL);
    CREATE TABLE customers (id INTEGER PRIMARY KEY, name TEXT, phone TEXT, balance REAL, currency TEXT);
    CREATE TABLE suppliers (id INTEGER PRIMARY KEY, name TEXT, phone TEXT, balance REAL, currency TEXT);
    CREATE TABLE bank_accounts (id INTEGER PRIMARY KEY, name TEXT, bank TEXT, number TEXT, iban TEXT, balance REAL, currency TEXT);
    ''')
    for i, (cat, _, _) in enumerate(CATS):
        c.execute('INSERT INTO categories VALUES (?,?)', (i + 1, cat))
    ps = products(n)
    exp = dict(products=n, units=0, barcodes=0, images=n, usd=0, stock=0, sale=0.0)
    for p in ps:
        c.execute('INSERT INTO products VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)',
                  (p['id'], p['name'], p['barcode'], p['sku'], p['unit'], p['sale'], p['cost'], p['stock'], p['cat'], 5,
                   f'{p["name"]} — منتج أصلي', f'2027-{(p["id"] % 12) + 1:02d}-15' if p['cat'] in (3, 4) else None, None))
        exp['stock'] += p['stock']; exp['sale'] += p['sale']
        if p['id'] % 2 == 1:  # a carton of 12 with its own barcode and prices
            c.execute('INSERT INTO product_units (product_id,name,factor,barcode,sale_price,cost_price) VALUES (?,?,?,?,?,?)',
                      (p['id'], 'كرتون', 12, f'629{p["id"]:010d}', round(p['sale'] * 11.5, 2), round(p['cost'] * 12, 2)))
            exp['units'] += 1
        if p['id'] % 3 == 0:
            c.execute('INSERT INTO product_barcodes (product_id,barcode) VALUES (?,?)', (p['id'], f'627{p["id"]:010d}'))
            exp['barcodes'] += 1
        c.execute('INSERT INTO product_images (product_id,image) VALUES (?,?)', (p['id'], png(p['id'], p['color'])))
        if p['id'] % 4 == 0:
            c.execute('INSERT INTO product_prices (product_id,currency,price,cost) VALUES (?,?,?,?)',
                      (p['id'], 'USD', round(p['sale'] / 3.75, 2), round(p['cost'] / 3.75, 2)))
            exp['usd'] += 1
    cust = people(60); sup = people(25, 'مؤسسة ')
    exp['customers'] = len(cust); exp['suppliers'] = len(sup); exp['cust_total'] = 0; exp['sup_total'] = 0
    for k, n2 in enumerate(cust):
        bal = round(random.uniform(0, 4000), 2) if k % 3 else 0
        exp['cust_total'] = round(exp['cust_total'] + bal, 2)
        c.execute('INSERT INTO customers (name,phone,balance,currency) VALUES (?,?,?,?)', (n2, f'05{k:08d}', bal, 'SAR'))
    for k, n2 in enumerate(sup):
        bal = round(random.uniform(500, 20000), 2)
        exp['sup_total'] = round(exp['sup_total'] + bal, 2)
        c.execute('INSERT INTO suppliers (name,phone,balance,currency) VALUES (?,?,?,?)', (n2, f'01{k:08d}', bal, 'SAR'))
    for row in [('الصندوق الرئيسي', 'نقدي', 'CASH-1', None, 15000, 'SAR'), ('حساب الراجحي', 'مصرف الراجحي', '1234567890', 'SA0380000000608010167519', 85000, 'SAR'),
                ('حساب الأهلي', 'البنك الأهلي', '9876543210', 'SA4410000001234567891234', 42000.5, 'SAR'), ('صندوق الدولار', 'نقدي', 'CASH-USD', None, 2500, 'USD')]:
        c.execute('INSERT INTO bank_accounts (name,bank,number,iban,balance,currency) VALUES (?,?,?,?,?,?)', row)
    exp['accounts'] = 4
    exp['sale'] = round(exp['sale'], 2)
    c.commit(); c.close()
    return exp

# ───────────── 2) another program ─────────────
def other(path, n=300):
    if os.path.exists(path): os.remove(path)
    c = sqlite3.connect(path)
    q = lambda s, a=(): c.execute(s, a)
    c.executescript('''
    CREATE TABLE "الفروع" ("رقم" INTEGER PRIMARY KEY, "اسم الفرع" TEXT, "رئيسي" INTEGER);
    CREATE TABLE "العملات" ("رقم" INTEGER PRIMARY KEY, "الرمز" TEXT, "الاسم" TEXT);
    CREATE TABLE "المجموعات" ("رقم المجموعة" INTEGER PRIMARY KEY, "اسم المجموعة" TEXT);
    CREATE TABLE "الأصناف" ("رقم الصنف" INTEGER PRIMARY KEY, "اسم الصنف" TEXT, "الباركود" TEXT, "رقم المجموعة" INTEGER, "الوحدة" TEXT, "حد الطلب" REAL, "ملاحظات" TEXT);
    CREATE TABLE "وحدات الأصناف" ("رقم الوحدة" INTEGER PRIMARY KEY, "رقم الصنف" INTEGER, "اسم الوحدة" TEXT, "المعامل" REAL, "أساسية" INTEGER);
    CREATE TABLE "أسعار الأصناف" ("م" INTEGER PRIMARY KEY, "رقم الصنف" INTEGER, "رقم الوحدة" INTEGER, "رقم العملة" INTEGER, "سعر الشراء" REAL, "سعر البيع" REAL);
    CREATE TABLE "باركودات الوحدات" ("م" INTEGER PRIMARY KEY, "رقم الصنف" INTEGER, "رقم الوحدة" INTEGER, "الباركود" TEXT);
    CREATE TABLE "صور الأصناف" ("م" INTEGER PRIMARY KEY, "رقم الصنف" INTEGER, "اسم الملف" TEXT, "الصورة" BLOB);
    CREATE TABLE "أرصدة المخازن" ("م" INTEGER PRIMARY KEY, "رقم الصنف" INTEGER, "رقم الفرع" INTEGER, "الكمية" REAL);
    CREATE TABLE "حركات المخزون" ("م" INTEGER PRIMARY KEY, "رقم الصنف" INTEGER, "رقم الفرع" INTEGER, "النوع" TEXT, "الكمية" REAL, "التاريخ" TEXT);
    CREATE TABLE "العملاء" ("رقم العميل" INTEGER PRIMARY KEY, "اسم العميل" TEXT, "الجوال" TEXT, "رقم الفرع" INTEGER);
    CREATE TABLE "ذمم العملاء" ("م" INTEGER PRIMARY KEY, "رقم العميل" INTEGER, "رقم الفرع" INTEGER, "المبلغ" REAL, "المتبقي" REAL, "رقم العملة" INTEGER);
    CREATE TABLE "الموردين" ("رقم المورد" INTEGER PRIMARY KEY, "اسم المورد" TEXT, "الهاتف" TEXT, "الرصيد" REAL);
    CREATE TABLE "الصناديق والبنوك" ("رقم" INTEGER PRIMARY KEY, "الاسم" TEXT, "البنك" TEXT, "رقم الحساب" TEXT, "الرصيد" REAL, "رقم العملة" INTEGER, "رقم الفرع" INTEGER);
    CREATE TABLE "فواتير المبيعات" ("رقم الفاتورة" INTEGER PRIMARY KEY, "التاريخ" TEXT, "رقم العميل" INTEGER, "الإجمالي" REAL, "المدفوع" REAL);
    CREATE TABLE "الموظفين" ("رقم الموظف" INTEGER PRIMARY KEY, "الاسم" TEXT, "الراتب" REAL, "تاريخ التعيين" TEXT);
    CREATE TABLE "عقود الصيانة" ("رقم العقد" INTEGER PRIMARY KEY, "الجهة" TEXT, "المبلغ الشهري" REAL, "تاريخ البداية" TEXT);
    ''')
    q('INSERT INTO "الفروع" VALUES (1,"الفرع الرئيسي",1)'); q('INSERT INTO "الفروع" VALUES (2,"فرع المعلا",0)')
    q('INSERT INTO "العملات" VALUES (1,"SAR","ريال سعودي")'); q('INSERT INTO "العملات" VALUES (2,"USD","دولار")')
    for i, (cat, _, _) in enumerate(CATS):
        q('INSERT INTO "المجموعات" VALUES (?,?)', (i + 1, cat))
    ps = products(n)
    unit_id = 0
    exp = dict(rows=n, ok=0, refused={}, warnings={})
    def bump(d, k): d[k] = d.get(k, 0) + 1
    for p in ps:
        name, barcode, stock = p['name'], p['barcode'], p['stock']
        if p['id'] in (17, 88, 160): name = None; bump(exp['refused'], 'missing_name')            # no name
        if p['id'] in (41, 205): barcode = ps[p['id'] - 2]['barcode']; bump(exp['refused'], 'duplicate_in_file')  # same barcode as the one before
        if p['id'] in (55, 120): stock = -6; bump(exp['warnings'], 'negative_stock')              # negative quantity
        q('INSERT INTO "الأصناف" VALUES (?,?,?,?,?,?,?)', (p['id'], name, barcode, p['cat'], p['unit'], 4, None))
        unit_id += 1; base = unit_id
        q('INSERT INTO "وحدات الأصناف" VALUES (?,?,?,?,1)', (base, p['id'], p['unit'], 1))
        q('INSERT INTO "باركودات الوحدات" ("رقم الصنف","رقم الوحدة","الباركود") VALUES (?,?,?)', (p['id'], base, barcode))
        q('INSERT INTO "أسعار الأصناف" ("رقم الصنف","رقم الوحدة","رقم العملة","سعر الشراء","سعر البيع") VALUES (?,?,1,?,?)', (p['id'], base, p['cost'], p['sale']))
        q('INSERT INTO "أسعار الأصناف" ("رقم الصنف","رقم الوحدة","رقم العملة","سعر الشراء","سعر البيع") VALUES (?,?,2,?,?)', (p['id'], base, round(p['cost'] / 3.75, 2), round(p['sale'] / 3.75, 2)))
        if p['id'] % 2 == 0:
            unit_id += 1
            q('INSERT INTO "وحدات الأصناف" VALUES (?,?,?,?,0)', (unit_id, p['id'], 'كرتون', 6))
            q('INSERT INTO "باركودات الوحدات" ("رقم الصنف","رقم الوحدة","الباركود") VALUES (?,?,?)', (p['id'], unit_id, f'629{p["id"]:010d}'))
            q('INSERT INTO "أسعار الأصناف" ("رقم الصنف","رقم الوحدة","رقم العملة","سعر الشراء","سعر البيع") VALUES (?,?,1,?,?)', (p['id'], unit_id, round(p['cost'] * 6, 2), round(p['sale'] * 5.8, 2)))
        q('INSERT INTO "صور الأصناف" ("رقم الصنف","اسم الملف","الصورة") VALUES (?,?,?)', (p['id'], f'{p["sku"]}.png', png(p['id'], p['color'])))
        q('INSERT INTO "أرصدة المخازن" ("رقم الصنف","رقم الفرع","الكمية") VALUES (?,1,?)', (p['id'], stock))
        q('INSERT INTO "أرصدة المخازن" ("رقم الصنف","رقم الفرع","الكمية") VALUES (?,2,?)', (p['id'], random.randint(0, 50)))
        q('INSERT INTO "حركات المخزون" ("رقم الصنف","رقم الفرع","النوع","الكمية","التاريخ") VALUES (?,1,"شراء",?,"2025-01-05")', (p['id'], 100))
    exp['ok'] = n - sum(exp['refused'].values())
    cust = people(80)
    exp['customers_main'] = 0; exp['cust_total'] = 0
    for k, n2 in enumerate(cust, 1):
        br = 1 if k <= 50 else 2
        q('INSERT INTO "العملاء" VALUES (?,?,?,?)', (k, n2, f'7{k:08d}', br))
        if br == 1: exp['customers_main'] += 1
        if k % 2 == 0:
            due = round(random.uniform(100, 3000), 2); rest = round(due * random.choice([1, .5, .25]), 2)
            q('INSERT INTO "ذمم العملاء" ("رقم العميل","رقم الفرع","المبلغ","المتبقي","رقم العملة") VALUES (?,?,?,?,1)', (k, br, due, rest))
            if br == 1: exp['cust_total'] = round(exp['cust_total'] + rest, 2)
    sup = people(20, 'شركة ')
    for k, n2 in enumerate(sup, 1):
        q('INSERT INTO "الموردين" VALUES (?,?,?,?)', (k, n2, f'1{k:07d}', round(random.uniform(1000, 30000), 2)))
    q('INSERT INTO "الصناديق والبنوك" VALUES (1,"الصندوق","نقدي","C-1",12500,1,1)')
    q('INSERT INTO "الصناديق والبنوك" VALUES (2,"حساب الكريمي","بنك الكريمي","22334455",60000,1,1)')
    q('INSERT INTO "الصناديق والبنوك" VALUES (3,"صندوق الدولار","نقدي","C-USD",1800,2,1)')
    q('INSERT INTO "الصناديق والبنوك" VALUES (4,"صندوق المعلا","نقدي","C-2",7000,1,2)')
    for v in range(1, 120):
        q('INSERT INTO "فواتير المبيعات" VALUES (?,?,?,?,?)', (v, '2025-02-01', v % 80 + 1, 150.0, 100.0))
    for k in range(1, 9):
        q('INSERT INTO "الموظفين" VALUES (?,?,?,?)', (k, f'موظف {k}', 3500, '2023-05-01'))
    for k in range(1, 4):
        q('INSERT INTO "عقود الصيانة" VALUES (?,?,?,?)', (k, 'شركة تبريد', 450, '2025-01-01'))
    c.commit(); c.close()
    return exp

e1 = ready(os.path.join(OUT, 'FYONA-Import-Ready.db'))
e2 = other(os.path.join(OUT, 'FYONA-Import-Other-App.db'))
json.dump({'ready': e1, 'other': e2}, open(os.path.join(OUT, 'expect.json'), 'w'), ensure_ascii=False, indent=1)
print(json.dumps({'ready': e1, 'other': e2}, ensure_ascii=False))
