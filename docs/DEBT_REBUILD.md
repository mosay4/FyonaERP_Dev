# Debt rebuild — implementation / verification map

References inspected visually: each of the seven PDFs has one raster page.
Reference values and names are examples, never production seed data.

| PDF | Screen | State / API | Financial source / access |
| --- | --- | --- | --- |
| Business Debt Interface.pdf | `/debts` | notification unread count | own notification recipient |
| Post-entry for customer or supplier accounts.pdf | `/debts/customers`, `/debts/suppliers` | party search | existing Customer/Supplier, organization permission |
| After accessing a client or supplier account.pdf | debt party detail (`/customers/detail`, `/suppliers/detail`) | `GET /merchant-links/overview`, group CRUD, assign, existing invoice/payment/settlement services | same Invoice + CustomerReceivable/SupplierPayable; org / party scope |
| My Accounts with Merchants button interface in the personal section.pdf | `/personal/merchant-accounts` | accepted MerchantLinks + invites | external user + accepted relation |
| After selecting the merchant in the personal section.pdf | `/personal/merchant-partner` | `GET /me/merchant-links/{id}/debt-overview` + enabled currency prefs + own settlement requests | linked merchant's receivables/payables; display-only CentralFXEngine |
| Personal Debt Sections Interface.pdf | sections tab of merchant | DebtGroup + operation counts | same relation / party scope |
| After entering a specific religious section.pdf | `/personal/debt-section` | group-scoped overview, operation detail | group owned by linked party; original invoice only |

## Round 43 — localized Premium guard + receipt-upload notice

- The backend's English Premium guard is mapped to the app language
  (`premiumIncludesSections`): Arabic «الباقة الذهبية تشمل القسمين الشخصي
  والأعمال، ولا يمكن إضافة باقات فردية لها».
- The receipt-upload path (رفع صورة السند) now SHOWS the same notice instead of
  silently failing: the upload error is surfaced from the receipt provider.
- Added `subscription_errors.dart` (premiumSubscriptionError /
  localizeSubscriptionError) and a unit test for the mapping.

Flutter 41/41; analyze 0. No APK build (branches feature next).

## Round 42 — purchase line steppers, auto-fit price/unit

- Shared invoice line widgets: QtyStepper (+ right / − left), AutoNumField
  (font shrinks as digits grow), UnitLineField (full unit via FittedBox; the
  arrow appears ONLY when the product has >1 unit, single unit non-clickable).
- Purchase product line: qty stepper, narrower price (flex 3), wider unit
  (flex 4). Sale line unit field uses the same smart unit widget.

Flutter 38/38; analyze 0.

## Round 41 — debt amount/currency fit, purchase qty steppers, «دين» wording

- Paid/remaining breakdowns (business debt total + personal monitoring hero)
  use FittedBox rows (amount + full currency label), so long labels like
  «ريال يمني قديم» and huge amounts are never clipped; the currency selector
  chip scales too.
- Purchase add-product: tighter price box (flex 2 vs qty 3) and a qty stepper
  (+ on the right, − on the left) in both variants.
- Replaced «آجل» with «دين» in all Arabic strings.

Flutter 38/38; analyze 0.

## Round 40 — link notifications open the alerts tab

- Accept/reject/unlink phone pushes now deep-link to
  `/debts/notifications?tab=alerts` (the merchant sees the alert in the tab
  immediately). The in-app row still opens the party detail.
- `DebtNotificationsPage` accepts `initialTab`; route builders map tab=alerts
  to index 1 (business) / 3 (personal).
- Verified on the real DB: the merchant receives the in-app `link_accepted`
  row (to_side=merchant) and the push route is the alerts tab.

Backend 117/117; Flutter 38/38; analyze 0.

## Round 39 — merchant-side party naming + real avatar

- Merchant chat/notifications now show the merchant's OWN party name
  (`Customer.name`/`Supplier.name`), while the avatar stays the real personal
  account picture. Personal profile renames no longer rewrite the party name.
- Real personal name appears only in the link request (lookup/approval).
- Personal side always sees the business name + business avatar (org), in chat,
  lists and invites.
- Rate-limit fix: /auth/me* and /auth/sessions use the normal bucket (the 10/min
  auth bucket caused 429 on profile saves).

Backend 117/117; Flutter 38/38; analyze 0.

## Round 38 — personal/business identity separation

- Personal profile edits update the ACCOUNT (full_name/avatar); business edits
  update the ORGANIZATION (name + new organizations.avatar column) — never the
  account. Removed the cross-section setNameAll/setAvatarAll flow.
- New `POST /auth/me/organization/avatar`; chat `_shop` uses the org avatar;
  user invites/links use the org name/avatar (fallback owner avatar).
- UserResponse now carries organization_name/organization_avatar so the
  business profile shows the real shop identity and auto-syncs only its own
  section.
- Section-local auto-sync: personal compares with full_name, business with
  organization_name; avatars upload to the matching endpoint.

Backend 117/117; Flutter 38/38; analyze 0.

## Round 37 — global identity sync, profile name check, phone/code polish

- Name save now also updates the SERVER account (and the org/shop name in the
  business section), sets BOTH section overrides, and propagates to every
  `MerchantLink.display_name` + linked party names that still matched the old
  name — so merchants/customers see the new name in lists, chat and invites.
- Inline check button appears next to the name after any edit (no full-width
  save row).
- Avatar crop uploads to `/auth/me/avatar` AND sets both section overrides, so
  the other side sees the new picture.
- Profile code chip is a compact red-translucent chip in both themes; phone is
  LTR `+967...`; phone edit page: country selector first (LTR), edit-specific
  title/subtitle, «حفظ الرقم الجديد» disabled until typing, masked current as
  `+967****880`.

Backend 117/117; Flutter 38/38; analyze 0.

## Round 36 — add-without-debt, themed toast, one-link-per-account

- Adding a party from the debts page now works with amount = 0 too: the
  post-sheet guard still required `amount > 0`, so a debt-less add closed the
  sheet and created nothing. Guard relaxed; the party is created and both
  lists reload (opening debt only when amount > 0).
- Pending-invite toast is theme-aware (white text on dark, black on light).
- Backend refuses to link the SAME personal account (phone/public code) to the
  merchant twice through a different party, with a clear Arabic message; the
  invite UI surfaces the server message. Relinking after a revoke stays allowed.

Backend 117/117 (+2); Flutter 38/38; analyze 0.

## Round 35 — short pushes, empty sections, header title/height, chat gap

- Phone-tray link pushes are one short line: invite «التاجر X – يريد ربط دينك
  لمتابعته بشكل مباشر», accept/reject/unlink shortened; details live on the
  request page the tap opens.
