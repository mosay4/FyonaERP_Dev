from uuid import uuid4
import pytest
from fastapi import HTTPException
from app.api.deps import get_branch_context
from app.domain.services.branch_service import issue_scope_token
from app.domain.services.employee_access_policy import allowed


@pytest.mark.asyncio
async def test_signed_all_scope_rejects_explicit_write_target():
    user, org, branch = uuid4(), uuid4(), uuid4()
    token = issue_scope_token(user, org, None, True, [branch])
    with pytest.raises(HTTPException) as error:
        await get_branch_context(org_id=str(org), user_id=user,
            x_branch_token=token, x_branch_id=str(branch), branch_id=str(branch),
            db=None, request=None)
    assert error.value.status_code == 403
    assert error.value.detail['code'] == 'branch_read_only'


def test_employee_cannot_get_sara_even_with_legacy_grant():
    assert not allowed({'ai': True}, 'ai')
