"""Final boundary for bank balances, including nested/aggregate API payloads."""
import json
from ..domain.services.employee_access_policy import allowed, report_allowed


def redact_balances(value):
    if isinstance(value, list): return [redact_balances(v) for v in value]
    if not isinstance(value, dict): return value
    result = {}
    for key, item in value.items():
        if 'balance' in key.lower() or key in {
                'totals', 'summary', 'total_income', 'total_expense', 'net_change'}:
            continue
        result[key] = ({code: None for code in item} if key == 'currencies' and isinstance(item, dict)
                       else redact_balances(item))
    result['balance_visible'] = False
    return result


class EmployeeBankResponseGuard:
    def __init__(self, app): self.app = app
    async def __call__(self, scope, receive, send):
        path = scope.get('path', '')
        reporting = path.startswith(('/api/v1/reports', '/api/v1/business-reports'))
        banking = path.startswith(('/api/v1/banking', '/api/v1/finance', '/api/v1/accounting',
            '/api/v1/branches/transfers', '/api/v1/business/transactions', '/api/v1/business/payment-options'))
        if scope['type'] != 'http' or not (banking or reporting):
            return await self.app(scope, receive, send)
        start = None
        body = bytearray()
        async def filtered(message):
            nonlocal start
            if message['type'] == 'http.response.start':
                start = message
                return
            if message['type'] != 'http.response.body': return await send(message)
            if start is None: return await send(message)
            policy = scope.get('state', {}).get('employee_policy')
            denied_report = policy is not None and reporting and not report_allowed(policy, path)
            denied_export = policy is not None and banking and any(
                word in path for word in ('export', 'statement')) and not all(
                    allowed(policy, key) for key in ('reports.view', 'reports.export', 'banks.balances', 'banks.details'))
            if denied_report or denied_export:
                if message.get('more_body'): return
                result = b'{"success":false,"message":"Report access denied"}'
                start['status'] = 403
                start['headers'] = [(b'content-type', b'application/json'),
                                    (b'content-length', str(len(result)).encode())]
                await send(start)
                return await send({'type': 'http.response.body', 'body': result})
            if policy is None or not banking or allowed(policy, 'banks.balances') or not 200 <= start['status'] < 300:
                if start is not None:
                    await send(start); start = None
                return await send(message)
            body.extend(message.get('body', b''))
            if message.get('more_body'): return
            try:
                result = json.dumps(redact_balances(json.loads(body)), ensure_ascii=False).encode()
            except (ValueError, TypeError):
                result = b'{"success":false,"message":"Balance access denied"}'
                start['status'] = 403
            start['headers'] = [(k,v) for k,v in start['headers'] if k.lower() != b'content-length']
            start['headers'].append((b'content-length', str(len(result)).encode()))
            await send(start)
            await send({'type': 'http.response.body', 'body': result})
        await self.app(scope, receive, filtered)
