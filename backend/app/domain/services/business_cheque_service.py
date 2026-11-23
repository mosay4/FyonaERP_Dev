"""Original Business cheque records; no bank, ledger or attachment posting exists.

The original status endpoint allowed terminal reversal and creation accepted any
status. Fail closed: new records are pending and only pending may transition to
one of the original terminal states. Legacy invalid states remain readable and
deletable, but cannot be silently repaired/posted. Transactions belong to callers.
NULL legacy branch ownership resolves only to the company's default branch.
"""
from datetime import datetime, timezone

from fastapi import HTTPException
from sqlalchemy import and_, exists, or_, select

from ..entities.finance_entities import Cheque
from ..entities.sale_entities import Branch


def branch_condition(company, branches):
    return or_(Cheque.branch_id.in_(branches), and_(Cheque.branch_id.is_(None), exists(
        select(Branch.id).where(Branch.organization_id == company, Branch.is_default,
                                Branch.id.in_(branches)))))


async def list_cheques(db, company, branches, *, page=1, per_page=50, status=None):
    query = select(Cheque).where(Cheque.organization_id == company, ~Cheque.is_deleted,
                                branch_condition(company, branches))
    if status:
        query = query.where(Cheque.status == status)
    return (await db.scalars(query.order_by(Cheque.created_at.desc())
                            .offset((page - 1) * per_page).limit(per_page))).all()


async def get_cheque(db, company, branches, identity, *, lock=False):
    query = select(Cheque).where(Cheque.id == identity, Cheque.organization_id == company,
                                ~Cheque.is_deleted, branch_condition(company, branches))
    if lock:
        query = query.with_for_update().execution_options(populate_existing=True)
    row = (await db.execute(query)).scalar_one_or_none()
    if row is None:
        raise HTTPException(404, detail="الشيك غير موجود")
    return row


async def create_cheque(db, company, branch, data, *, cheque_id=None):
    if data.status != 'pending':
        raise HTTPException(409, detail='New cheques must be pending')
    if not await db.scalar(select(Branch.id).where(Branch.id == branch,
            Branch.organization_id == company, Branch.is_active, ~Branch.is_archived)):
        raise HTTPException(403, detail='Invalid cheque branch')
    row = Cheque(**({'id': cheque_id} if cheque_id is not None else {}),
                 organization_id=company, branch_id=branch, **data.model_dump())
    db.add(row)
    await db.flush()
    return row


async def transition_cheque(db, company, branch, identity, data):
    row = await get_cheque(db, company, (branch,), identity, lock=True)
    if row.status != 'pending' or data.status not in {'cashed', 'bounced', 'cancelled'}:
        raise HTTPException(409, detail='Cheque status transition is not permitted')
    row.status = data.status
    await db.flush()
    return row


async def delete_cheque(db, company, branch, identity):
    row = await get_cheque(db, company, (branch,), identity, lock=True)
    row.is_deleted, row.deleted_at = True, datetime.now(timezone.utc)
    await db.flush()
    return row
