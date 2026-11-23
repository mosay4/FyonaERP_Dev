"""Migration 101 accepts both legacy and missing branch timestamps."""
import importlib.util
from pathlib import Path
from unittest.mock import MagicMock

import pytest


@pytest.mark.parametrize('existing_timestamp', [False, True])
def test_lookup_migration_preserves_existing_branch_timestamp(monkeypatch, existing_timestamp):
    path = Path(__file__).parents[2] / 'migrations/versions/101_employee_lookup_and_branch_image_version.py'
    spec = importlib.util.spec_from_file_location('lookup_migration', path)
    migration = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(migration)
    operations = MagicMock()
    operations.get_bind.return_value.execute.return_value.mappings.return_value.all.return_value = []
    inspector = MagicMock()
    inspector.get_columns.return_value = [{'name': 'updated_at'}] if existing_timestamp else []
    monkeypatch.setattr(migration, 'op', operations)
    monkeypatch.setattr(migration.sa, 'inspect', lambda connection: inspector)
    migration.upgrade()
    branch_columns = [call.args[1].name for call in operations.add_column.call_args_list if call.args[0] == 'branches']
    assert branch_columns == ([] if existing_timestamp else ['updated_at'])
    assert operations.create_index.call_count == 2
    migration.downgrade()
    assert all(call.args[0] != 'branches' for call in operations.drop_column.call_args_list)
