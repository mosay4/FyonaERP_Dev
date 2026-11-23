import json
from uuid import UUID
from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, Field
from sqlalchemy.ext.asyncio import AsyncSession
from ...core.database import get_db
from ...core.qa_business_ledger import contains_registered_branch
from ..deps import get_current_org_id, get_current_user_uuid
from ..deps import get_branch_scope
from ..responses import ok
from ...domain.entities.business_settings_entities import BusinessProjectSettings
from ...domain.entities.business_settings_entities import BusinessProjectBackup
from ...domain.services.employee_access_policy import member_policy, full_access, allowed

router = APIRouter(prefix='/business/project-settings', tags=['Business settings'])


class SettingsPatch(BaseModel):
    enabled_currencies: list[str] | None = Field(default=None, min_length=1, max_length=100)
    allow_negative: bool | None = None
    invoice_design: dict | None = None


@router.get('')
async def get_settings(org_id: str = Depends(get_current_org_id), db: AsyncSession = Depends(get_db)):
    row = await db.get(BusinessProjectSettings, UUID(org_id))
    return ok({'settings': json.loads(row.settings) if row else {}})


@router.put('')
async def save_settings(data: SettingsPatch, request: Request,
                        org_id: str = Depends(get_current_org_id),
                        user_id: UUID = Depends(get_current_user_uuid), db: AsyncSession = Depends(get_db)):
    policy = await member_policy(db, request, user_id)
    patch = data.model_dump(exclude_none=True)
    if policy is not None:
        if any(k != 'invoice_design' for k in patch) and not full_access(policy):
            raise HTTPException(403, detail='تخصيص إعدادات المشروع يحتاج صلاحيات كاملة')
        if 'invoice_design' in patch and not allowed(policy, 'invoices'):
            raise HTTPException(403, detail='لا تملك صلاحية تخصيص الفواتير')
    if data.enabled_currencies is not None:
        import re
        codes = list(dict.fromkeys(c.strip().upper() for c in data.enabled_currencies))
        if any(not re.fullmatch(r'[A-Z0-9_-]{2,16}', c) for c in codes):
            raise HTTPException(400, detail='رمز العملة غير صالح')
        patch['enabled_currencies'] = codes
    if len(json.dumps(patch)) > 2_000_000:
        raise HTTPException(400, detail='حجم الإعدادات كبير جداً')
    row = await db.get(BusinessProjectSettings, UUID(org_id))
    if row is None:
        row = BusinessProjectSettings(organization_id=UUID(org_id), settings='{}')
        db.add(row)
    current = json.loads(row.settings or '{}')
    if 'invoice_design' in patch:
        patch['invoice_design'] = {**current.get('invoice_design', {}), **patch['invoice_design']}
    current.update(patch)
    row.settings = json.dumps(current, ensure_ascii=False)
    await db.commit()
    return ok({'settings': current})


async def _backup_access(db, request, user_id):
    policy = await member_policy(db, request, user_id)
    if policy is not None and not full_access(policy):
        raise HTTPException(403, detail='النسخ الاحتياطي يحتاج صلاحيات كاملة')


async def _connected_backup_branches(db, scope):
    ids = scope.branch_ids if scope.all_mode else [scope.branch_id]
    if await contains_registered_branch(db, ids):
        raise HTTPException(409, detail='نسخ دفتر هذا الفرع واستعادته تتم من الجهاز.')
    return ids


@router.get('/backups')
async def list_backups(request: Request, org_id: str = Depends(get_current_org_id),
                      user_id: UUID = Depends(get_current_user_uuid), scope=Depends(get_branch_scope),
                      db: AsyncSession = Depends(get_db)):
    from sqlalchemy import select
    await _backup_access(db, request, user_id)
    rows = (await db.execute(select(BusinessProjectBackup).where(
        BusinessProjectBackup.organization_id == UUID(org_id)).order_by(BusinessProjectBackup.created_at.desc()))).scalars().all()
    allowed_ids = {str(b) for b in (scope.branch_ids if scope.all_mode else [scope.branch_id])}
    return ok({'backups': [{'id': str(b.id), 'created_at': b.created_at.isoformat(),
        'checksum': b.checksum, 'bytes': len(b.payload.encode()),
        'record_count': json.loads(b.payload)['record_count']}
        for b in rows if set(json.loads(b.payload)['branch_ids']).issubset(allowed_ids)]})


@router.post('/backups')
async def create_backup(request: Request, org_id: str = Depends(get_current_org_id),
                        user_id: UUID = Depends(get_current_user_uuid), scope=Depends(get_branch_scope),
                        db: AsyncSession = Depends(get_db)):
    from ...domain.services.business_backup_service import capture, checksum
    await _backup_access(db, request, user_id)
    payload = await capture(db, UUID(org_id), await _connected_backup_branches(db, scope))
    row = BusinessProjectBackup(organization_id=UUID(org_id), payload=payload, checksum=checksum(payload))
    db.add(row); await db.commit()
    return ok({'id': str(row.id), 'checksum': row.checksum})


async def _backup(db, backup_id, org_id, scope):
    row = await db.get(BusinessProjectBackup, backup_id)
    allowed_ids = {str(b) for b in (scope.branch_ids if scope.all_mode else [scope.branch_id])}
    if row is None or str(row.organization_id) != org_id or not set(json.loads(row.payload)['branch_ids']).issubset(allowed_ids):
        raise HTTPException(404, detail='النسخة غير موجودة')
    return row


@router.get('/backups/{backup_id}')
async def download_backup(backup_id: UUID, request: Request, org_id: str = Depends(get_current_org_id),
                          user_id: UUID = Depends(get_current_user_uuid), scope=Depends(get_branch_scope),
                          db: AsyncSession = Depends(get_db)):
    await _backup_access(db, request, user_id)
    row = await _backup(db, backup_id, org_id, scope)
    return ok({'snapshot': json.loads(row.payload), 'checksum': row.checksum})


@router.delete('/backups/{backup_id}')
async def delete_backup(backup_id: UUID, request: Request, org_id: str = Depends(get_current_org_id),
                        user_id: UUID = Depends(get_current_user_uuid), scope=Depends(get_branch_scope),
                        db: AsyncSession = Depends(get_db)):
    await _backup_access(db, request, user_id)
    row = await _backup(db, backup_id, org_id, scope)
    await db.delete(row); await db.commit()
    return ok({'deleted': True})


@router.post('/backups/{backup_id}/restore')
async def restore_backup(backup_id: UUID, request: Request, org_id: str = Depends(get_current_org_id),
                         user_id: UUID = Depends(get_current_user_uuid), scope=Depends(get_branch_scope),
                         db: AsyncSession = Depends(get_db)):
    from ...domain.services.business_backup_service import restore
    await _backup_access(db, request, user_id)
    ids = await _connected_backup_branches(db, scope)
    row = await _backup(db, backup_id, org_id, scope)
    count = await restore(db, row, UUID(org_id), ids)
    await db.commit()
    return ok({'restored': count})
