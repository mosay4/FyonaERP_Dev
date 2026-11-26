"""Phone OTP engine (WhatsApp-first, SMS fallback, primary-device codes).

* ``providers`` — MessageProvider abstraction + WhatsApp Cloud / SMS.to.
* ``costs``     — per-message estimates and daily/monthly budgets.
* ``engine``    — persisted state machine (start/resend/verify/process).
* ``worker``    — restart-safe background loop (due actions, expiry, purge).
* ``webhooks``  — WhatsApp status + SMS.to callbacks (signed, idempotent).
"""
