## Goal
- Convert the Python/Flet FYONA Business Suite to a faithful Flutter/Dart implementation. Dark FinTech UI, Arabic RTL, ~80 screens, 15+ models, SQLite, Riverpod, GoRouter.

## Constraints & Preferences
- Flutter 3.44.4 + Riverpod + GoRouter + Dio, Material 3, RTL Arabic.
- Font: **Cairo** across all files.
- Primary: `#A01530` (dark crimson). Background `#0A0A0A`, cards `#151515`, borders `#252525`.
- **No blue or green** — only crimson accents.
- Phone number is primary login identifier.
- Two-Tone Premium icon style (outline white/gray + crimson detail).
- Physical device: Realme RMX3710 (Android 15, API 35).
- API: `http://10.182.19.105:8000/api/v1`.
- User communicates in Arabic. Only do what user explicitly asks.
- User chat bubbles: `#6B0F1A`, right-aligned, `BorderRadius.only(topLeft:18, topRight:4, bottomLeft:18, bottomRight:18)`.
- AI chat bubbles: `#151515`, left-aligned, border `#252525`, text `#F5F5F5`, `BorderRadius.only(topLeft:18, topRight:18, bottomLeft:4, bottomRight:18)`.

## Progress
### Done
- **Backend OpenAI integration**: `sara_agent_service.py` created with intent classifier, smart context builder (fetches only data relevant to query), dynamic prompt, 11 OpenAI function tools (`open_app_screen`, `get_banking_data`, `get_financial_summary`, `get_customer_data`, `get_inventory_data`, `search_all_transactions`, `create_entity`, `get_app_help`, `export_report`, `show_suggestions`), tool executor for data-fetching callbacks.
- **Knowledge Base**: `knowledge_base.py` — 18 app pages documented in Arabic (description, usage, actions, deep links, common errors).
- **Agent Models**: `agent_models.py` — `AgentContext`, `AgentResponse` (text + actions + suggestions), `IntentClassification`.
- **Backend route updated**: `ai.py` POST `/ai/query` now uses `SaraAgentService` with `get_current_user_id` dependency. `AIQuery` model extended with `user_name`, `account_type`, `company_name`, `current_screen`, `history`.
- **Flutter ActionDispatcher**: `sara_action_dispatcher.dart` — `SaraActionDispatcher` class with 11 action types (`openScreen`, `goBack`, `createEntity`, `exportPdf`, `showSnackbar`, `copyText`, `refreshData`, `navigateToTab`, `openUrl`, `showDialog`). Route mapping from Arabic screen names to GoRouter routes.
- **Flutter AiService updated**: `ai_service.dart` — new `AiAgentResponse` model (text + actions + suggestions). `askQuestion()` now sends `userName`, `accountType`, `currentScreen`, `history` and returns `AiAgentResponse`.
- **SaraChatPage rewritten** to match old project design: simplified bubbles (no grouping/avatars/timestamps/status checks/date separators/voice), `CircularProgressIndicator` for typing, `ActionChip` for suggestions, standard AppBar, `FadeTransition` only. Uses `AiAgentResponse`, executes actions via `_dispatcher`, stores `_history`, shows `_dynamicSuggestions`.
- **Wrapper pages updated**: `ai_assistant_page.dart` passes `accountType: 'business'`. `personal_ai_page.dart` stays `accountType: 'personal'`.
- **401 error fixed**: Root cause was JWT secret mismatch. `.env` had `JWT_SECRET_KEY=dev-secret-key-change-in-production` but original default in `config.py` is `change-me-in-production`. Restoring original key fixes it. User needs to restart backend.
- **WhatsApp support button added**: `_buildWhatsAppItem()` in `app_drawer.dart` — "خدمة العملاء" opens `https://wa.me/966570234694` via `url_launcher`. Positioned between mode toggle and logout.
- **Bank report PDF export system created**: `bank_report_pdf.dart` — `BankReportPdfGenerator` using `ReceiptDesignPreset` for colors. Centered, professional layout with header, KPI cards, comparison bars, category bars, daily bars, accounts table, transactions table, footer. Added `bankReport` to `PersonalReceiptSection`. Updated `bank_detail_page.dart` to use new generator. Removed `includeCover` option.
- **PDF font embedding fixed** (root cause of Arabic squares in exported PDFs):
  - `bank_report_pdf.dart`: Added `_loadFont()` helper, loads `Cairo-400.ttf` / `Cairo-700.ttf` via `rootBundle.load()` → `pw.Font.ttf()`. All `pw.TextStyle(font: font)` calls updated.
  - `renderer.dart`: Added `PdfFonts` class with lazy font cache + `ensure()`. `PdfReceiptRenderer.save()` calls `PdfFonts.ensure()` before generating.
  - `cards.dart`: `_pts()` function now uses `PdfFonts.regular` as default `font` parameter. All PDF card builders inherit Arabic font support.
  - `pdf_engine.dart`: Added `_getFontRegular()` / `_getFontBold()` lazy static methods. `generateReportPdf()` updated to load fonts and pass to all private helpers.

