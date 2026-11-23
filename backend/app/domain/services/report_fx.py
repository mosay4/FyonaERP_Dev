"""Request-stable, documented FX valuation for business reports."""
from copy import deepcopy
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation

from sqlalchemy import select, func

from app.domain.entities.finance_entities import ExchangeRateHistory

UTC = timezone.utc
ONE = Decimal('1')
ZERO = Decimal('0')


def decimal_value(value):
    try:
        result = Decimal(str(value))
        return result if result.is_finite() else ZERO
    except (InvalidOperation, ValueError, TypeError):
        return ZERO


def utc(value):
    return value.replace(tzinfo=UTC) if value.tzinfo is None else value.astimezone(UTC)


class FxResolver:
    def __init__(self, db):
        self._db = db
        self._history = {}
        self._loaded = False
        self._info = getattr(db, 'info', {})
        self._now = self._info.setdefault('report_valuation_at', datetime.now(UTC))
        self._policy = self._info.get('report_fx_policy', 'historical')

    async def _load(self):
        if self._loaded:
            return
        cached = self._info.get('report_fx_history')
        if cached is None:
            rows = (await self._db.execute(select(
                ExchangeRateHistory.currency_code,
                ExchangeRateHistory.average_rate,
                func.coalesce(ExchangeRateHistory.effective_at, ExchangeRateHistory.created_at),
                ExchangeRateHistory.base_currency,
            ).where(
                ExchangeRateHistory.average_rate > 0,
                ExchangeRateHistory.source.notin_(['fallback', 'hardcoded', 'seed']),
            ).order_by(func.coalesce(ExchangeRateHistory.effective_at,
                ExchangeRateHistory.created_at), ExchangeRateHistory.created_at,
                ExchangeRateHistory.id))).all()
            cached = {}
            pairs = {}
            for code, value, at, *base in rows:
                rate = decimal_value(value)
                if rate > 0:
                    code = str(code).strip().upper()
                    base = str(base[0] if base else 'USD').strip().upper()
                    pairs.setdefault((base, code), []).append((utc(at), rate))
                    if base == 'USD':
                        cached.setdefault(code, []).append((utc(at), rate))
            self._info['report_fx_history'] = cached
            self._info['report_fx_history_pairs'] = pairs
        self._history = cached
        self._loaded = True

    def _pair_at(self, source, target, at):
        pairs = self._info.get('report_fx_history_pairs', {})
        for key, inverse in [((source, target), False), ((target, source), True)]:
            best = None
            for ts, rate in pairs.get(key, []):
                if utc(ts) > utc(at):
                    break
                best = rate
            if best is not None and best > 0:
                return best, inverse
        return None

    def _hist_rate_at(self, code, at):
        if code == 'USD':
            return ONE
        result = None
        for ts, rate in self._history.get(code, []):
            if utc(ts) > utc(at):
                break
            if rate.is_finite() and rate > 0:
                result = rate
        return result

    async def _current(self):
        cached = self._info.get('report_fx_current')
        if cached is not None:
            return cached
        from app.domain.services.currency_service import CentralFXEngine
        try:
            data = deepcopy(await CentralFXEngine.get_instance().get_all_rates())
        except Exception:
            data = {}
        rates = {'USD': ONE}
        meta = data.get('meta') or {}
        self._info['report_fx_snapshot_metadata'] = meta
        if meta.get('global_source') not in (None, '', 'fallback', 'unknown'):
            for code, value in (data.get('global') or {}).items():
                rate = decimal_value(value)
                if rate > 0 and not code.startswith('YER'):
                    rates[code.strip().upper()] = rate
        yemen = data.get('yemen') or {}
        pairs = {}
        if yemen.get('source') not in (None, '', 'fallback', 'unknown'):
            for code, city in [('YER_OLD', 'sanaa'), ('YER_NEW', 'aden')]:
                rate = decimal_value(((yemen.get(city) or {}).get('USD') or {}).get('average'))
                if rate > 0:
                    rates[code] = rate
                direct = decimal_value(((yemen.get(city) or {}).get('SAR') or {}).get('average'))
                if direct > 0:
                    pairs[('SAR', code)] = direct
        manual_pairs = {}
        for row in data.get('admin_rates') or []:
            rate = decimal_value(row.get('average_rate'))
            base = (row.get('base_currency') or 'USD').upper()
            code = str(row.get('currency_code', '')).strip().upper()
            if base == 'SAR' and code in ('YER_OLD', 'YER_NEW') and rate > 0:
                manual_pairs[('SAR', code)] = rate
                continue
            if base != 'USD':
                continue
            if rate > 0:
                rates[code] = rate
                pairs = {pair: value for pair, value in pairs.items() if code not in pair}
        pairs.update(manual_pairs)
        rates['USD'] = ONE
        self._info['report_fx_current'] = rates
        self._info['report_fx_current_pairs'] = pairs
        return rates

    def _missing(self, amount, source, target, at, reason):
        row = {'currency': source, 'target': target,
               'original_amount': str(amount), 'at': utc(at).isoformat(),
               'reason': reason}
        rows = self._info.setdefault('report_fx_missing', [])
        if row not in rows:
            rows.append(row)

    async def convert(self, amount, from_cur, to_cur, at):
        source = str(from_cur or 'SAR').strip().upper()
        target = str(to_cur or 'SAR').strip().upper()
        source = 'YER_NEW' if source == 'YER' else source
        target = 'YER_NEW' if target == 'YER' else target
        amount = decimal_value(amount)
        if source == target or not amount:
            return amount
        at = utc(at)
        if at.date() > self._now.date():
            self._missing(amount, source, target, at, 'future_operation')
            return None
        self._info.setdefault('report_fx_used_currencies', set()).update((source, target))
        if self._policy == 'latest_approved' or at.date() == self._now.date():
            rates = await self._current()
            pairs = self._info.get('report_fx_current_pairs', {})
            direct, inverse = pairs.get((source, target)), pairs.get((target, source))
            if direct is not None:
                return amount * direct
            if inverse is not None:
                return amount / inverse
            rf, rt = rates.get(source), rates.get(target)
        else:
            await self._load()
            direct = self._pair_at(source, target, at)
            if direct is not None:
                rate, inverse = direct
                return amount / rate if inverse else amount * rate
            rf, rt = self._hist_rate_at(source, at), self._hist_rate_at(target, at)
        if rf is None or rt is None or rf <= 0 or rt <= 0:
            self._missing(amount, source, target, at, 'documented_rate_missing')
            return None
        return amount * rt / rf
