"""«جميع الفروع» on the phone: Sara names branches and never executes."""
import ast
from pathlib import Path

SOURCE = Path(__file__).resolve().parents[2] / 'app' / 'api' / 'v1' / 'business_sara.py'


def _rule() -> str:
    # Read the constant without importing the router (no model registry side
    # effects for the other unit tests).
    tree = ast.parse(SOURCE.read_text(encoding='utf-8'))
    for node in tree.body:
        if isinstance(node, ast.Assign) and any(
                getattr(t, 'id', None) == 'ALL_BRANCHES_DEVICE_RULE' for t in node.targets):
            return ast.literal_eval(node.value)
    raise AssertionError('ALL_BRANCHES_DEVICE_RULE missing')


def test_all_branches_device_rule_names_branches_and_is_read_only():
    rule = _rule()
    assert 'branch_name' in rule and 'by_branch' in rule
    assert 'اسم الفرع' in rule
    assert 'قراءة واستشارة فقط' in rule and 'لا تجهزي ولا تنفذي' in rule


def test_all_branches_device_prompt_replaces_the_execute_on_device_line():
    text = SOURCE.read_text(encoding='utf-8')
    assert 'if device and scope.all_mode:\n        prompt += ALL_BRANCHES_DEVICE_RULE' in text


def test_all_branches_guard_lets_the_device_resume_through():
    # The phone answers Sara's reads and resumes via /continue; in «جميع
    # الفروع» the read-only middleware used to answer it 409.
    from app.core.all_branches_guard import all_branches_blocked
    for path in ('/api/v1/business-sara/query', '/api/v1/business-sara/continue'):
        assert not all_branches_blocked('POST', path, 'all')
    assert all_branches_blocked('POST', '/api/v1/business-sara/execute', 'all')