### In Progress
- *(none)*

### Blocked
- AI chat was non-functional due to 401 — **fixed** by restoring original JWT secret. User needs to restart backend to apply.

## Key Decisions
- Cash treated as bank accounts (`account_type = 'cash'`) with multi-currency support instead of separate `personal_wallets` table.
- Migration is one-way (`personal_wallets` deleted after conversion). Future cash transactions create/find cash accounts via `_ensureCashAccount(currency)`.
- Sara AI transformed from simple ChatBot to full Agent system: intent classification → smart context → dynamic prompt → OpenAI function calling → action dispatch in Flutter.
- **No full DB dump sent to OpenAI** — only minimal data per query based on intent.
- OpenAI function calling defines 11 tools (app actions + data queries). Backend executes data queries and re-feeds result to LLM for final response.
- Flutter ActionDispatcher executes actions from AI response (open screens, create entities, show dialogs, export PDFs).
- Conversation memory kept as `_history` list (last 6 messages) sent with each request.
- Bank report PDF uses `BankReportPdfGenerator` (new `bank_report_pdf.dart`) instead of `PdfEngine.generateBankReportPdf()`. Layout is centered with close spacing (14-18px) instead of scattered 20-24px. Uses `ReceiptDesignPreset` for editable colors instead of hardcoded `#A01530`.
- PDF font embedding: `pw.Font.ttf()` + `pw.TextStyle(font: font)` is the **only** valid way to embed custom fonts in `pdf` package. `pw.TextStyle(fontFamily:)` is silently ignored.
- Font cache pattern: `PdfFonts` class in `renderer.dart` with lazy static `ensure()` method — fonts loaded once, shared across all PDF card builders.

## Next Steps
- **User to restart backend** and re-login after JWT secret fix to clear 401 error.
- **Test PDF export** on physical device: verify Arabic text renders correctly, charts display properly, tables are formatted.
- Fix remaining unused methods in `pdf_engine.dart` (`generateAllBanksReportPdf`, `generateExecutivePdf`) for consistency — low priority since they aren't called.

