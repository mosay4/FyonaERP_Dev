from sqlalchemy import select
from ..entities.auth_entities import Organization
from ..entities.sale_entities import Branch


async def business_identity(db, organization_id):
    organization = await db.get(Organization, organization_id)
    main = (await db.execute(select(Branch).where(Branch.organization_id == organization_id,
        Branch.is_default.is_(True), Branch.is_active.is_(True),
        Branch.is_archived.is_(False)))).scalars().first()
    settings = (main.settings or {}) if main else {}
    return {'name': main.name if main else organization.name,
            'photo_url': (main.image if main else None) or organization.avatar,
            'phone': settings.get('phone') or settings.get('business_phone'),
            'branch_id': str(main.id) if main else None}
