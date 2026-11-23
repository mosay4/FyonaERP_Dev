"""Legacy branch scenarios must never use the configured production database."""
import os
from pathlib import Path
import subprocess
import sys

import pytest

from tests.unit.test_notifications_visibility import pg_url  # noqa: F401


@pytest.mark.parametrize('script', [
    'test_branches_runtime.py', 'test_branch_isolation_runtime.py',
    'test_all_branches_lists_runtime.py', 'test_branch_bank_runtime.py',
    'test_branch_stock_runtime.py', 'test_branch_sale_stock_runtime.py',
    'test_branch_expense_runtime.py', 'test_branch_transfers_runtime.py',
    'test_branch_lifecycle_runtime.py', 'test_branch_concurrency_runtime.py',
])
def test_branch_runtime_in_disposable_database(pg_url, script):
    assert '/fyona_test_notifs' in pg_url, 'Refusing to run against a non-test database'
    root = Path(__file__).resolve().parents[1]
    env = dict(os.environ, DATABASE_URL=pg_url)
    result = subprocess.run([sys.executable, str(root / 'tests' / script)],
        cwd=root, env=env, capture_output=True, text=True, timeout=100)
    assert result.returncode == 0, f'{script}\n{result.stdout}\n{result.stderr}'