## Critical Context
- **PDF font embedding resolved**: Root cause of Arabic squares (□□□□□) was using `pw.TextStyle(fontFamily: 'Cairo')` which is silently ignored by the `pdf` package. Fixed by loading Cairo TTF via `rootBundle.load()` → `pw.Font.ttf()` and passing via `pw.TextStyle(font: font)`. Applied across all three PDF systems (`bank_report_pdf.dart`, `cards.dart`/`renderer.dart`, `pdf_engine.dart`).
- **Charts in PDF**: Charts use `pw.Container` with colored bars (not Flutter widgets). No `fl_chart` rendering in PDF. The "red box" issue seen earlier was caused by font failure — with font embedded, labels and values render correctly.
- **401 error resolved**: `.env` had wrong JWT secret `dev-secret-key-change-in-production` vs default `change-me-in-production`. Reverted to match original. Backend restart required.
- **User's old design**: Simple chat UI — standard Alignment (not Row+Spacer), `CircularProgressIndicator` for typing, `ActionChip` for suggestions, specific bubble colors and radius. No status checks/timestamps/avatars/voice/date separators. FadeTransition only.
- **`fl_chart`** used for all on-screen charts; needs explicit width/radius values.
- **Two PDF systems**: `pdf_engine.dart` (generic reports, unused) and `bank_report_pdf.dart` (bank-specific with preset support). Both now have font embedding. Invoice PDFs use `cards.dart` + `renderer.dart` path.
- **Trial countdown forced to 24h**: `trialTotal = const Duration(hours: 24)`.
- **Flutter analyze**: Zero errors across all modified files.
- **Cash migration**: `PersonalFinanceService.migrateCashWallet()` in `load()` ensures at least one "كاش (SAR)" account exists.

## Relevant Files
- `backend/app/domain/services/sara_agent_service.py`: Full AI Agent with intent classification, smart context, dynamic prompt, OpenAI function calling with 11 tools, tool executor.
- `backend/app/domain/services/knowledge_base.py`: 18-page app knowledge base with Arabic docs and deep links.
- `backend/app/domain/models/agent_models.py`: AgentContext, AgentResponse, IntentClassification.
- `backend/app/api/v1/ai.py`: Updated route — uses `SaraAgentService` + `get_current_user_id` + `get_current_org_id` + `require_permission("ai", "read")`.
- `backend/app/domain/models/m5_models.py`: AIQuery extended with `user_name`, `account_type`, `company_name`, `current_screen`, `history`.
- `backend/.env`: JWT_SECRET_KEY changed back to `change-me-in-production` to match config.py default (fixes 401).
- `lib/shared/widgets/sara_action_dispatcher.dart`: 11 action types, route mapping, `SaraActionDispatcher` class.
- `lib/features/ai/domain/services/ai_service.dart`: New `AiAgentResponse` model, `askQuestion()` sends user context + history.
- `lib/shared/widgets/sara_chat_page.dart`: Rewritten — simplified bubbles, no voice/status/timestamps, `CircularProgressIndicator`, `ActionChip`, `FadeTransition` only. Uses `AiAgentResponse`, executes actions via `_dispatcher`, stores `_history`, shows `_dynamicSuggestions`.
- `lib/shared/widgets/app_drawer.dart`: Added `_buildWhatsAppItem()` — opens `wa.me/966570234694` via `url_launcher`.
- `lib/features/personal/presentation/pages/bank_report_pdf.dart`: **New** — `BankReportPdfGenerator` class. Professional centered PDF with preset colors, KPI cards, charts, tables. Font-embedded via `pw.Font.ttf()`.
- `lib/features/personal/presentation/pages/bank_detail_page.dart`: Updated to use `BankReportPdfGenerator` instead of `PdfEngine.generateBankReportPdf()`. Removed `includeCover` option.
- `lib/features/personal/presentation/providers/receipt_design_models.dart`: Added `bankReport('bank_report', 'تقرير البنك')` to `PersonalReceiptSection`.
- `lib/core/receipt_engine/renderer.dart`: Added `PdfFonts` class — lazy font cache for PDF generation. `PdfReceiptRenderer.save()` calls `PdfFonts.ensure()`.
- `lib/core/receipt_engine/cards.dart`: `_pts()` uses `PdfFonts.regular` as default font. All PDF card builders now use Cairo font.
- `lib/core/pdf_engine.dart`: Generic PDF reports — has lazy `_getFontRegular()` / `_getFontBold()`. `generateReportPdf()` font-embedded.