- Empty debt-sections page: replaced the huge button with a designed empty
  state (icon, title, hint, compact pill «إضافة قسم جديد»).
- Top bar title is static per section: «القسم الشخصي» / «قسم الأعمال»
  (activeSectionProvider), with slightly more vertical padding so nothing is
  clipped.
- Chat: removed the duplicated top SafeArea inside the shell so the peer
  card sits directly under the top bar (keyboard behaviour untouched).

Backend 115/115; Flutter 38/38; analyze 0.

## Round 34 — home grid regression, debt add sheet, chat in debt pages, payable card

- Home quick-action cards: the dot Stack passed LOOSE constraints, so cards
  shrank to their content (uneven widths/heights). `StackFit.passthrough`
  restores the full-width equal cards.
- Add-party sheet (from the debts lists) now checks duplicate names inline,
  reloads the list on success, and returns success once the PARTY is created
  even if the opening-debt step fails (with a specific message).
- Chat icon added to the individual/section debt detail app bars for both
  sides (business resolves the link id via `link-status`).
- «المستحق الحالي» redesigned as a bordered card with a wallet header and
  sorted currency chips (formatted amounts, no raw `+` / `OLD` concatenation);
  the sale prior-debt card uses the same style.

Flutter 38/38; analyze 0.

## Round 33 — document edit details, payment perspective, cash full, section sheet

- «عرض الفاتورة» badge is now tappable when modified and expands the same
  per-change details (product/date/employee or manager, only changed tables);
  unmodified invoices show no badge at all.
- Payments wording is perspective-aware: merchant receives on customer debts
  («حصلت») / pays suppliers («دفعت»); the personal party sees the mirror.
- Cash supplier/customer (no registered party) now offers «دفع كامل» again even
  in debt mode (partial/credit remain).
- Debt type (individual/section) selector rebuilt as a designed bottom sheet
  (handle, title, subtitle, icon tiles, counts, scroll) instead of an upward
  dropdown that covered the labels.

Flutter 38/38; analyze 0.

## Round 32 — add-save, push wake-up, dot corner, notification wording

- Add-party sheet: the inline error state lived INSIDE the StatefulBuilder and
  reset on every rebuild (Save looked dead when the amount was empty); moved it
  out, made the sheet scrollable, show the error above Save, and allow saving
  with amount 0 (party only). Success text is «تمت الإضافة بنجاح».
- Push: Android now requests battery-optimisation exemption once (Doze/OEM
  killers were the reason pushes stopped after swiping the app); token still
  re-syncs on resume. Server log check: FCM high priority, active token,
  test send = sent:1.
- Red dot moved to the card corner; stale invites (link no longer pending) are
  auto-marked read so the dot cannot stick after handling them.
- Edit notification text no longer lists product/qty: «عدّل التاجر الفاتورة
  <number>. لعرض جميع التفاصيل اضغط هنا».
- Invoice detail from a notification uses the real invoice number as the title
  (the route had passed the UUID as `name`).
- Edit push now actually fires: the old varchar(80) event_id 500 aborted the
  transaction before the post-commit push.

Backend 115/115; Flutter 38/38; analyze 0.

## Round 31 — edit-save 500 root fix, invite copy, list cleanup

- ROOT CAUSE of the edit 500: composite `event_id`
  (`debt_edited:<invoice>:<link>` = 85 chars) exceeded the legacy
  `app_notifications.event_id varchar(80)` → Postgres DataError → 500 and the
  whole edit rolled back. `init_db` now widens it to 200 (idempotent) and
  `emit` truncates defensively. Verified with an 85-char id on the real DB.
- Customer/supplier list: removed the inline debt-amount FutureBuilder; the
  row shows only the name (tap still opens the party/debt detail).
- Invite: success says «تم إرسال طلب التتبع للعميل/للمورد»; a repeat while
  pending shows a one-line clock toast «لديك طلب سابق … أخبره ليوافق».
- Invoice edit sheet: cursor starts AFTER the prefilled number (backspace
  removes the last digit), an X closes without saving, Save is translucent and
  disabled until a real change, and the label is fully visible (54px min).

Backend 115/115; Flutter 38/38; analyze 0.

## Round 30 — side-scoped notifications, chat dots, invite/dup fixes

- «حذف الربط» → «إلغاء الربط» (button + dialog).
- 4 personal tabs never truncate: FittedBox + 11.5px labels, zero padding.
- Business bottom nav icons re-centred in their 36px chip (dot included).
- Notifications are SIDE-scoped: payload `to_side` + `side` filter on list,
  unread and a new per-link chat unread endpoint. One dual-role login now has
  fully separated personal/business centers and red dots; opening a chat
  marks its chat notifications read (clears both dots).
- Red dot on the chat icon (partner overview, personal operation, business
  party) from unread chat counts. FCM token re-syncs on every app resume.
- Invite dialog: ONE field «ادخل رقم الهاتف أو الرقم المميز للمستخدم»
  (10.5px hint), auto-detects a 6-digit code vs phone.
- Duplicate customer/supplier name: inline red warning inside the add dialog
  (name kept editable), plus the server-side guard.
- Phone rendering split label/value with an LTR number so `+` stays first.

Backend 114/114; Flutter 38/38; analyze 0.

## Round 29 — unread dots, edited badge details, quantity formatting

- «حذف الربط» bottom button: minimum size + padding + line height (no clip).
- Red unread dot on the personal «حساباتي مع التجار» tile and the business
  «الديون» tab, fed by `/debt-notifications/unread` (excludes own actions) and
  polled every 15s; the notification center invalidates it after mark-read.
- Edit quantities prefill/display without `.0` (1, 2, 3); fractions only when
  the merchant typed them (`debtPlainNum`).
- Edited badge is red; tapping it expands a smooth panel INSIDE the badge with
  per-product before/after tables (only the changed fields), date, employee
  name or «المدير». `?edits=1` auto-opens it from the edit notification, which
  now carries invoice number + concise change summary + «اضغط هنا».
- Invoice document shows a red «معدّلة» chip only when modified.
- Per-line change text removed (details live in the badge).

Backend 113/113 (+11 categories/unread); Flutter 37/37; analyze 0.

## Round 28 — notification routing, 4/2 tabs, invite copy

- Cold-start push taps now wait for the intro/splash (and login) to finish:
  `NotificationRouter.navigate` queues while on splash/login/choose-usage and
  the shell + splash flush the queue; a chat/debt deep link opens directly.
- Chat back arrow always responds: pop when possible, otherwise go to the
  correct notifications/list screen.
