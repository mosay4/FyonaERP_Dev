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
