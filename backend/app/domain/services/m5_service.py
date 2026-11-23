import json
from datetime import date, datetime, timezone
from decimal import Decimal
from openai import AsyncOpenAI
from sqlalchemy import select, func
from sqlalchemy.orm import selectinload
from app.core.config import settings
from app.domain.models.m5_models import (
    DepartmentResponse,
    PositionResponse,
    EmployeeResponse,
    AttendanceResponse,
    LeaveResponse,
    PayrollResponse,
    PayrollItemResponse,
    KPIResponse,
    SalesReportResponse,
    SalesReportItem,
    InventoryReportResponse,
    InventoryReportItem,
    AIInsightsResponse,
    AIInsight,
    AIQueryResponse,
    ForecastResponse,
    ForecastItem,
)
from app.domain.entities.hr_entities import (
    Department,
    Position,
    Employee,
    Attendance,
    Leave,
    Payroll,
    PayrollItem,
)
from app.domain.repositories.m5_repository import (
    DepartmentRepository,
    PositionRepository,
    EmployeeRepository,
    AttendanceRepository,
    LeaveRepository,
    PayrollRepository,
)


class HRService:
    def __init__(
        self,
        dept: DepartmentRepository,
        pos: PositionRepository,
        emp: EmployeeRepository,
        att: AttendanceRepository,
        lev: LeaveRepository,
        pr: PayrollRepository,
    ):
        self._d = dept
        self._p = pos
        self._e = emp
        self._a = att
        self._l = lev
        self._pr = pr

    async def create_dept(self, org_id, data):
        r = await self._d.create(
            Department(organization_id=org_id, **data.model_dump())
        )
        return DepartmentResponse.model_validate(r)

    async def list_depts(self, org_id):
        return [
            DepartmentResponse.model_validate(i) for i in await self._d.list(org_id)
        ]

    async def create_pos(self, org_id, data):
        r = await self._p.create(Position(organization_id=org_id, **data.model_dump()))
        return PositionResponse.model_validate(r)

    async def list_positions(self, org_id, dept_id=None):
        items = await self._p.list(org_id, dept_id)
        return [
            PositionResponse(
                id=i.id,
                organization_id=i.organization_id,
                department_id=i.department_id,
                department_name=i.department.name if i.department else None,
                title=i.title,
                title_ar=i.title_ar,
                description=i.description,
                is_active=i.is_active,
                created_at=i.created_at,
            )
            for i in items
        ]

    async def create_emp(self, org_id, uid, data):
        r = await self._e.create(
            Employee(organization_id=org_id, created_by=uid, **data.model_dump())
        )
        return await self._emp_resp(r.id, org_id)

    async def get_emp(self, id, org_id):
        e = await self._e.get_by_id(id, org_id)
        if not e:
            raise ValueError("الموظف غير موجود")
        return self._emp_resp_obj(e)

    async def update_emp(self, id, org_id, data):
        e = await self._e.get_by_id(id, org_id)
        if not e:
            raise ValueError("الموظف غير موجود")
        upd = data.model_dump(exclude_unset=True)
        for k, v in upd.items():
            setattr(e, k, v)
        r = await self._e.update(e)
        return self._emp_resp_obj(r)

    async def delete_emp(self, id, org_id):
        e = await self._e.get_by_id(id, org_id)
        if not e:
            raise ValueError("الموظف غير موجود")
        await self._e.soft_delete(id, org_id)

    async def list_emps(
        self, org_id, search=None, dept_id=None, status=None, page=1, per_page=20
    ):
        items, total = await self._e.list(
            org_id, search, dept_id, status, page, per_page
        )
        return [self._emp_resp_obj(i) for i in items], total

    def _emp_resp_obj(self, e):
        return EmployeeResponse(
            id=e.id,
            organization_id=e.organization_id,
            employee_code=e.employee_code,
            full_name=e.full_name,
            email=e.email,
            phone=e.phone,
            department_id=e.department_id,
            department_name=e.department.name if e.department else None,
            position_id=e.position_id,
            position_name=e.position.title if e.position else None,
            hire_date=e.hire_date,
            salary=e.salary,
            status=e.status,
            id_number=e.id_number,
            gender=e.gender,
            date_of_birth=e.date_of_birth,
            address=e.address,
            emergency_contact=e.emergency_contact,
            emergency_phone=e.emergency_phone,
            bank_name=e.bank_name,
            bank_account=e.bank_account,
            iban=e.iban,
            notes=e.notes,
            created_at=e.created_at,
            updated_at=e.updated_at,
        )

    async def _emp_resp(self, id, org_id):
        return self._emp_resp_obj(await self._e.get_by_id(id, org_id))

    async def create_attendance(self, org_id, uid, data):
        a = Attendance(created_by=uid, **data.model_dump())
        r = await self._a.create(a)
        e = await self._e.get_by_id(r.employee_id, org_id)
        return AttendanceResponse(
            id=r.id,
            employee_id=r.employee_id,
            employee_name=e.full_name if e else None,
            date=r.date,
            check_in=r.check_in,
            check_out=r.check_out,
            status=r.status,
            notes=r.notes,
            created_at=r.created_at,
        )

    async def list_attendance(
        self, org_id, emp_id=None, from_date=None, to_date=None, page=1, per_page=20
    ):
        items, total = await self._a.list(
            org_id, emp_id, from_date, to_date, page, per_page
        )
        emp_ids = list({i.employee_id for i in items if i.employee_id})
        emp_map = {}
        if emp_ids:
            s = self._pr._s
            r = await s.execute(select(Employee).where(Employee.id.in_(emp_ids)))
            emp_map = {e.id: e for e in r.unique().scalars().all()}
        result = []
        for i in items:
            e = emp_map.get(i.employee_id)
            result.append(
                AttendanceResponse(
                    id=i.id,
                    employee_id=i.employee_id,
                    employee_name=e.full_name if e else None,
                    date=i.date,
                    check_in=i.check_in,
                    check_out=i.check_out,
                    status=i.status,
                    notes=i.notes,
                    created_at=i.created_at,
                )
            )
        return result, total

    async def create_leave(self, org_id, data):
        days = (data.end_date - data.start_date).days + 1
        r = await self._l.create(Leave(days=float(days), **data.model_dump()))
        e = await self._e.get_by_id(r.employee_id, org_id)
        return LeaveResponse(
            id=r.id,
            employee_id=r.employee_id,
            employee_name=e.full_name if e else None,
            leave_type=r.leave_type,
            start_date=r.start_date,
            end_date=r.end_date,
            days=r.days,
            reason=r.reason,
            status=r.status,
            created_at=r.created_at,
        )

    async def approve_leave(self, id, org_id, uid):
        l = await self._l.get_by_id(id, org_id)
        if not l:
            raise ValueError("الإجازة غير موجودة")
        l.status = "approved"
        l.approved_by = uid
        r = await self._l.update(l)
        e = await self._e.get_by_id(r.employee_id, org_id)
        return LeaveResponse(
            id=r.id,
            employee_id=r.employee_id,
            employee_name=e.full_name if e else None,
            leave_type=r.leave_type,
            start_date=r.start_date,
            end_date=r.end_date,
            days=r.days,
            reason=r.reason,
            status=r.status,
            created_at=r.created_at,
        )

    async def reject_leave(self, id, org_id, uid):
        l = await self._l.get_by_id(id, org_id)
        if not l:
            raise ValueError("الإجازة غير موجودة")
        l.status = "rejected"
        l.approved_by = uid
        return await self._l.update(l)

    async def list_leaves(self, org_id, emp_id=None, status=None, page=1, per_page=20):
        items, total = await self._l.list(org_id, emp_id, status, page, per_page)
        emp_ids = list({i.employee_id for i in items if i.employee_id})
        emp_map = {}
        if emp_ids:
            s = self._pr._s
            r = await s.execute(select(Employee).where(Employee.id.in_(emp_ids)))
            emp_map = {e.id: e for e in r.unique().scalars().all()}
        result = []
        for i in items:
            e = emp_map.get(i.employee_id)
            result.append(
                LeaveResponse(
                    id=i.id,
                    employee_id=i.employee_id,
                    employee_name=e.full_name if e else None,
                    leave_type=i.leave_type,
                    start_date=i.start_date,
                    end_date=i.end_date,
                    days=i.days,
                    reason=i.reason,
                    status=i.status,
                    created_at=i.created_at,
                )
            )
        return result, total

    async def create_payroll(self, org_id, uid, data):
        p = Payroll(organization_id=org_id, processed_by=uid, **data.model_dump())
        r = await self._pr.create(p)
        emps = await self._e.list(org_id, status="active")
        total_sal = Decimal("0")
        for emp, _ in emps:
            net = emp.salary or Decimal("0")
            item = PayrollItem(
                payroll_id=r.id,
                employee_id=emp.id,
                basic_salary=emp.salary,
                net_salary=net,
            )
            self._pr._s.add(item)
            total_sal += emp.salary or Decimal("0")
        r.total_salary = total_sal
        r.net_total = total_sal
        await self._pr._s.flush()
        r = await self._pr.get_by_id(r.id, org_id)
        return await self._payroll_resp(r, org_id)

    async def process_payroll(self, id, org_id, uid):
        p = await self._pr.get_by_id(id, org_id)
        if not p:
            raise ValueError("كشف الرواتب غير موجود")
        if p.status != "draft":
            raise ValueError("يمكن معالجة المسودة فقط")
        p.status = "processed"
        p.processed_at = datetime.now(timezone.utc)
        await self._pr.update(p)
        return await self._payroll_resp(p, org_id)

    async def list_payrolls(self, org_id, page=1, per_page=20):
        items, total = await self._pr.list(org_id, page, per_page)
        return [await self._payroll_resp(i, org_id) for i in items], total

    async def _payroll_resp(self, p, org_id):
        from app.domain.entities.hr_entities import PayrollItem as PI

        r = await self._pr._s.execute(select(PI).where(PI.payroll_id == p.id))
        items = []
        raw_items = r.unique().scalars().all()
        emp_ids = list({i.employee_id for i in raw_items if i.employee_id})
        emp_map = {}
        if emp_ids:
            s = self._pr._s
            er = await s.execute(select(Employee).where(Employee.id.in_(emp_ids)))
            emp_map = {e.id: e for e in er.unique().scalars().all()}
        for i in raw_items:
            e = emp_map.get(i.employee_id) if i.employee_id else None
            items.append(
                PayrollItemResponse(
                    id=i.id,
                    payroll_id=i.payroll_id,
                    employee_id=i.employee_id,
                    employee_name=e.full_name if e else None,
                    basic_salary=i.basic_salary,
                    allowances=i.allowances,
                    deductions=i.deductions,
                    bonus=i.bonus,
                    overtime=i.overtime,
                    net_salary=i.net_salary,
                    total_days=i.total_days,
                    working_days=i.working_days,
                    absence_days=i.absence_days,
                )
            )
        return PayrollResponse(
            id=p.id,
            organization_id=p.organization_id,
            month=p.month,
            year=p.year,
            status=p.status,
            total_salary=p.total_salary,
            total_deductions=p.total_deductions,
            total_bonuses=p.total_bonuses,
            net_total=p.net_total,
            notes=p.notes,
            created_at=p.created_at,
            processed_at=p.processed_at,
            items=items,
        )

    # ═══ Reports ═══
    async def kpi(self, org_id):
        from app.core.cache import tenant_cache_get, tenant_cache_set

        cached = await tenant_cache_get(org_id, "kpi")
        if cached:
            return KPIResponse.model_validate(cached)

        from app.domain.entities.business_entities import Customer, Product
        from app.domain.entities.sales_entities import SalesOrder
        from app.domain.entities.purchase_entities import PurchaseOrder

        s = self._pr._s
        c = (
            await s.execute(
                select(func.count(Customer.id)).where(
                    Customer.organization_id == org_id, ~Customer.is_deleted
                )
            )
        ).scalar() or 0
        p = (
            await s.execute(
                select(func.count(Product.id)).where(
                    Product.organization_id == org_id, ~Product.is_deleted
                )
            )
        ).scalar() or 0
        so = (
            await s.execute(
                select(func.count(SalesOrder.id)).where(
                    SalesOrder.organization_id == org_id, ~SalesOrder.is_deleted
                )
            )
        ).scalar() or 0
        po = (
            await s.execute(
                select(func.count(PurchaseOrder.id)).where(
                    PurchaseOrder.organization_id == org_id,
                    ~PurchaseOrder.is_deleted,
                )
            )
        ).scalar() or 0
        emp_active = await self._e.count(org_id, "active")
        pending_leaves = await self._l.count_pending(org_id)
        ls = (
            await s.execute(
                select(func.count(Product.id)).where(
                    Product.organization_id == org_id,
                    ~Product.is_deleted,
                    Product.stock < Product.min_stock,
                )
            )
        ).scalar() or 0

        # ── Real financial aggregates (delivered sales / received purchases) ──
        sales_amount = Decimal("0")
        purchase_amount = Decimal("0")
        delivered_orders = 0

        month_keys = self._last_months(6)
        monthly_revenue = [Decimal("0")] * 6
        monthly_expenses = [Decimal("0")] * 6

        so_rows = await s.execute(
            select(SalesOrder.total, SalesOrder.order_date).where(
                SalesOrder.organization_id == org_id,
                ~SalesOrder.is_deleted,
                SalesOrder.status == "delivered",
            )
        )
        for total, odate in so_rows.all():
            total = total or Decimal("0")
            sales_amount += total
            delivered_orders += 1
            idx = self._month_index(month_keys, odate)
            if idx is not None:
                monthly_revenue[idx] += total

        po_rows = await s.execute(
            select(PurchaseOrder.total, PurchaseOrder.order_date).where(
                PurchaseOrder.organization_id == org_id,
                ~PurchaseOrder.is_deleted,
                PurchaseOrder.status == "received",
            )
        )
        for total, odate in po_rows.all():
            total = total or Decimal("0")
            purchase_amount += total
            idx = self._month_index(month_keys, odate)
            if idx is not None:
                monthly_expenses[idx] += total

        net_profit = sales_amount - purchase_amount
        result = KPIResponse(
            total_customers=c,
            total_products=p,
            total_sales_orders=so,
            total_purchase_orders=po,
            total_sales_amount=sales_amount,
            total_purchases_amount=purchase_amount,
            total_invoices=delivered_orders,
            total_revenue=sales_amount,
            total_expenses=Decimal("0"),
            net_profit=net_profit,
            active_employees=emp_active,
            pending_leaves=pending_leaves,
            low_stock_products=ls,
            monthly_revenue=monthly_revenue,
            monthly_expenses=monthly_expenses,
        )
        await tenant_cache_set(org_id, "kpi", result.model_dump(), ttl=60)
        return result

    @staticmethod
    def _last_months(n: int) -> list:
        """Return the first day of the last `n` months, oldest first."""
        from datetime import timedelta

        keys = []
        d = date.today().replace(day=1)
        for _ in range(n):
            keys.append(d)
            d = (d.replace(day=1) - timedelta(days=1)).replace(day=1)
        keys.reverse()
        return keys

    @staticmethod
    def _month_index(month_keys: list, d) -> int | None:
        if d is None:
            return None
        for i, start in enumerate(month_keys):
            if start.year == d.year and start.month == d.month:
                return i
        return None

    async def sales_report(self, org_id, from_date, to_date):
        from app.domain.entities.sales_entities import SalesOrder

        s = self._pr._s
        r = await s.execute(
            select(SalesOrder).where(
                SalesOrder.organization_id == org_id,
                SalesOrder.status == "delivered",
                SalesOrder.order_date >= from_date,
                SalesOrder.order_date <= to_date,
            )
        )
        items = r.unique().scalars().all()
        total = sum((i.total or Decimal("0")) for i in items)
        return SalesReportResponse(
            items=[
                SalesReportItem(
                    period=f"{from_date} - {to_date}",
                    order_count=len(items),
                    total_amount=total,
                    total_tax=Decimal("0"),
                )
            ],
            grand_total=total,
            from_date=from_date,
            to_date=to_date,
        )

    async def inventory_report(self, org_id):
        from app.domain.entities.business_entities import Product

        s = self._pr._s
        r = await s.execute(
            select(Product).where(
                Product.organization_id == org_id, ~Product.is_deleted
            )
        )
        items = r.unique().scalars().all()
        result = []
        total_val = Decimal("0")
        for i in items:
            v = (i.price or Decimal("0")) * Decimal(str(i.stock or 0))
            total_val += v
            result.append(
                InventoryReportItem(
                    product_id=i.id,
                    product_name=i.name,
                    sku=i.sku,
                    stock=i.stock,
                    min_stock=i.min_stock,
                    unit_price=i.price,
                    stock_value=v,
                )
            )
        return InventoryReportResponse(
            items=result,
            total_value=total_val,
            total_products=len(result),
            low_stock_count=sum(1 for i in items if i.stock < i.min_stock),
        )

    # ═══ AI ═══
    async def insights(self, org_id):
        from app.domain.entities.business_entities import Product

        s = self._pr._s
        low_stock = (
            await s.execute(
                select(func.count(Product.id)).where(
                    Product.organization_id == org_id,
                    ~Product.is_deleted,
                    Product.stock < Product.min_stock,
                )
            )
        ).scalar() or 0
        pending_l = await self._l.count_pending(org_id)
        insights = []
        if low_stock > 0:
            insights.append(
                AIInsight(
                    type="inventory",
                    title="منتجات منخفضة المخزون",
                    description=f"يوجد {low_stock} منتجات تحت الحد الأدنى",
                    severity="warning",
                    value=str(low_stock),
                )
            )
        if pending_l > 0:
            insights.append(
                AIInsight(
                    type="hr",
                    title="إجازات معلقة",
                    description=f"يوجد {pending_l} طلبات إجازة بانتظار الموافقة",
                    severity="info",
                    value=str(pending_l),
                )
            )
        if not insights:
            insights.append(
                AIInsight(
                    type="general",
                    title="لا توجد تنبيهات",
                    description="كل شيء يعمل بشكل طبيعي",
                    severity="success",
                )
            )
        return AIInsightsResponse(
            insights=insights, generated_at=datetime.now(timezone.utc)
        )

    async def forecast(self, org_id, metric, periods=3):
        from app.domain.entities.sales_entities import SalesOrder

        s = self._pr._s
        import random

        items = []
        for i in range(periods):
            import calendar

            m = (date.today().month + i) % 12 or 12
            y = date.today().year + (date.today().month + i - 1) // 12
            _, last_day = calendar.monthrange(y, m)
            r = await s.execute(
                select(func.count(SalesOrder.id)).where(
                    SalesOrder.organization_id == org_id,
                    SalesOrder.status == "delivered",
                    func.extract("month", SalesOrder.order_date) == m,
                    func.extract("year", SalesOrder.order_date) == y,
                )
            )
            base = r.scalar() or 5
            items.append(
                ForecastItem(
                    period=f"{y}-{m:02d}",
                    predicted_value=base * 1.1 + random.uniform(-2, 2),
                    lower_bound=base * 0.9,
                    upper_bound=base * 1.3,
                )
            )
        return ForecastResponse(items=items, metric=metric, periods=periods)

    async def query_ai(self, org_id, query_text):
        try:
            ctx = await self._build_context(org_id)
            system_prompt = (
                "أنت مساعد أعمال ذكي لنظام FYONA ERP. "
                "لديك معرفة كاملة ببيانات المنشأة التجارية الموضحة في السياق أدناه. "
                "أجب باللغة العربية الفصحى بوضوح واحترافية. "
                "استخدم الأرقام والإحصائيات من السياق لدعم إجابتك. "
                "إذا سُئلت عن شيء خارج نطاق بيانات المنشأة، أخبر المستخدم أنك متخصص في تحليل أعمال المنشأة فقط.\n\n"
                f"سياق بيانات المنشأة (JSON):\n{json.dumps(ctx, ensure_ascii=False, indent=2, default=str)}"
            )
            from app.domain.services.ai_router import build_client, route

            r = route(query_text, tools=False, base_tokens=1024)
            if not r.api_key:
                return AIQueryResponse(
                    answer="لم يتم تعيين مفتاح الذكاء الاصطناعي. يرجى إضافة DEEPSEEK_API_KEY (أو OPENAI_API_KEY) إلى ملف .env.",
                    confidence=0.0,
                    data=None,
                )
            client = build_client(r)
            resp = await client.chat.completions.create(
                model=r.model,
                messages=[
                    {"role": "system", "content": system_prompt},
                    {"role": "user", "content": query_text},
                ],
                temperature=0.3,
                max_tokens=r.max_tokens,
                extra_body={"effort": r.effort},
            )
            answer = resp.choices[0].message.content or ""
            return AIQueryResponse(answer=answer, confidence=0.9, data=None)
        except Exception as e:
            return AIQueryResponse(
                answer=f"عذراً، حدث خطأ أثناء معالجة سؤالك: {str(e)}",
                confidence=0.0,
                data=None,
            )

    async def _build_context(self, org_id):
        from app.domain.entities.business_entities import Customer, Product
        from app.domain.entities.sales_entities import SalesOrder
        from app.domain.entities.purchase_entities import PurchaseOrder
        from app.domain.entities.finance_entities import BankAccount, BankTransaction

        s = self._pr._s
        ctx = {}

        # KPI-style counts
        cust = (await s.execute(select(func.count(Customer.id)).where(Customer.organization_id == org_id, ~Customer.is_deleted))).scalar() or 0
        prods = (await s.execute(select(func.count(Product.id)).where(Product.organization_id == org_id, ~Product.is_deleted))).scalar() or 0
        low_stock = (await s.execute(select(func.count(Product.id)).where(Product.organization_id == org_id, ~Product.is_deleted, Product.stock < Product.min_stock))).scalar() or 0
        sales_orders = (await s.execute(select(func.count(SalesOrder.id)).where(SalesOrder.organization_id == org_id, ~SalesOrder.is_deleted))).scalar() or 0
        purchase_orders = (await s.execute(select(func.count(PurchaseOrder.id)).where(PurchaseOrder.organization_id == org_id, ~PurchaseOrder.is_deleted))).scalar() or 0
        try:
            active_emps = await self._e.count(org_id, "active")
        except Exception:
            active_emps = 0

        ctx["الإحصائيات_العامة"] = {
            "العملاء": cust,
            "المنتجات": prods,
            "منتجات_منخفضة_المخزون": low_stock,
            "طلبات_البيع": sales_orders,
            "أوامر_الشراء": purchase_orders,
            "الموظفون_النشطون": active_emps,
        }

        # Recent sales
        thirty_days_ago = datetime.now(timezone.utc).date()
        try:
            from dateutil.relativedelta import relativedelta
            thirty_days_ago = thirty_days_ago - relativedelta(days=30)
        except Exception:
            pass
        r = await s.execute(
            select(SalesOrder).where(
                SalesOrder.organization_id == org_id,
                SalesOrder.status == "delivered",
                SalesOrder.order_date >= thirty_days_ago,
            )
        )
        recent = r.unique().scalars().all()
        ctx["آخر_30_يوماً"] = {
            "عدد_طلبات_البيع": len(recent),
            "إجمالي_المبيعات": str(sum((i.total or Decimal("0")) for i in recent)),
        }

        # Bank accounts & balances
        bank_q = await s.execute(
            select(BankAccount).where(BankAccount.organization_id == org_id, ~BankAccount.is_deleted)
        )
        banks = bank_q.scalars().all()
        ctx["الحسابات_الببنكية"] = [
            {"اسم": b.account_name, "البنك": b.bank_name, "العملة": b.currency, "الرصيد": str(b.balance)}
            for b in banks
        ]

        # Pending leaves
        try:
            pending_l = await self._l.count_pending(org_id)
            ctx["الإجازات_المعلقة"] = pending_l
        except Exception:
            pass

        return ctx