- Notification categories: chat / settlement / alert / debt. Personal center
  shows 4 tabs (الديون، السداد، الرسائل، التنبيهات); business center shows 2
  (الرسائل، التنبيهات, everything non-chat). Own actions are filtered out via
  the event's `sender_user_id` / `actor_user_id`.
- Debt-created/edit/delete notifications carry the merchant name and keep the
  `?op=` invoice deep link; invite alerts carry the merchant name + phone and
  open the requests page.
- Invite UI: raw «Organization» removed, merchant phone shown in
  `+966XXXXXXXX` form, classification sentence and clearer link body.

Backend 111/111 (+9 categories/self-filter); Flutter 37/37; analyze 0.

## Round 27 — remove hint + allow over-payment

- Removed the hint paragraph under the add-party form entirely.
- Over-payment is now allowed for individual invoices and section debts: the
  debt is cleared with its exact remainder, the extra still moves through the
  bank (customer advance / rounded supplier payment), and the sheet previews
  «سيُسدَّد» + «مبلغ زائد (دفعة مقدمة)». No more "amount must match" block.

Backend 102/102 (+7 overpay); Flutter 37/37; analyze 0.

## Round 26 — debt UX: opening balances, bank-first settlement, clipping

- Debts lists bottom button is now «إضافة مورد جديد» / «إضافة عميل جديد»:
  name + optional phone + opening amount/currency → party + confirmed
  «رصيد افتتاحي» invoice (`create_opening_debt`), so it behaves like any party.
- Kept «إضافة دين جديد» inside individual debts and inside a section; fixed
  the fixed-height clipping with minimum-size + vertical padding + line height.
- Removed the duplicated «تسديد للمورد» block in a section; the button is now
  one full-width button, and a fully-settled section/invoice shows a disabled
  translucent-green «مسدد بالكامل».
- New settlement sheet (section debts): bank first → currency/account of that
  bank (type + available balance) → amount → live FX rate (editable) with
  «سيُسدد»/«المتبقي بعد العملية» preview. Single invoices keep the invoice
  currency only. Backend `_settle_party` already freezes the rate and posts one
  account movement; verified 100 USD debt settled with 375 SAR at 0.2666667.
- Invoice detail: taller padded buttons (payments no longer clipped).

Backend 95/95 + opening/FX ad-hoc verified; Flutter 37/37; analyze 0.

## Round 25 — unlink + party deletion

- Personal «حساباتي مع التجار»: trash button beside the bell enters selection
  mode; pick a merchant → warning (the merchant is notified, the link is
  removed, return only by a new invite) → biometric/PIN gate → unlink.
  Backend `POST /me/merchant-links/{id}/unlink` revokes the link and notifies
  the merchant; the merchant's party and debts stay intact.
- Business debt lists (suppliers/customers): removed the letter-avatar circles
  and the pointless chevron inside the red header card. Added a bell + delete
  button; long-press selects a party, then delete asks:
  • linked → revoke + notify the personal user, hide the party;
  • not linked → permanent delete with JSON + audit backup; FK CASCADE drops
    the explicit debt rows while invoices keep their balance anonymised
    (customer/supplier = NULL), i.e. balances stay with an unknown source.
- Re-accepting an invitation restores a hidden party.

Backend 95/95 (+14 new); Flutter 37/37; analyze 0.

## Round 24 — header layout + waveform direction

- Header raised (2px top margin) and re-ordered to match RANY: back circle at
  the LEFT edge, avatar next, name/status immediately beside the avatar (RTL),
  no wasted gap; the back is no longer crowded against the avatar.
- Voice waveform seek was inverted in RTL: the timeline starts on the RIGHT,
  so `fraction = 1 - x/width`. Dragging left now advances, dragging right goes
  back, matching the on-screen waveform.

Backend 81/81; Flutter 37/37; analyze 0.

## Round 23 — RANY.pdf visual identity (logic unchanged)

- Soft rose background with radial pink blobs (`ChatStyle` + `ChatBackgroundPainter`).
- Floating white rounded header: circular white back button with a red border,
  orange→crimson avatar (image or initial), bold name, green/red presence +
  «متصل الآن/غير متصل».
- Bubbles: sent = crimson gradient on the LEFT with 20/6 corners; received =
  white on the RIGHT with a pink border + soft shadow; blue read checks.
- Voice: red/white waveform seek bar (tap/drag) + circular play/pause + 1×/1.5×/2×
  chip + current/total times; the same recorded-duration sync is kept.
- File: icon tile + name + download; album: red/white card with rounded tiles and
  a white/pink «+N» tile with red text.
- Composer: transparent rose bar, white pill input, circular red «+» and mic/send.
- Recording bar: white floating card with the red waveform and circular actions.
- All send/receive, background-upload, receipts, reply, seek and notification
  logic is unchanged.

Backend 81/81; Flutter 37/37; analyze 0.

## Round 22 — voice bar sync, swipe side, edited label

- Voice bar completing early: a stale player position from the previous clip
  could override the new clip's position. Starting a new clip now applies a
  400ms position grace and resets playback speed to 1×, so the bar advances 1:1
  over the recorded duration (verified files: 6.1s / 4.09s vs duration_ms
  6085 / 4068).
- Swipe-to-reply visual direction now follows the swapped sides
  (`mineOnRight = mine ? !rtl : rtl`); the bubble translates toward the empty
  side and the reply icon appears there.
- The «معدلة» label has an 8px gap from the time, bolder 10px text and a clear
  black-on-white / white-on-red color.

Backend 81/81; Flutter 37/37; analyze 0.

## Round 21 — upload timeout, instant voice, side swap

- **Video upload failing part-way root cause**: the global Dio `sendTimeout`
  was 30s, so any upload longer than 30s aborted at a percentage. Media uploads
  now use a per-request 60-minute send timeout / 10-minute receive timeout.
- **Voice playback speed**: voice notes are prefetched/cached to a temp file in
  the background when messages load (latest 30), so tapping plays instantly
  instead of downloading first. The download remains as a fallback.
- **Received voice seek snap-back**: added a 700ms seek grace that ignores
  stale position events right after a seek, and position updates were tightened
  to 0.1s for a smooth bar that matches the recorded duration.
- **Message side swap**: sent messages now sit on the LEFT (red) and received on
  the RIGHT (white) in the RTL app; bubble corners, swipe-to-reply direction and
  the pending bubble follow the new side.

Backend 81/81; Flutter 37/37; analyze 0.

## Round 20 — file bubble restored, pending layout, recorded duration

- **Empty file message root cause**: the `kind == 'file'` branch had been dropped
  from `_ChatBubble` during an earlier voice-UI replacement, so file messages
  rendered only the timestamp. The branch is restored (icon + file name + open +
  download) and verified from real DB rows (`file_name` is present).
- **Upload progress circle**: for files/voice the circle no longer overlays the
  name/text; it sits at the end of the row. Media/albums keep a centered overlay
  on the image/grid (no text under it). Captions stay below.
- **Recorded duration**: `chat_messages.duration_ms` (+ API `duration_ms`) is
  stored when sending a voice note; the player's slider max/duration uses the
  recorded length (fallback to the player duration for old messages), so the bar
  matches the real recording. Seeking updates the position immediately.
- Pending uploads stay in the global `ChatUploadManager` when leaving the chat.

Backend 81/81; Flutter 37/37; analyze 0.

## Round 19 — no compression (fast send), voice seek, album download-all, preview fix

- **Compression removed** (calls + `video_compress` dependency): sending starts
  immediately; uploads stream from disk. The chat poll was reduced to 1s so the
  recipient sees the message ~1s after the upload finishes. (A 300MB upload is
  still bounded by the sender's network bandwidth.)
- **Voice seek root cause**: the bubble's swipe-to-reply `GestureDetector` was
  stealing the horizontal drag from the Slider. Swipe-to-reply is now disabled
  for voice messages (use long-press to reply), and `_seekVoice` updates the
  local position immediately, so dragging seeks reliably.
- **Album download**: the viewer's download button now offers «تنزيل هذا المحتوى
  فقط» and «تنزيل الجميع» (label adapts: all images / all videos / all). Download
  all loops silently and shows one summary.
- **Local preview conflict**: previewing a selected video before sending now
  pushes the player on the ROOT navigator, so it sits above the album-dialog and
  Back returns to the still-open selection (nothing is deselected).

Backend 81/81; Flutter 37/37; analyze 0.

## Round 18 — album direction, media MIME, album edit, background uploads

- Album pager now opens on the LEFT and advances by swiping RIGHT in the RTL
  app (`PageView(reverse: true)`).
- **Voice/video “تعذر إرسال الرسالة” root cause**: `_mimeFor` did not map `m4a`
  (voice) or `3gp/avi` (video), so the backend rejected them with 400. Added the
  missing MIME types AND made the backend accept a known media extension even
  when the content-type is octet-stream. Live uploads of `.m4a`/`.3gp` now
  return 200.
- Album preview: an X on each tile removes it; tapping a tile opens a local
  preview (image viewer / local video player) before sending.
- Uploads moved to a GLOBAL background manager (`ChatUploadManager`): they keep
  running when you leave the chat; pending bubbles and progress are restored
  when you return; completion is picked up by the 2s poll. Progress events are
  throttled to 1% to keep the UI smooth.
- Compression stays background (MediaCodec 540p, skip <6MB/<20s).

Backend 81/81; Flutter 37/37; analyze 0.

## Round 17 — album send fix, faster compression, voice seek, invoice caption

- **Album “تعذر إرسال الرسالة” root cause**: the HTTP send endpoint never
  forwarded `data.media` to `send_message`, so the service raised «لا توجد
  وسائط». The router now passes the media list; a live HTTP album send returns
  200 with `media`.
- **Compression speed**: skip compression for clips < 6MB and < 20s (sent
  instantly); otherwise use hardware MediaCodec at 540p
  (`VideoQuality.Res960x540Quality`) and stream `compressProgress$` into the
  pending bubble percentage. Originals are kept (`deleteOrigin: false`).
- **Viewer title** («صورة» / «فيديو») is explicitly white on the black AppBar.
- **Voice**: the progress slider, current/total time and 1×/1.5×/2× speed are
  visible on EVERY voice message immediately (not only after tapping play); the
  slider follows the finger while dragging (`_seekValue`) and seeks on release.
- **Invoice sharing**: after picking an invoice, a caption dialog lets the
  sender add an optional description; it is stored in `text` and shown in the
  bubble below the invoice number.

Backend 81/81; Flutter 37/37; analyze 0.

## Round 16 — multi-media album (4-up + “+N”) + image quality

- Backend `chat_messages.media` (JSON list) + `kind=album`; `send_message`
  accepts a media list, `_msg_dict` returns `media`/`media_count`, reply
  summaries carry `media_count`, and the push preview is «📷 N صور/فيديو».
- Flutter gallery uses `pickMultipleMedia` (multi-select). One selection keeps
  the single-media flow; multiple open an album preview sheet with a caption,
  upload sequentially with an aggregate progress bubble, then send ONE album
  message. The bubble renders a 2×2 grid (up to 4); when there are more, the
  4th tile shows «+N» and tapping opens a full-screen swipeable album viewer
  (images zoom, videos open the player, save/back).
- Images are compressed on pick (`imageQuality 80`, max 1600px). Video/file
  compression via a native codec/package is NOT shipped (no offline package;
  adding FFmpeg would bloat/risk the build) — uploads stream up to 300MB and
  media auto-cleans after 7 days.

Backend 81/81 (album 4); Flutter 37/37; analyze 0.

## Round 15 — swipe reply, quote jump, voice scrubber, full-screen media, save

- Swipe-to-reply now follows the finger (Transform with the drag), shows a
  reply icon toward the empty side, and triggers at >50px.
- Tapping the quoted snippet scrolls smoothly to the original message
  (`Scrollable.ensureVisible`, ~650ms, centered) and highlights it with a
  YELLOW border for 2s. The quote shows the real other-party name.
- Media downloads: images/videos are saved to the device GALLERY via `gal`
  (with the required READ_MEDIA permissions), documents use the system save
  dialog; a type-specific confirmation snackbar is shown.
- Voice player: progress slider (seek/scrub), current/total time, 1×/1.5×/2×
  speed, play/pause; positions are throttled to avoid rebuilding the list.
- Full-screen black media viewer (route with back + save) for images and
  videos; the video view has a scrubber, play/pause, and duration.
- Voice messages now show an immediate pending bubble with upload progress.
- Reply works for every non-deleted message (text/media) and text replies now
  include the quote (root cause: `_sendText` never passed `reply_to_id`).

Not yet shipped (explicitly): multi-media album grid (4-up + “+N”) and video
compression. They need a dedicated album schema + a compression package and
their own tested release; I did not ship a half version.

Backend 77/77; Flutter 37/37; analyze 0.

## Round 14 — notification routing, media URL, upload 500, reply sync

Root causes found:
- **Media upload 500**: `core.paths.UPLOAD_ROOT` is a `str`, but the new
  streaming upload used `UPLOAD_ROOT / "chat" / name` → TypeError on every
  voice/video/file upload («تعذر إرسال الرسالة»). Fixed with `Path(...)`.
- **Voice/file/image not playing or downloading**: downloads used the API base
  (`/api/v1`) with `/uploads/...` → 404. Added `_mediaUrl()` that resolves
  `/uploads/...` against `AppConfig.apiHostUrl` (root). Voice playback and
  file/image/video download now work; save shows a type-specific confirmation.
- **Notification tap → home**: the same account can be both Business and
  Personal, so a stored `/debts/chat` or `/customers/detail` route bounces in
  Personal (and vice versa). `DebtNotificationsPage` now knows its context
  (`isPersonal`) and rebuilds the route from the payload `link_id`/`message_id`
  for the CURRENT context (`/personal/chat`, `/personal/merchant-partner`,
  `/debts/chat`, or the stored business party route). The backend now returns
  `action_payload` in the list.
- **Reply sent without the quote**: only media sends passed `reply_to_id`; text
  sends did not. Fixed `_sendText` to pass and clear the reply. The action sheet
  now always offers «رد» for any non-deleted message, and a horizontal swipe
  (>250 velocity) triggers reply as well.

All backend suites 77/77; Flutter 37/37; analyze 0.

## Round 13 — chat reply, native gallery, voice toggle, notification isolation

- **«Organization» root cause**: `chat_service._shop` returned the raw org
  name (the earlier cleaner was only in merchant_link_service). It now strips
  «X's Organization» / «Organization» and falls back to the owner name. Verified
  live (`other_name = "Jdjdjddj Jjkknn"`).
- **Recording bar**: replaced the single overflow-prone Row with a two-row
  layout (timer + live waveform, then cancel/pause/send as equal-width buttons)
  above the composer, so the controls are always visible (no white rectangle).
- **Reply**: `chat_messages.reply_to_id` + `reply` summary in the API; long-press
  → «رد»; composer shows the quoted snippet with a close button; the sent bubble
  shows the quoted sender/snippet (WhatsApp-style). Works for both sides.
- **Gallery**: uses `image_picker.pickMedia()` (native photo/video picker);
  «رفع ملفات» uses the document picker (PDF/Word/Excel/text/CSV/ODT/ODS/PPT).
- **Large videos**: upload streams the file to disk (`MultipartFile.fromFile`)
  instead of loading it in RAM; the backend streams the multipart to
  `uploads/chat/` with a 300 MB cap and a 7-day auto-cleanup (temporary relay,
  not permanent storage).
- **Save to device**: image viewer + video player + file bubble have a download
  button (`FilePicker.saveFile`).
- **Voice playback**: tap plays, tap again pauses, tap again resumes from the
  same position; the bubble icon switches to pause while playing.
- **Notifications**: the main app notifications list/badge now EXCLUDES
  `commercial_debt`; debt/chat/settlement notifications live only in the
  isolated center (three tabs) and deep-link to their detail.

Backend 77/77; Flutter 37/37; analyze 0 errors.

## Round 12 — confirmed debt invoice edit & permanent deletion

Backend `debt_invoice_service.py` (merchant-only, transactional):
- **Adjust** (`PATCH /merchant-links/operation/{id}`): changes quantity/unit
  price, recomputes line + invoice totals (discount/tax preserved), adjusts
  stock and FIFO/FEFO lots by the delta, updates the receivable/payable,
  recalculates balance/status, records `invoice_item_changes` (before→after),
  writes an inventory adjustment movement, and notifies the linked party.
- **Delete** (`DELETE /merchant-links/operation/{id}`): restores sale stock and
  lots, refuses purchase deletion if any of its lots were consumed, removes the
  invoice's inventory movements, reverses every payment on the invoice against
  its bank account (compensating `bank_transactions`), deletes the
  receivable/payable, soft-deletes the invoice (`cancelled`), and notifies the
  linked party with the invoice number/amount.
- Permissions are kind-aware (customers/suppliers update). The response includes
  `linked` so the UI warns about notifying the other party.

Flutter:
- Business invoice detail shows a pencil + red trash opposite the
  modified/settled badges. The pencil opens a sheet to edit quantity/price per
  line with a live total; the trash asks for confirmation (different text when
  the party is linked) and pops back after deletion.
- The Business individual/section pages reload after returning from an invoice,
  so edited/deleted rows disappear/refresh immediately.
- Personal stays read-only.

Runtime test `test_debt_invoice_edit_runtime.py` (14/14) proves totals,
receivable, stock, bank reversal, payment removal, soft-delete, and movement
cleanup. All backend suites 77/77; Flutter 37/37; analyze 0.

## Round 11 — debt currency labels, business settlement, section picker

- Hero total card: the display currency and the paid/remaining suffixes now use
  the localized currency name (AR: ريال يمني قديم, EN: YER_OLD) in a small
  font; the big amount was reduced (34→24) and the breakdown values (15→12.5).
- Section-name placeholder is now «مثال: دين شهر 1 أو دين سبتمبر أو أي مسمى
  آخر...» with a 10.5px hint and hintMaxLines=2 (never clipped).
- Business invoice detail (merchant only): green «تحصيل من العميل» /
  «تسديد للمورد» + «عرض الفاتورة» on one row, «المدفوعات» centered below;
  settled invoices show a green «مسدد بالكامل» chip. The personal side keeps
  the read-only payments + original-invoice buttons.
- Settlement is scoped: `PartyPaymentRequest` now accepts `invoice_id` and
  `debt_group_id`; `_settle_party` filters the open rows accordingly, so an
  invoice payment only touches that invoice and a section payment only that
  section (same currency).
- Section page: a green collect/pay button (or «مسدد بالكامل» when zero) applies
  a section-scoped payment in the section's display currency.
- Invoice rows show a green check when fully settled.
- Add-invoice flow: a «قسم الدين» selector appears only for partial/credit
  (individual or one of the merchant's real sections) and stores
  `debt_group_id` on the invoice.
- Payment notifications now say «تم سداد الدين بالكامل» or «سداد جزئي: X —
  المتبقي Y» using the real post-payment balance.

Deferred (explicitly): editing quantity/price and permanent deletion of
CONFIRMED invoices with full stock/bank/receivable reversal. That is a
destructive accounting operation; it needs its own dedicated, heavily tested
release to avoid corrupting balances. The merchant-side UI for it is not
shipped yet.

Tests: backend 63/63; Flutter 37/37; analyze 0 errors.

## Round 10 — chat direction/media/files/recording + requests row

- Direction flipped: MY messages are on the RIGHT (red), the other side on the
  LEFT (surface/grey), in RTL and LTR (side-based `mine`).
- Media is optimistic: the sender sees the image/video/file bubble immediately
  with a circular upload progress + percentage (Dio `onSendProgress`); at 100%
  it is sent (same `client_id` for idempotency) and the pending bubble is
  replaced by the server message. Tapping an image opens a full-screen
  zoomable viewer.
- Attach menu: Camera, Gallery (images AND videos via `FilePicker.media`),
  Files (PDF/Word/Excel/text/CSV/ODT/ODS/PPT), Invoice. Documents are accepted
  by the backend (`kind=file`, `file_name`) and open via `open_filex`.
- Merchant/shop name: the raw «X's Organization» / «Organization» label is
  stripped; the owner name is used when needed (chat header + invoice header).
- Recording: a slim bar is ADDED above the composer (the attach/composer stay);
  it shows a live amplitude waveform, elapsed seconds, cancel, pause/resume and
  send. Nothing is sent on cancel.
- Personal merchant list: «طلبات التجار» now sits on the SAME row as «تجاري»
  (title right, requests button far left), with the count badge.

Tests: backend 63/63; Flutter 37/37; analyze 0 errors.

## Round 9 — business party redesign + section-linked debts

- Party identity card: linked user's PHOTO (when present) in a circular
  avatar, full name, pencil-only edit at the edge, added date and exactly ONE
  contact — phone when the merchant has it (even if linked by code), else the
  public code, else the linked phone. The duplicated code under the name is
  gone.
- The whole lower stack (per-currency, pay, groups/individual/requests/recent,
  add) was replaced by TWO buttons: «ديون منفردة» + «مجموعات الديون».
- New Business pages copy the Personal design 100% (shared `DebtPeriodFilter`
  + `DebtTotalHeroCard` + `DebtOperationTile` + `DebtGroupTile`):
  `party_debts_page` (individual), `party_sections_page` (grid + add section),
  `party_section_page` (one section + add debt). Empty sections show a small
  centered «إضافة قسم جديد»; the add dialog uses the example placeholder.
- Add-debt from a section prefills the party AND the section
  (`/sales/add?customer=..&group=..&debt=1` / purchases), and the payment sheet
  is restricted to «جزئي / آجل» (full is hidden). `debt_group_id` was added to
  the sale/purchase issue models and stored on the invoice.
- Backend `businessOverview` accepts `group_id`, `date_from`, `date_to`,
  `currency`; `merchant_link_status` returns the linked user's `avatar` and
  `linked_via`.
- New-debt notifications keep using the isolated `commercial_debt` domain and
  deep-link to the operation.

Tests: backend 63/63; Flutter 42/42 (incl. new party pages 3/3, party detail,
merchant requests, tracking, chat); analyze 0 errors.

Resolved in Round 9b: tapping an invoice in the Business individual/section
pages now opens the SAME operation-detail page as Personal (badge, summary,
products table, payments, «عرض الفاتورة الأصلية») via a business-safe
`/merchant-links/operation` endpoint; the original-invoice button opens the
merchant's own A4 view. The detail body is shared (`operation_detail_for_party`)
so both sides stay identical.

## Round 8 — merchant requests + single-field tracking

- Personal merchant list: a compact «طلبات التجار» button under the search with
  a count badge (red when >0, grey 0). It opens a sheet listing ONLY real
  invite data (shop/merchant name, merchant number = public code or phone,
  avatar, customer/supplier kind) with green «موافقة» / red «إلغاء».
  Approve opens a final confirmation explaining the link and showing the real
  merchant data; confirm → accept → «تم الربط بنجاح», the request disappears
  and the badge updates. No invented fields. Backend `user_invites` now returns
  `shop_name`, `merchant_phone`, `merchant_code`, `merchant_avatar`,
  `created_at`.
- Business «add tracking» dialog: ONE field with the party-specific hint
  («رقم الجوال أو الرقم المميز للعميل/للمورد») and title («أضف عميلك ليتتبع
  ديونه بشكل مباشر» / «أضف المورد ليتتبع الديون بشكل مباشر»). An unknown
  number now shows «لا يوجد مستخدم بهذا الرقم» INLINE while the dialog/field
  stay open (previously it closed the dialog). Client detects a 6-digit code
  vs a phone for the lookup.

Tests: Flutter merchant-requests 2/2 + tracking inline-error 1/1 + all debt/
chat suites 34/34; backend 63/63; analyze 0 errors.

## Round 7 — chat pro features + scoped notifications

Chat:
- **Side-based direction**: messages store `sender_side` (merchant/personal) and
  the API takes `side`, so the same account can be both sides — a Personal
  message is right/red in Personal and left/grey in Business. Backfilled old
  rows; tested with a same-user link.
- **Media + caption in ONE message**: image/video/camera open a preview dialog
  with an optional caption before upload; the caption is stored in `text` and
  shown inside the media bubble.
- **Video** support (pick + preview + in-app player with auth headers).
- **Voice**: live duration, pause/resume (elapsed excludes pauses), cancel
  (file deleted, nothing sent), send.
- **Edit/delete (30 min, server-enforced)**: `PATCH/DELETE
  /chat/{link}/messages/{id}`; sender only; server clock; after the window the
  API rejects. Edits set `edited_at` (badge «معدّلة», original time kept).
  Delete-for-everyone sets `deleted_at` and hides content for both sides.
  Long-press menu: copy / edit / delete (permissions + window).
- Polling (2s) makes edits/deletes appear live on both sides.
- Light micro-interactions: new-message fade/slide (only the newest bubble),
  animated send/mic switch, animated presence dot.

Notifications:
- Every message pushes the recipient (never the sender) with the sender name,
  a short preview and the attachment type; deep link opens the chat at the
  message. Deduped by `chat:{message_id}`.
- **Per-party isolation**: `GET /debt-notifications?link_id=` filters by the
  notification payload `link_id` (all debt/chat/settlement emissions now carry
  it). The party detail / merchant detail bells open the scoped page.
- **Three tabs** (الديون / الرسائل / السداد) with icons and a red pill
  indicator; tapping opens the related invoice/operation or chat message.
  Settlement messages state the amount/currency and now «مكتمل السداد» or
  «سداد جزئي، المتبقي …» computed from the real open balance.

Tests: backend 63/63 (chat 14, edit/delete/direction 8, merchant 20, debt 21);
Flutter 38/38; analyze 0 errors. Verified per-link notification filtering live
(3 categories, no cross-link leak).

## Round 6 — invoice detail polish + chat fixes

- Invoice detail summary card now shows ONLY the 3 financial figures
  (total / paid / remaining); the invoice number was removed (it is already the
  page title) so the card no longer crowds/clips.
- Bottom actions are equal-width, 48px tall, 11.5px labels, with safe-area
  bottom padding — «المدفوعات» and «عرض الفاتورة الأصلية» both show fully.
- The original A4 page gained a bottom bar: «حفظ PDF» (save) and «مشاركة»
  (share) built from the same design + document via `buildInvoicePdf`.
- **Chat name/avatar + the mid-chat error had ONE root cause**: the client
  parsed `GET /chat/{id}/messages` as a bare list, but the API returns
  `{messages: [...]}` → a cast exception aborted `_load`, so `_info` stayed
  empty («…», no avatar) and the page showed the generic error. Fixed the
  parser (handles both shapes). The API itself was 200 all along (verified in
  the server log).
- Presence is now app-wide and truthful: `POST /chat/presence` heartbeat every
  25s while the app is open (stopped on background), online window 45s → green
  when in the app, red when not.

## Round 5 — sections + merchant↔party chat

Sections:
- Invoice-count wording (فاتورة واحدة / فاتورتان / N فواتير / N فاتورة).
- Section page now uses the SAME shared `DebtPeriodFilter` + `DebtTotalHeroCard`
  (banks-size card with paid green / remaining red) as the individual tab, and
  lists the section's invoices directly (newest→oldest). The «عرض تفصيل
  الديون» breakdown was removed. Opening an invoice uses the same detail page.

Chat (isolated per accepted `MerchantLink`):
- Backend `chat_messages` + `chat_presence`; service `chat_service.py`;
  router `chat.py` (`/chat/{link_id}`, `/messages`, `/read`, `/invoices`,
  `/media`). Only `external_user_id` and `invited_by` of an ACCEPTED link may
  read/write — no chat for unlinked parties.
- Text / image / voice / invoice messages; `client_id` idempotency; delivery
  (`delivered_at`) and read (`read_at`) receipts; presence = seen within 45s.
- Push only when the recipient is offline; route deep-links straight to the
  conversation+message (`/personal/chat` or `/debts/chat`). In-app rows use the
  isolated debt-notification center.
- Flutter `ChatPage`: header with avatar/shop name + green/red presence dot,
  bubbles (mine/theirs), ✔️ / ✔️✔️ black / ✔️✔️ blue receipts, image + camera,
  voice record/play, invoice picker with search, invoice bubble opens the real
  invoice, 2s polling for near-instant delivery (no WebSocket dependency),
  highlight of the deep-linked message.
- Chat button appears only for linked relationships: personal merchant
  overview + section app bars, and the business party detail app bar when
  `link.status == accepted`.

Tests: backend chat runtime 14/14; Flutter chat page 1/1 + debt suites 17/17;
analyze 0 errors.

## Round 4 — Personal «حساباتي مع التجار» polish

- **Tabs** (الديون الفردية / الأقسام) now sit in a rounded segmented container
  with a filled red pill indicator; explicit light/dark colours, no clipping.
- **Report filters** before the total card: الكل / اليوم / هذا الشهر /
  بين فترتين (date-range picker). Backend `debt-overview` accepts
  `date_from`/`date_to` and filters by `invoice_date`.
- **Total card** = banks «إجمالي الأرصدة» size/style, now with an inline
  breakdown: المدفوع (green) and المتبقي (red). Backend returns
  `grand_total`, `paid_total`, `remaining_total` (each converted with the
  approved FX engine; honest `fx_missing` gap, never a fake number).
- Individual tab: per-currency boxes and settlement requests removed; the
  debt records (all invoices, newest→oldest) appear directly under the card.
- **Invoice detail**: modified/not-modified badge; summary rectangle
  (invoice no, total, paid, remaining); a real **products table** (image,
  name, qty, unit price, line total) rendered with a lazy `SliverList` (safe
  for thousands of rows) and RTL→LTR automatically; bottom actions are
  «المدفوعات» + «عرض الفاتورة الأصلية» (compact). Settlement/pay buttons were
  removed from the personal side — the linked party is monitor-only.
- **Payments sheet**: numbered list in each payment's own currency, phrased
  «دفعت مبلغ …» for customers and «حصلت مبلغ …» for suppliers, with date.
- **Original A4 invoice**: renders the SAME `InvoicePreviewCard` the merchant
  sees, inside a zoom/pan `InteractiveViewer`. The merchant's paper design
  (colours, logo, signature, stamp, footer, shop name) is now **synced to the
  server** (`org_invoice_designs`, `PUT/GET /invoices/designs/{template}`) and
  served to the linked party. If the merchant never synced, the standard paper
  design is used with the real shop name/phone; the placeholder
  «Organization» is never shown.
- **Merchant edits** on invoice lines are recorded (`invoice_item_changes`)
  and shown to the linked party as «قبل → بعد» per product, with the badge
  turning orange (معدلة). The confirmed-invoice edit rule is unchanged
  (edits are tracked on draft updates before confirmation).

Tests: backend 41/41; Flutter 53/53 debt-focused; analyze 0 errors; build
exit 0. Honest limit: exact A4 artwork requires the merchant app to sync its
design (happens automatically on app start / save once updated).

## Round 3 — device feedback

- **Black screen on the business party detail**: the app's `ErrorWidget.builder`
  returned `ColoredBox(black)`, so ANY build exception became a blind black
  page. It now shows a calm, on-brand fallback with a short error code (the
  full detail is still logged) — no more black screens, and the cause is
  reportable. Also hardened: query-name decoding is now try/catch
  (`_dec`), and the per-currency boxes no longer do `MediaQuery` width math
  (Expanded rows + clamped widths) so a negative width can never assert.
  Widget tests (real theme + real backend payload + phone size) render the
  detail, the lists, and the home with zero exceptions — the remaining cause
  is route/runtime-only and will surface via the new visible error code.
- **Currency picker showed only the 4 defaults**: it called
  `loadEnabledCurrencies()` with no user id (→ 'global' key). It now uses the
  signed-in user's id (`currentUserIdProvider`) for both the picker and the
  default currency, so every currency the user enabled in preferences appears.
- **Total-debts card** is now the SAME size/shape as the banks
  «إجمالي الأرصدة» hero card (padding 24, gradient, decorative circles, 34px
  amount, currency chip).
- **Invoice document in Personal**: «عرض الفاتورة» now opens a dedicated,
  clean paper-invoice page (`/personal/debt-invoice`) rendered from the REAL
  operation data — merchant name/phone header, item table (name, qty+unit,
  price, line total), subtotal/discount/tax/total/paid/remaining, payments, and
  a standard signature/stamp line + system footer. The cluttered bottom sheet
  and the raw product dump are gone.
  Backend `partner_operation_detail` now returns `merchant` (org name + owner
  phone) and `subtotal` for the document header.
  Limitation: the merchant's per-device custom design (logo/signature/stamp
  images) is stored only in the merchant app's SharedPreferences and is NOT on
  the server, so exact per-merchant artwork cannot be reproduced yet — this
  renders the standard paper layout from real data (no invented values).

## Round 2 — errors1 screenshots + references

Root causes proven from the running service (not guessed):

1. **HTTP 500 on the personal merchant account** — the LIVE backend process
   started 21:46, BEFORE the source fix (22:44), so it still imported
   `CentralFXEngine` from `push_service` (`ImportError` → 500). The source was
   already correct; the process was stale. Restarted `fyona-backend.service`
   (new pid) → the endpoint returns 200. This also explains the party-detail
   `404` on `/merchant-links/overview` (route missing in the old process) which
   is why the identity card showed «—» and an empty card rendered.
2. **Debt-notification bell returned the user to the HOME screen** — the route
   `/debt-notifications` matched no allowed prefix in `isRouteAllowed`, so the
   router bounced to `/dashboard` (business) / `/personal` (personal). Fixed by
   giving each context a prefixed route — `/debts/notifications` (business) and
   `/personal/debt-notifications` (personal) — adding them (and the legacy
   path) to the allow-lists, and pointing each bell at its own center.
3. **Party name «—» / wrong identity** — stale backend (404) as above; also the
   detail page now receives the name the list already showed as a fallback and
   the link status payload now carries `phone` + `public_code` so the identity
   footer matches reference 3.
4. **Menu notification deep link** — a merchant-facing `settlement_request`
   notification was routed to the PERSONAL screen; it now opens the merchant's
   business party detail.
5. **Value from the API shown as a raw code (`YER_OLD`)** — amounts now use the
   localized currency name (AR) / ISO code (EN); the raw `*_OLD/_NEW` storage
   codes never reach the AR UI.
6. **Invoice numbers wrapped mid-number** — operation rows force LTR,
   single-line, ellipsis on the number and a separate currency column.
7. **Empty oversized card** on party detail — the redundant link card was
   removed; the page now follows reference 3 (identity card, «ديونه حسب العملة»,
   the three info rows مجموعات الديون/ديون منفردة/طلبات السداد, «آخر العمليات»,
   one bottom «إضافة دين جديد»).
8. **Duplicate add buttons** on the debt lists — the app-bar «+» is hidden in
   the debts context; the single reference action is the bottom button. Rows
   use the reference letter-avatar + person icon + name + chevron (no balance,
   no phone).
9. **Raw `DioException` shown to the user** — replaced with a friendly,
   localized retry (server/timeout/network/generic); the technical detail
   stays in logs. A widget test now asserts the raw text never renders.

## Defects found and fixed

Backend:
- Overview imported CentralFXEngine from the wrong module (push_service).
- Section response excluded grouped operations; UI then mistook failures for zero.
- Operation detail missed the InvoiceItem import and used a non-existent
  Payment.currency column (now payment_currency with invoice fallback).
- Notification duplicate handling called `rollback()` on the whole financial
  transaction (now a SAVEPOINT rollback of the notification insert only).
- Push was fired BEFORE the commit on every path. Now: emit inside the
  transaction (outbox), push only after commit — directly after explicit
  `commit()` in merchant routers, via BackgroundTasks after auto-commit in
  invoice/payment routers.
- Invite/reject notices used the general notification domain (invisible in the
  debt center, leaking into the main center). All debt/link events now use the
  `commercial_debt` domain with per-link deep-link routes.
- Debt-created push existed for sales only; purchases now notify the supplier.
- Merchant business endpoints had no (or kind-wrong) permission guards; they
  are now kind-aware (customers XOR suppliers, payments for proofs).
- Overview rewrote totals on CustomerReceivable/SupplierPayable (the same rows
  the settlement engine mutates): per-currency kept separate, converted total
  via CentralFXEngine `get_rate` metadata, honest `fx_missing` gap instead of a
  fake number, settled ops excluded, newest-first with stable tiebreak.
- Group rename/delete/assign endpoints added; delete only unassigns invoices
  (financial rows survive); personal request tracking endpoint added.

Flutter:
- Business tiles expanded vertically (now fixed-height reference cards).
- Customer/supplier debt lists leaked phones (now name-only in debt context).
- Party detail rebuilt: red identity card (name/edit/added-date/phone-XOR-code/
  link status), per-currency totals, sections with create/rename/delete,
  individual debts, pending proofs, recent ops, assign-to-section, settle +
  add-debt actions.
- Personal overview: currency picker from the user's ENABLED set, null-total
  FX-gap state (never "null 0"), error retry, per-currency panels, 2-column
  section grid (name + count only), own settlement requests with statuses,
  notification `op`/`req` deep-link auto-open.
- Section page uses the server-filtered operation list; operation detail shows
  real items/discount/tax/units/payments, an invoice sheet rendered from the
  same data (no business permission needed, no duplicate record), and a
  one-tap settlement-proof request (button disabled while sending).
- All chevrons are direction-aware (RTL/LTR); a widget test caught and fixed
  a real 11px RenderFlex overflow in the totals row.

## Verification (actually executed)

- Live endpoint probe with a real owner JWT: `/merchant-links/overview`
  returns `party.name = "يحيئ"` / `"محمد"` and the correct link status
  (both parties are genuinely not linked → «غير مرتبط» is correct data).
- Backend `test_merchant_links_runtime.py`: 20/20 (unchanged, still green).
- Backend `test_debt_rebuild_runtime.py` (new): 21/21 — overview separation,
  conversion-or-honest-gap, group lifecycle, contact shapes, stranger blocked
  (debts + requests), supplier side, request tracking, operation detail,
  exactly-once emit. Uses isolated tagged rows with scoped cleanup.
- Flutter: `debt_rebuild_pages_test.dart` 6/6 (totals, FX gap, retry, section
  isolation, operation detail, EN LTR + dark) + `debt_party_detail_test.dart`
  2/2 (real name + reference rows + no raw code, friendly error) +
  `route_guard_test.dart` (notification allow-list regression) + debts/merchant/
  routes suites — 16/16 in the debt-focused run.
- `flutter analyze`: 0 errors project-wide.

## Honest limits

- No Android device/emulator is attached to this server (`adb devices` empty),
  so on-device screenshots against the 7 PDFs were NOT taken. Layout parity
  was enforced by construction (measured tokens, widget smoke tests incl.
  overflow guards, AR/EN, light/dark, 360px width). Needs human screenshot
  comparison on a real device from the release APK.
- Push end-to-end timing/sound in foreground/background/killed states needs
  two physical devices; server-side ordering (emit-then-push-after-commit,
  dedup keys, per-recipient single row) is tested, airtime delivery is not.
- `partner_invoices` legacy tab (MerchantPartnerPage) is superseded by the
  overview tabs and left untouched outside debt scope.
