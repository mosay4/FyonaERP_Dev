# Information Clicker coverage (page → elements)

✔ covered · • dynamic label (covered at its call site or by a section row help) · ✘ missing

| Section | covered | missing | dynamic |
|---|---|---|---|
| Profile & settings | 206 | 0 | 45 |
| Business | 596 | 0 | 151 |
| Personal | 413 | 0 | 110 |
| Shared (both sections) | 87 | 0 | 28 |

## features/ai/presentation/pages/ai_suggestions_page.dart
```
  ✔ IconButton (line 126) → s.ai.generate  [key:aiGenerateTooltip]
  ✔ IconButton (line 131) → s.ai.markAll  [key:aiMarkAllTitle]
  ✔ IconButton (line 226) → s.ai.markOne  [icon:Icons.check_circle]
  ✔ IconButton (line 235) → c.icon.delete  [icon:TwoToneIcons.delete]
  • GestureDetector (line 318) — label comes from the caller / record data
```
## features/ai/presentation/widgets/sara_offline_notice.dart
```
  ✔ TextButton (line 102) → c.retry  [key:retry]
```
## features/ai/presentation/widgets/sara_premium.dart
```
  • GestureDetector (line 50) — label comes from the caller / record data
  ✔ IconButton (line 126) → s.sara.back  [text:رجوع]
  • SaraPremiumAvatar (line 132) — label comes from the caller / record data
  • GestureDetector (line 259) — label comes from the caller / record data
  • GestureDetector (line 333) — label comes from the caller / record data
```
## features/branches/presentation/pages/branch_inventory_picker_page.dart
```
  ✔ IconButton (line 294) → b.sale.scan  [key:purScanBarcode]
  ✔ TextButton.icon (line 348) → o.inv.categories  [key:invCategories]
  • ChoiceChip (line 446) — label comes from the caller / record data
  ✔ InkWell (line 469) → o.branches.pickerCategory  [key:branchProductCount]
  ✔ IconButton (line 625) → o.branches.pickerSelect  [key:inventoryOutOfStock]
  ✔ IconButton (line 646) → o.branches.qtyMinus  [key:inventoryDecreaseQuantity]
  ✔ IconButton (line 689) → o.branches.qtyPlus  [key:inventoryIncreaseQuantity]
  • DropdownMenuItem (line 727) — label comes from the caller / record data
  ✔ DropdownButtonFormField (line 700) → o.branches.unit  [key:branchUnit]
  ✔ FilledButton (line 855) → o.branches.applySelection  [key:inventoryApply]
```
## features/branches/presentation/pages/branch_invitations_page.dart
```
  ✔ TextButton (line 70) → o.branches.inviteReject  [key:branchInviteReject]
  ✔ FilledButton (line 75) → o.branches.inviteAccept  [key:branchInviteAccept]
  ✔ Tab (line 122) → o.branches.inviteIncoming  [key:branchInviteIncoming]
  ✔ Tab (line 123) → o.branches.inviteSent  [key:branchInviteSentList]
  ✔ FloatingActionButton.extended (line 127) → o.branches.inviteSend  [key:branchInviteSend]
  ✔ FilledButton (line 290) → o.branches.inviteAccept  [key:branchInviteAccept]
  ✔ OutlinedButton (line 303) → o.branches.inviteReject  [key:branchInviteReject]
  ✔ TextButton.icon (line 321) → o.branches.revoke  [key:branchMemberRevoke]
  • DropdownMenuItem (line 425) — label comes from the caller / record data
  ✔ DropdownButtonFormField (line 421) → o.branches.selectBranch  [key:branchSelectBranch]
  ✔ SwitchListTile (line 447) → o.branches.inviteTransferPerm  [key:branchInviteTransferPermission]
  ✔ FilledButton (line 457) → o.branches.inviteSend  [key:branchInviteSend]
```
## features/branches/presentation/pages/branch_members_page.dart
```
  ✔ IconButton (line 54) → o.branches.invitations  [key:branchInvitations]
  ✔ FloatingActionButton.extended (line 61) → o.branches.inviteSend  [key:branchInviteSend]
  ✔ TextButton.icon (line 209) → o.branches.memberBranches  [key:branchMemberBranches]
  ✔ SwitchListTile (line 222) → o.branches.inviteTransferPerm  [key:branchMemberTransfer]
  ✔ SwitchListTile (line 232) → o.branches.memberAll  [key:branchMemberAllBranches]
  ✔ TextButton.icon (line 244) → o.branches.revoke  [key:branchMemberRevoke]
  ✔ TextButton.icon (line 257) → o.branches.memberReactivate  [text:طلب إعادة تفعيل العضوية]
  • CheckboxListTile (line 286) — label comes from the caller / record data
  ✔ TextButton (line 307) → o.branches.cancel  [key:branchCancel]
  ✔ FilledButton (line 312) → o.branches.save  [key:branchSave]
  ✔ TextButton (line 366) → o.branches.cancel  [key:branchCancel]
  ✔ FilledButton (line 371) → o.branches.revoke  [key:branchMemberRevoke]
```
## features/branches/presentation/pages/branch_transfers_page.dart
```
  ✔ FloatingActionButton.extended (line 118) → o.branches.transferNew  [key:branchTransferFromTo]
  • ChoiceChip (line 196) — label comes from the caller / record data
  ✔ FilledButton (line 258) → o.branches.retry  [key:branchRetry]
  ✔ InkWell (line 313) → o.branches.transferRow  [key:branchStatusReversed]
  ✔ ListTile (line 482) → o.branches.financial  [key:branchFinancial]
  ✔ ListTile (line 503) → o.branches.inventory  [key:branchInventory]
  • BackButton (line 894) — label comes from the caller / record data
  ✔ FilledButton (line 940) → o.branches.confirmTransfer  [key:branchConfirmTransfer]
  • InkWell (line 1048) — label comes from the caller / record data
  ✔ IconButton (line 1145) → c.icon.close  [icon:Icons.close_rounded]
  ✔ ListTile (line 1174) → s.sub.planCard  [icon:Icons.check_circle_rounded]
  ✔ _pickerField (line 1309) → o.branches.pickerField  [key:branchSenderBranch]
  ✔ _pickerField (line 1323) → o.branches.pickerField  [key:branchReceiverBranch]
  ✔ _pickerField (line 1354) → o.branches.pickerField  [key:branchSenderBranch]
  ✔ _pickerField (line 1362) → o.branches.pickerField  [key:branchSourceBank]
  ✔ _pickerField (line 1396) → o.branches.pickerField  [key:branchSelectCurrency]
  ✔ _pickerField (line 1439) → o.branches.pickerField  [key:branchReceiverBranch]
  ✔ _pickerField (line 1447) → o.branches.pickerField  [key:branchReceiverBank]
  ✔ _pickerField (line 1481) → o.branches.pickerField  [key:branchSelectCurrency]
  ✔ OutlinedButton.icon (line 1682) → o.branches.chooseProducts  [key:inventoryChooseProducts]
  ✔ IconButton (line 1813) → c.icon.close  [icon:Icons.close_rounded]
  ✔ TextButton (line 2218) → o.branches.cancel  [key:branchCancel]
  ✔ FilledButton (line 2225) → o.branches.unitFactorSave  [key:branchUnitConversionSave]
  ✔ TextButton (line 2316) → o.branches.cancel  [key:branchCancel]
  ✔ FilledButton (line 2323) → o.branches.createMissing  [key:inventoryCreateConfirm]
  ✔ TextButton (line 2381) → b.pay.negAlways  [key:payNegAlways]
  ✔ TextButton (line 2388) → b.pay.negOnce  [key:payNegOnce]
  ✔ FilledButton (line 2395) → b.pay.negCancel  [key:payNegCancel]
  ✔ TextButton (line 2470) → o.branches.cancel  [key:branchCancel]
  ✔ FilledButton (line 2477) → o.branches.confirmTransfer  [key:branchConfirmTransfer]
  ✔ FilledButton.icon (line 2746) → o.branches.reverseAction  [key:branchReverseAction]
  ✔ TextButton (line 3210) → o.branches.cancel  [key:branchCancel]
  ✔ FilledButton (line 3217) → o.branches.reverseAction  [key:branchReverse]
```
## features/branches/presentation/pages/branches_page.dart
```
  ✔ FloatingActionButton.extended (line 62) → o.branches.new  [key:branchNew]
  ✔ InkWell (line 131) → o.branches.transferCard  [key:branchTransferAction]
  ✔ PopupMenuItem (line 394) → o.branches.reactivate  [key:branchReactivate]
  ✔ PopupMenuItem (line 401) → o.branches.edit  [key:branchEdit]
  ✔ PopupMenuItem (line 408) → o.branches.reset  [key:branchReset]
  ✔ PopupMenuItem (line 415) → o.branches.delete  [key:branchDeletePermanent]
  ✔ PopupMenuButton (line 385) → c.icon.more  [icon:Icons.more_vert]
  ✔ PopupMenuItem (line 439) → o.branches.edit  [key:branchEdit]
  ✔ PopupMenuItem (line 447) → o.branches.archive  [key:branchArchive]
  ✔ PopupMenuItem (line 454) → o.branches.reset  [key:branchReset]
  ✔ PopupMenuItem (line 462) → o.branches.delete  [key:branchDeletePermanent]
  ✔ PopupMenuButton (line 430) → c.icon.more  [icon:Icons.more_vert]
  ✔ TextButton (line 600) → o.branches.cancel  [key:branchCancel]
  ✔ FilledButton (line 607) → o.branches.archive  [key:branchArchive]
  ✔ TextButton (line 665) → o.branches.cancel  [key:branchCancel]
  ✔ FilledButton (line 672) → o.branches.reset  [key:branchReset]
  ✔ TextButton (line 756) → o.branches.cancel  [key:branchCancel]
  ✔ FilledButton (line 763) → o.branches.delete  [key:branchDeletePermanent]
  ✔ GestureDetector (line 907) → o.branches.photo  [icon:Icons.add_a_photo_rounded]
  ✔ TextButton.icon (line 939) → o.branches.photo  [key:branchPickImage]
  ✔ TextButton (line 969) → o.branches.cancel  [key:branchCancel]
  ✔ FilledButton (line 976) → o.branches.save  [key:branchSave]
```
## features/business_banks/presentation/pages/business_account_detail_page.dart
```
  ✔ IconButton (line 272) → c.icon.back  [icon:Icons.arrow_back_ios_new]
  ✔ TextButton.icon (line 303) → c.icon.refresh  [icon:Icons.refresh_rounded]
  • _chip (line 420) — label comes from the caller / record data
  • GestureDetector (line 440) — label comes from the caller / record data
  ✔ _dateChip (line 482) → p.account.from  [key:statementPeriodFrom]
  ✔ _dateChip (line 490) → p.account.to  [key:statementPeriodTo]
  ✔ IconButton (line 497) → c.icon.close  [icon:Icons.close]
  • GestureDetector (line 546) — label comes from the caller / record data
  • GestureDetector (line 599) — label comes from the caller / record data
```
## features/business_banks/presentation/pages/business_bank_detail_page.dart
```
  ✔ TextButton (line 64) → p.savings.cancelNew  [key:cancel]
  ✔ FilledButton (line 68) → b.banks.unlink  [key:bankLinkUnlink]
  ✔ IconButton (line 321) → b.banks.unlink  [key:bankLinkUnlink]
```
## features/business_banks/presentation/pages/business_banks_page.dart
```
  ✔ TextButton.icon (line 648) → b.banks.retry  [key:txOperationFailed]
  ✔ ElevatedButton.icon (line 772) → c.close  [key:close]
  ✔ ElevatedButton.icon (line 822) → c.close  [key:close]
  ✔ OutlinedButton.icon (line 865) → b.banks.link  [key:bankLinkAction]
  • CheckboxListTile (line 936) — label comes from the caller / record data
  ✔ TextButton (line 972) → p.savings.cancelNew  [key:cancel]
  ✔ FilledButton (line 979) → b.banks.linkConfirm  [key:bankLinkConfirm]
  ✔ CurrencySelector (line 1084) → b.debts.currency  [key:currencyLabel]
  ✔ DropdownMenuItem (line 1115) → b.banks.accountType  [key:accountTypeChecking]
  ✔ DropdownMenuItem (line 1119) → b.banks.accountType  [key:accountTypeSavings]
  • DropdownButton (line 1105) — label comes from the caller / record data
  ✔ TextButton (line 1133) → p.savings.cancelNew  [key:cancel]
  ✔ ElevatedButton (line 1146) → b.banks.saveForm  [key:update]
  ✔ _InputField (line 1246) → c.amount  [key:amountLabel]
  ✔ ElevatedButton.icon (line 1261) → p.transfer.go  [key:transfer]
  ✔ GestureDetector (line 1426) → p.banks.pickerRow  [icon:Icons.chevron_left_rounded]
  ✔ GestureDetector (line 1558) → p.banks.pickerBack  [icon:Icons.arrow_forward_ios_rounded]
  ✔ InkWell (line 1596) → p.banks.pickerRow  [icon:Icons.chevron_left_rounded]
  ✔ InkWell (line 1681) → p.banks.pickerRow  [icon:Icons.account_balance_rounded]
  ✔ GestureDetector (line 1876) → p.home.currency  [icon:Icons.expand_more]
  • CurrencySelector (line 1974) — label comes from the caller / record data
  ✔ GestureDetector (line 2158) → c.icon.dropdown  [icon:TwoToneIcons.arrowDown]
  ✔ GestureDetector (line 2099) → b.banks.cash  [key:cashAccount]
  ✔ ElevatedButton.icon (line 2209) → b.banks.addCurrency  [key:addCurrency]
  ✔ OutlinedButton.icon (line 2239) → b.banks.deleteBank  [key:deleteBankCompletely]
  ✔ InkWell (line 2365) → p.banks.export  [icon:Icons.receipt_long]
  ✔ InkWell (line 2377) → c.icon.edit  [icon:TwoToneIcons.edit]
  ✔ InkWell (line 2389) → c.icon.delete  [icon:TwoToneIcons.delete]
```
## features/core_business/presentation/pages/business_debts_page.dart
```
  ✔ _box (line 51) → b.debts.suppliers  [key:bizDebtSuppliers]
  ✔ _box (line 61) → b.debts.customers  [key:bizDebtCustomers]
  ✔ InkWell (line 85) → c.icon.back  [icon:Icons.arrow_back]
  ✔ IconButton (line 169) → c.icon.notifications  [icon:Icons.notifications_outlined]
```
## features/core_business/presentation/pages/customers_page.dart
```
  ✔ TextButton (line 186) → p.savings.cancelNew  [key:cancel]
  ✔ FilledButton (line 193) → p.budget.saveDetail  [key:save]
  ✔ TextButton (line 326) → p.savings.cancelNew  [key:cancel]
  ✔ FilledButton (line 333) → b.debts.deleteConfirm  [key:debtPartyDeleteConfirm]
  ✔ IconButton (line 416) → b.debts.deleteMode  [key:debtPartyDeleteTooltip]
  ✔ IconButton (line 433) → c.icon.add  [icon:Icons.add]
  ✔ FilledButton.icon (line 527) → b.debts.addCustomer  [key:bizAddCustomerNew]
  ✔ InkWell (line 598) → s.sub.planCard  [icon:Icons.check_circle_rounded]
  ✔ IconButton (line 713) → b.debts.track  [key:merchantTrack]
  • GestureDetector (line 666) — customer row → b.debts.partyRow
```
## features/core_business/presentation/pages/party_debt_pages.dart
```
  • SimpleDialogOption (line 200) — label comes from the caller / record data
  • DebtPeriodFilter (line 394) — label comes from the caller / record data
  ✔ DebtOperationTile (line 459) → p.mdebt.row  [key:debtInvoiceWord]
  ✔ FilledButton.icon (line 471) → b.debts.addDebt  [key:bizAddDebt]
  ✔ TextButton (line 618) → p.savings.cancelNew  [key:cancel]
  ✔ FilledButton (line 625) → p.budget.saveDetail  [key:save]
  ✔ TextButton (line 719) → p.savings.cancelNew  [key:cancel]
  ✔ FilledButton (line 726) → p.budget.saveDetail  [key:save]
  ✔ IconButton (line 829) → b.debts.newSection  [key:debtAddGroup]
  ✔ FilledButton.icon (line 895) → b.debts.newSection  [key:debtAddGroupCta]
  • DebtGroupTile (line 934) — label comes from the caller / record data
  • DebtPeriodFilter (line 1192) — label comes from the caller / record data
  ✔ FilledButton.icon (line 1235) → p.mdebt.settled  [key:debtSettledFull]
  ✔ FilledButton.icon (line 1281) → b.debts.paySupplier  [key:debtPaySupplier]
  ✔ DebtOperationTile (line 1345) → p.mdebt.row  [key:debtInvoiceWord]
  ✔ FilledButton.icon (line 1357) → b.debts.addDebt  [key:bizAddDebt]
```
## features/core_business/presentation/pages/party_detail_page.dart
```
  ✔ TextButton (line 349) → p.savings.cancelNew  [key:cancel]
  ✔ FilledButton (line 356) → p.budget.saveDetail  [key:save]
  ✔ TextButton (line 395) → p.savings.cancelNew  [key:cancel]
  ✔ FilledButton (line 402) → p.budget.saveDetail  [key:save]
  ✔ TextButton (line 439) → p.savings.cancelNew  [key:cancel]
  ✔ FilledButton (line 446) → b.debts.deleteDebt  [key:debtDelete]
  ✔ SimpleDialogOption (line 479) → b.debts.noSection  [key:debtNoGroup]
  • SimpleDialogOption (line 487) — label comes from the caller / record data
  ✔ TextButton (line 572) → p.savings.cancelNew  [key:cancel]
  ✔ FilledButton (line 579) → p.budget.saveDetail  [key:save]
  ✔ TextButton (line 732) → p.savings.cancelNew  [key:cancel]
  ✔ FilledButton (line 739) → b.debts.reject  [key:merchantReject]
  ✔ TextButton (line 921) → p.savings.cancelNew  [key:cancel]
  ✔ FilledButton (line 930) → p.budget.saveDetail  [key:save]
  ✔ IconButton (line 894) → c.icon.edit  [icon:Icons.edit_outlined]
  ✔ FilledButton (line 957) → b.debts.paySupplier  [key:purSettle]
  ✔ TextButton (line 1022) → b.pay.negAlways  [key:payNegAlways]
  ✔ TextButton (line 1029) → b.pay.negOnce  [key:payNegOnce]
  ✔ FilledButton (line 1036) → b.pay.negCancel  [key:payNegCancel]
  ✔ FilledButton (line 1126) → b.sale.close  [key:saleClose]
  ✔ IconButton (line 1252) → b.debts.editParty  [key:debtEditParty]
  ✔ OutlinedButton.icon (line 1282) → b.debts.invite  [key:merchantInviteBtn]
  ✔ TextButton (line 1331) → b.debts.recordPayment  [key:debtRecordPayment]
  • InkWell (line 1451) — label comes from the caller / record data
  ✔ IconButton (line 1523) → b.debts.rename  [key:debtRename]
  ✔ IconButton (line 1530) → b.debts.deleteDebt  [key:debtDelete]
  ✔ TextButton (line 1592) → b.debts.reject  [key:merchantReject]
  ✔ FilledButton (line 1601) → p.merchants.approve  [key:merchantApprove]
  • ChatUnreadIcon (line 1689) — label comes from the caller / record data
  ✔ IconButton (line 1699) → c.icon.notifications  [icon:Icons.notifications_outlined]
  • InkWell (line 1771) — operations button: label comes from a variable (partyOps*Btn keys are covered)
  • InkWell (line 1824) — label comes from the caller / record data
  ✔ TextButton.icon (line 1869) → b.debts.newSection  [key:debtAddGroup]
  ✔ IconButton (line 1889) → c.icon.edit  [icon:Icons.edit_outlined]
  ✔ IconButton (line 1894) → c.icon.delete  [icon:Icons.delete_outline]
  ✔ InkWell (line 2013) → p.chat.invoice  [icon:Icons.receipt_long_outlined]
  ✔ OutlinedButton.icon (line 2150) → b.debts.assignGroup  [key:debtAssignGroup]
```
## features/core_business/presentation/pages/party_operations_page.dart
```
  ✔ ListTile (line 248) → o.emp.salaryHistory  [icon:Icons.receipt_long_rounded]
  • ChoiceChip (line 435) — label comes from the caller / record data
  • InkWell (line 540) — operation row → b.debts.sectionRow
```
## features/core_business/presentation/pages/suppliers_page.dart
```
  ✔ TextButton (line 184) → p.savings.cancelNew  [key:cancel]
  ✔ FilledButton (line 191) → p.budget.saveDetail  [key:save]
  ✔ TextButton (line 324) → p.savings.cancelNew  [key:cancel]
  ✔ FilledButton (line 331) → b.debts.deleteConfirm  [key:debtPartyDeleteConfirm]
  ✔ IconButton (line 412) → b.debts.deleteMode  [key:debtPartyDeleteTooltip]
  ✔ IconButton (line 429) → c.icon.add  [icon:Icons.add]
  ✔ FilledButton.icon (line 528) → b.debts.addSupplier  [key:bizAddSupplierNew]
  ✔ InkWell (line 600) → s.sub.planCard  [icon:Icons.check_circle_rounded]
  ✔ IconButton (line 718) → b.debts.track  [key:merchantTrack]
  • GestureDetector (line 668) — supplier row → b.debts.partyRow
```
## features/core_business/presentation/widgets/add_party_debt_sheet.dart
```
  ✔ IconButton (line 118) → c.icon.close  [icon:Icons.close_rounded]
  ✔ InkWell (line 177) → b.debts.currency  [key:currencyLabel]
  ✔ FilledButton (line 249) → p.budget.saveDetail  [key:save]
```
## features/core_business/presentation/widgets/debt_section_picker.dart
```
  ✔ IconButton (line 147) → c.icon.close  [icon:Icons.close_rounded]
  ✔ _tile (line 160) → p.chat.invoice  [icon:Icons.receipt_long_outlined]
  • _tile (line 203) — debt group row (user group name) → b.debts.sectionRow
  ✔ InkWell (line 238) → s.ai.markOne  [icon:Icons.check_circle]
  ✔ InkWell (line 311) → b.debts.sectionPicker  [key:debtSectionLabel]
```
## features/core_business/presentation/widgets/debt_settlement.dart
```
  ✔ IconButton (line 342) → c.icon.close  [icon:Icons.close_rounded]
  ✔ FilledButton (line 537) → b.debts.paySupplier  [key:purSettle]
  ✔ InkWell (line 602) → o.emp.pickBank  [icon:Icons.account_balance_outlined]
  ✔ InkWell (line 662) → b.debts.available  [key:debtAvailableShort]
```
## features/core_business/presentation/widgets/debt_widgets.dart
```
  ✔ InkWell (line 215) → p.merchants.card  [icon:Icons.storefront_outlined]
  ✔ InkWell (line 242) → p.chat.invoice  [icon:Icons.receipt_long_outlined]
  ✔ InkWell (line 314) → c.icon.edit  [icon:Icons.edit_outlined]
  • InkWell (line 309) — debt group tile (user group name) → b.debts.sectionRow
  ✔ IconButton (line 335) → c.icon.refresh  [icon:Icons.refresh]
  • InkWell (line 394) — label comes from the caller / record data
  ✔ GestureDetector (line 532) → p.home.currency  [icon:Icons.expand_more]
```
## features/core_business/presentation/widgets/invoice_line_widgets.dart
```
  ✔ IconButton (line 59) → c.icon.add  [icon:Icons.add]
  ✔ IconButton (line 88) → p.tree.zoomOut  [icon:Icons.remove]
  • InkWell (line 262) — label comes from the caller / record data
```
## features/core_business/presentation/widgets/party_tracking.dart
```
  ✔ IconButton (line 302) → c.icon.close  [icon:Icons.close_rounded]
  • ListTile (line 326) — label comes from the caller / record data
  ✔ IconButton (line 415) → c.icon.close  [icon:Icons.close_rounded]
  ✔ ButtonSegment (line 428) → b.track.publicCode  [text:الرقم المميز]
  ✔ ButtonSegment (line 435) → b.track.phone  [text:رقم الهاتف]
  ✔ OutlinedButton (line 463) → s.drawer.branchSwitch  [icon:Icons.keyboard_arrow_down_rounded]
  ✔ FilledButton (line 566) → b.track.search  [text:بحث]
  ✔ TextButton (line 599) → b.track.searchAgain  [text:لا، أبحث مرة ثانية]
```
## features/dashboard/presentation/pages/business_income_expense_page.dart
```
  ✔ ElevatedButton (line 415) → b.tx.retry  [key:txRetry]
  • _MovementTile (line 448) — label comes from the caller / record data
  • GestureDetector (line 466) — label comes from the caller / record data
  • GestureDetector (line 498) — label comes from the caller / record data
  • GestureDetector (line 533) — label comes from the caller / record data
  • GestureDetector (line 638) — label comes from the caller / record data
```
## features/dashboard/presentation/pages/business_setup_page.dart
```
  ✔ OutlinedButton (line 176) → p.tree.back  [key:back]
  ✔ FilledButton (line 195) → b.setup.create  [key:bizSetupCreate]
  • Switch.adaptive (line 266) — label comes from the caller / record data
  • ChoiceChip (line 287) — label comes from the caller / record data
  • ChoiceChip (line 310) — label comes from the caller / record data
```
## features/dashboard/presentation/pages/business_transaction_details_page.dart
```
  ✔ ElevatedButton.icon (line 376) → b.tx.viewInvoice  [key:viewInvoice]
  ✔ OutlinedButton.icon (line 429) → b.tx.reconDetails  [key:reconDetailsTitle]
```
## features/dashboard/presentation/pages/business_transactions_page.dart
```
  ✔ ElevatedButton (line 410) → b.tx.retry  [key:txRetry]
  • _TxTile (line 446) — label comes from the caller / record data
  • GestureDetector (line 477) — label comes from the caller / record data
  • GestureDetector (line 551) — transaction row → b.tx.row
```
## features/dashboard/presentation/pages/widgets/business_add_movement_sheet.dart
```
  ✔ IconButton (line 453) → c.icon.close  [icon:TwoToneIcons.close]
  ✔ _ActionChip (line 515) → p.tx.methodCash  [key:payMethodCash]
  ✔ _ActionChip (line 529) → p.tx.methodBank  [key:payMethodBank]
  ✔ GestureDetector (line 543) → p.tx.pickAccount  [key:selectAccountFirst]
  ✔ InkWell (line 654) → c.currenciesCount  [key:personalCurrenciesCount]
  ✔ GestureDetector (line 763) → b.debts.currency  [key:currencyLabel]
  ✔ ListTile (line 860) → b.move.pickRow  [icon:TwoToneIcons.check]
  ✔ GestureDetector (line 963) → b.debts.currency  [key:currencyLabel]
  ✔ ListTile (line 1032) → b.move.pickRow  [icon:TwoToneIcons.check]
  • GestureDetector (line 1128) — label comes from the caller / record data
  ✔ ElevatedButton (line 1216) → b.move.save  [key:addIncome]
  • GestureDetector (line 1263) — label comes from the caller / record data
```
## features/dashboard/presentation/pages/widgets/business_bottom_nav.dart
```
  ✔ TextButton (line 118) → p.savings.cancelNew  [key:cancel]
  ✔ TextButton (line 125) → b.nav.unsavedExit  [key:invExitWithoutSave]
  ✔ FilledButton (line 132) → b.nav.saveExit  [key:invSaveAndExit]
  • LiquidGlassNavBar (line 192) — label comes from the caller / record data
```
## features/dashboard/presentation/pages/widgets/business_recent_ops.dart
```
  ✔ GestureDetector (line 54) → b.home.recentViewAll  [key:viewAll]
  • _RecentTxTile (line 72) — label comes from the caller / record data
  • GestureDetector (line 125) — label comes from the caller / record data
```
## features/dashboard/presentation/pages/widgets/business_services_grid.dart
```
  ✔ FilledButton (line 445) → b.home.readOnlyOk  [key:branchReadOnlyDialogOk]
  • GestureDetector (line 465) — label comes from the caller / record data
```
## features/email/presentation/pages/email_compose_page.dart
```
  ✔ TextButton (line 94) → s.settings.emailSend  [key:adminSend]
  ✔ ElevatedButton.icon (line 138) → s.settings.emailSend  [key:adminSend]
```
## features/email/presentation/pages/email_logs_page.dart
```
  ✔ IconButton (line 34) → c.icon.refresh  [icon:TwoToneIcons.refresh]
```
## features/email/presentation/pages/email_settings_page.dart
```
  ✔ DropdownMenuItem (line 169) → s.settings.emailEncryption  [text:SSL]
  ✔ DropdownMenuItem (line 170) → s.settings.emailEncryption  [text:TLS]
  ✔ DropdownMenuItem (line 171) → s.settings.emailEncryption  [key:emailWithoutEncryption]
  ✔ DropdownButtonFormField (line 163) → s.settings.emailEncryption  [key:emailEncryption]
  ✔ IconButton (line 188) → c.icon.visibility  [icon:Icons.visibility_off]
  ✔ ElevatedButton (line 231) → s.settings.saveSettings  [key:adminSaveSettings]
  ✔ OutlinedButton (line 246) → s.settings.emailTest  [key:emailConnectionTest]
```
## features/employees/presentation/pages/employee_custom_permissions_page.dart
```
  ✔ TextButton (line 45) → s.backup.cancel  [text:إلغاء]
  ✔ TextButton (line 49) → o.emp.leaveNoSave  [text:اطلع بدون حفظ]
  ✔ FilledButton (line 56) → o.emp.savePerms  [text:احفظ واطلع]
  ✔ IconButton (line 102) → c.icon.back  [icon:Icons.arrow_back_rounded]
  ✔ IconButton (line 110) → o.emp.savePerms  [text:حفظ الصلاحيات]
  • EmployeePermissionsEditor (line 130) — label comes from the caller / record data
  ✔ FilledButton.icon (line 140) → o.emp.savePerms  [text:حفظ الصلاحيات]
```
## features/employees/presentation/pages/employee_debts_page.dart
```
  • ChoiceChip (line 226) — label comes from the caller / record data
  ✔ ButtonSegment (line 292) → o.emp.createDebtSeg  [text:إنشاء دين]
  • ButtonSegment (line 300) — label comes from the caller / record data
  ✔ FilledButton.icon (line 343) → o.emp.newDebt  [text:إنشاء دين جديد]
  ✔ ActionChip (line 386) → o.emp.dateRange  [text:بين تاريخين]
  • OutlinedButton (line 426) — label comes from the caller / record data
  • ChoiceChip (line 464) — label comes from the caller / record data
  ✔ ListTile (line 476) → o.emp.forYou  [text:دين لك]
```
## features/employees/presentation/pages/employee_detail_page.dart
```
  ✔ TextButton (line 72) → s.backup.cancel  [text:إلغاء]
  ✔ FilledButton (line 76) → o.emp.deleteFinal  [text:حذف نهائي]
  ✔ IconButton (line 48) → o.emp.deleteForever  [text:حذف الموظف نهائياً]
  ✔ TextButton.icon (line 105) → o.emp.unlink  [text:إلغاء الربط]
  ✔ IconButton (line 124) → c.icon.edit  [icon:Icons.edit_rounded]
  ✔ OutlinedButton (line 261) → o.emp.link  [text:ربط الموظف]
  • InkWell (line 358) — label comes from the caller / record data
  ✔ TextButton (line 581) → s.backup.cancel  [text:إلغاء]
  ✔ FilledButton (line 585) → o.emp.payConfirm  [text:صرف]
  ✔ DropdownMenuItem (line 641) → o.emp.debtSide  [text:على الموظف]
  ✔ DropdownMenuItem (line 645) → o.emp.debtSide  [text:للموظف]
  • DropdownButtonFormField (line 638) — label comes from the caller / record data
  ✔ DropdownMenuItem (line 655) → o.emp.debtType  [text:دين جديد]
  ✔ DropdownMenuItem (line 656) → o.emp.debtType  [text:سداد]
  • DropdownButtonFormField (line 652) — label comes from the caller / record data
  ✔ TextButton (line 670) → s.backup.cancel  [text:إلغاء]
  ✔ FilledButton (line 674) → s.backup.rowSave  [text:حفظ]
```
## features/employees/presentation/pages/employee_form_page.dart
```
  ✔ ListTile (line 138) → s.sub.planCard  [icon:Icons.check_circle_rounded]
  ✔ IconButton.filled (line 261) → o.emp.photo  [icon:Icons.photo_camera_rounded]
  ✔ OutlinedButton.icon (line 287) → p.reports.currency  [icon:Icons.currency_exchange_rounded]
  • EmployeeLinkSettings (line 298) — label comes from the caller / record data
  ✔ FilledButton.icon (line 306) → o.emp.save  [text:حفظ الموظف]
```
## features/employees/presentation/pages/employee_link_page.dart
```
  • EmployeeLinkSettings (line 86) — label comes from the caller / record data
  ✔ FilledButton.icon (line 94) → o.emp.sendLink  [text:إرسال طلب الربط]
```
## features/employees/presentation/pages/employee_payment_page.dart
```
  ✔ FilledButton (line 258) → p.chat.videoRetry  [text:إعادة المحاولة]
  ✔ _selector (line 404) → o.emp.pickBank  [text:اختر البنك]
  ✔ _selector (line 411) → o.emp.pickCurrency  [text:اختر العملة]
  ✔ _selector (line 420) → o.emp.pickCurrency  [text:اختر عملة الكاش]
  • DropdownMenuItem (line 490) — label comes from the caller / record data
  ✔ DropdownButtonFormField (line 475) → o.emp.originalCurrency  [text:عملة الدين الأصلية]
  • FilledButton.icon (line 565) — submit label is a variable (صرف راتب / سداد…) → g.emp.paySubmit
  • InkWell (line 617) — label comes from the caller / record data
  ✔ InkWell (line 659) → c.icon.dropdown  [icon:TwoToneIcons.arrowDown]
  ✔ ListTile (line 721) → p.banks.pickerRow  [icon:Icons.account_balance_rounded]
  • ListTile (line 781) — label comes from the caller / record data
  • ListTile (line 836) — label comes from the caller / record data
```
## features/employees/presentation/pages/employee_salary_page.dart
```
  • ListTile (line 196) — label comes from the caller / record data
  ✔ ActionChip (line 352) → o.emp.dateRange  [text:بين تاريخين]
  • ChoiceChip (line 390) — label comes from the caller / record data
  ✔ FilledButton.icon (line 441) → o.emp.paySalary  [text:صرف راتب]
  ✔ InkWell (line 510) → o.emp.pickBankCur  [text:اختر الحساب البنكي والعملة]
  ✔ FilledButton.icon (line 570) → o.emp.paySalary  [text:صرف راتب]
  ✔ ListTile (line 601) → o.emp.salaryHistory  [icon:Icons.receipt_long_rounded]
```
## features/employees/presentation/pages/employees_page.dart
```
  ✔ IconButton (line 54) → o.emp.add  [text:إضافة موظف]
  ✔ FilledButton.icon (line 122) → o.emp.add  [text:إضافة موظف]
  ✔ OutlinedButton.icon (line 332) → o.emp.link  [text:ربط الموظف]
  ✔ InkWell (line 159) → o.emp.card  [text:متصل الآن]
```
## features/employees/presentation/pages/employer_workspace_page.dart
```
  ✔ OutlinedButton.icon (line 127) → o.emp.mySalary  [text:راتبي]
  ✔ OutlinedButton.icon (line 147) → o.emp.myDebts  [text:ديوني]
  ✔ FilledButton.icon (line 168) → o.emp.enterStore  [text:الدخول إلى المتجر]
  ✔ TextButton.icon (line 177) → o.emp.unlink  [text:إلغاء الربط]
```
## features/employees/presentation/pages/employment_invitation_page.dart
```
  ✔ TextButton (line 70) → s.sara.back  [text:رجوع]
  ✔ FilledButton (line 169) → o.emp.accept  [text:أوافق]
  ✔ FilledButton (line 182) → o.emp.decline  [text:لا أوافق]
```
## features/employees/presentation/pages/job_requests_page.dart
```
  ✔ ListTile (line 127) → o.emp.jobRequest  [text:مربوط]
```
## features/employees/presentation/widgets/employee_link_settings.dart
```
  ✔ TextButton (line 259) → o.emp.confirmNo  [text:لا، مو هو]
  ✔ FilledButton (line 263) → o.emp.confirmYes  [text:نعم، هذا هو]
  • ChoiceChip (line 305) — label comes from the caller / record data
  ✔ InkWell (line 431) → s.drawer.branchSwitch  [icon:Icons.keyboard_arrow_down_rounded]
  ✔ FilledButton.icon (line 484) → o.emp.findEmployee  [text:بحث عن الموظف]
  ✔ SwitchListTile.adaptive (line 570) → o.emp.fullPerms  [text:صلاحيات كاملة]
  ✔ OutlinedButton.icon (line 590) → o.emp.customPerms  [text:صلاحيات مخصصة]
  ✔ TextButton.icon (line 597) → o.emp.branchesRetry  [text:ما قدرنا نجيب الفروع، حاول مرة ثانية]
  ✔ CheckboxListTile.adaptive (line 625) → o.emp.branchTick  [icon:Icons.storefront_rounded]
```
## features/employees/presentation/widgets/employee_permissions_editor.dart
```
  • Switch (line 116) — label comes from the caller / record data
  • FilterChip (line 154) — label comes from the caller / record data
```
## features/employees/presentation/widgets/employee_unlink_action.dart
```
  ✔ TextButton (line 68) → s.sara.back  [text:رجوع]
  ✔ FilledButton (line 72) → o.emp.unlink  [text:إلغاء الربط]
```
## features/inventory/presentation/pages/categories_page.dart
```
  ✔ TextButton (line 81) → p.savings.cancelNew  [key:cancel]
  ✔ FilledButton (line 88) → p.budget.saveDetail  [key:save]
  ✔ IconButton (line 142) → o.inv.addCategory  [key:invAddCategory]
  ✔ InkWell (line 174) → o.inv.categoryTile  [key:invCatProductsCount]
  ✔ InventorySmallAction (line 277) → o.inv.addCategory  [key:invAddCategory]
```
## features/inventory/presentation/pages/category_detail_page.dart
```
  ✔ TextButton (line 279) → p.savings.cancelNew  [key:cancel]
  ✔ FilledButton (line 283) → p.budget.saveDetail  [key:save]
  ✔ ListTile (line 324) → o.inv.camera  [key:invFromCamera]
  ✔ ListTile (line 330) → o.inv.gallery  [key:invFromGallery]
  ✔ ListTile (line 337) → p.debts.delete  [key:delete]
  ✔ TextButton (line 401) → p.savings.cancelNew  [key:cancel]
  ✔ FilledButton (line 405) → p.debts.delete  [key:delete]
  • InventorySearchField (line 530) — label comes from the caller / record data
  ✔ TextButton (line 559) → p.savings.cancelNew  [key:cancel]
  ✔ IconButton.filledTonal (line 578) → o.inv.removeFromCategory  [key:invRemoveCount]
  ✔ InventorySmallAction (line 622) → o.inv.addToCategory  [key:invAddProductsToCategory]
  ✔ IconButton (line 689) → c.select  [key:invSelect]
  • InventoryProductTile (line 666) — label comes from the caller / record data
  ✔ _HeaderAction (line 716) → p.debts.edit  [key:edit]
  ✔ _HeaderAction (line 723) → o.inv.catImage  [key:invCatActionImage]
  ✔ _HeaderAction (line 730) → o.inv.falcon  [key:invCatActionFalcon]
  ✔ _HeaderAction (line 743) → p.debts.delete  [key:delete]
  • InkWell (line 846) — label comes from the caller / record data
```
## features/inventory/presentation/pages/falcon_page.dart
```
  ✔ IconButton (line 936) → p.tree.back  [key:back]
  • ChoiceChip (line 1004) — label comes from the caller / record data
  • InkWell (line 1647) — label comes from the caller / record data
  • _FlameChip (line 1792) — label comes from the caller / record data
  • GestureDetector (line 1848) — label comes from the caller / record data
  • InkWell (line 2216) — label comes from the caller / record data
```
## features/inventory/presentation/pages/inventory_home_page.dart
```
  ✔ ListTile (line 78) → o.inv.categories  [key:invCategories]
  ✔ ListTile (line 87) → o.inv.settings  [key:invSettingsTitle]
  ✔ TextButton (line 188) → p.savings.cancelNew  [key:cancel]
  ✔ FilledButton (line 195) → o.inv.addProduct  [key:invAddProduct]
  ✔ IconButton (line 241) → o.inv.falcon  [key:invFalcon]
  ✔ IconButton (line 255) → o.inv.addCategory  [key:invAddCategory]
  ✔ IconButton (line 266) → o.inv.settings  [key:invSettingsTitle]
  • InventorySearchField (line 280) — label comes from the caller / record data
  • InventoryProductTile (line 339) — label comes from the caller / record data
  ✔ InventoryPill (line 403) → o.inv.noCategory  [key:invNoCategory]
  ✔ InventoryPill (line 414) → o.inv.withCategory  [key:invWithCategory]
  ✔ InventorySmallAction (line 457) → o.inv.addCategory  [key:invCreateFirstCategory]
  ✔ TextButton.icon (line 464) → o.inv.retry  [key:falconRetry]
  ✔ TextButton (line 498) → p.savings.cancelNew  [key:cancel]
  ✔ FilledButton (line 505) → p.budget.saveDetail  [key:save]
  • InventoryCategoryTile (line 587) — label comes from the caller / record data
```
## features/inventory/presentation/pages/product_detail_page.dart
```
  ✔ IconButton (line 133) → o.inv.edit  [key:invEdit]
  ✔ TextButton (line 161) → p.savings.cancelNew  [key:cancel]
  ✔ FilledButton (line 165) → o.inv.deleteProduct  [key:invDeleteProduct]
  ✔ IconButton (line 148) → o.inv.deleteProduct  [key:invDeleteProduct]
  ✔ OutlinedButton.icon (line 268) → o.inv.batches  [key:invShowBatches]
  • OutlinedButton.icon (line 497) — label comes from the caller / record data
  ✔ GestureDetector (line 571) → s.drawer.branchSwitch  [icon:Icons.keyboard_arrow_down_rounded]
  ✔ FilledButton (line 621) → p.budget.saveDetail  [key:save]
  ✔ InkWell (line 902) → o.inv.unitImage  [icon:Icons.photo_camera_outlined]
  • ChoiceChip (line 1258) — label comes from the caller / record data
  ✔ FilledButton (line 1277) → o.inv.saveAdjust  [key:invSaveAdjust]
```
## features/inventory/presentation/pages/product_form_page.dart
```
  • DropdownMenuItem (line 91) — label comes from the caller / record data
  ✔ DropdownButtonFormField (line 84) → o.inv.measureGroup  [key:invMeasureGroup]
  ✔ TextButton (line 101) → p.savings.cancelNew  [key:cancel]
  ✔ FilledButton (line 105) → p.budget.saveDetail  [key:save]
  ✔ ListTile (line 290) → o.inv.camera  [key:invFromCamera]
  ✔ ListTile (line 299) → o.inv.gallery  [key:invFromGallery]
  ✔ ListTile (line 309) → o.inv.removeImage  [key:invRemoveImage]
  ✔ TextButton (line 541) → p.savings.cancelNew  [key:cancel]
  ✔ FilledButton (line 545) → o.inv.codeMove  [key:invCodeMove]
  ✔ TextButton.icon (line 611) → o.inv.addPrice  [key:invAddPrice]
  ✔ IconButton (line 641) → o.inv.removeFromCategory  [key:invRemoveFromCategory]
  ✔ ListTile (line 631) → b.sale.category  [key:invCategory]
  ✔ ListTile (line 656) → b.sale.expiry  [key:invProductExpiry]
  ✔ FilledButton (line 714) → p.budget.saveDetail  [key:save]
  ✔ GestureDetector (line 750) → o.inv.image  [key:invImageOptional]
  ✔ GestureDetector (line 783) → o.inv.baseUnit  [key:invBaseUnit]
  • GestureDetector (line 854) — label comes from the caller / record data
  ✔ IconButton (line 937) → c.icon.close  [icon:Icons.close]
  ✔ IconButton (line 987) → o.inv.scan  [icon:Icons.qr_code_scanner]
  ✔ GestureDetector (line 1052) → o.inv.unitType  [key:invUnitType]
  ✔ IconButton (line 1145) → o.inv.scan  [icon:Icons.qr_code_scanner]
  ✔ TextButton (line 1186) → p.savings.cancelNew  [key:cancel]
  ✔ FilledButton (line 1190) → p.budget.saveDetail  [key:save]
  ✔ TextButton.icon (line 1255) → o.inv.extraUnit  [key:invExtraUnit]
  ✔ IconButton (line 1276) → o.inv.deleteUnit  [key:invDeleteUnit]
  • DropdownMenuItem (line 1364) — label comes from the caller / record data
  ✔ DropdownButtonFormField (line 1360) → b.sale.currency  [key:invCurrency]
  ✔ TextButton (line 1381) → p.savings.cancelNew  [key:cancel]
  ✔ FilledButton (line 1385) → p.budget.saveDetail  [key:save]
  ✔ TextButton.icon (line 1431) → o.inv.addPrice  [key:invAddPrice]
  ✔ IconButton (line 1445) → c.icon.close  [icon:Icons.close]
```
## features/inventory/presentation/pages/product_movements_page.dart
```
  • ChoiceChip (line 80) — label comes from the caller / record data
  ✔ IconButton (line 202) → o.inv.falcon  [key:invFalcon]
  ✔ _rangeChip (line 260) → o.inv.filterAll  [key:invFilterAll]
  • _rangeChip (line 271) — label comes from the caller / record data
  ✔ _rangeChip (line 281) → o.inv.pickRange  [key:invPickRange]
  • ChoiceChip (line 299) — label comes from the caller / record data
  ✔ FilledButton.icon (line 1081) → o.inv.viewReturn  [key:invMoveViewReturn]
  • InkWell (line 1140) — movement row → o.inv.movementRow
```
## features/inventory/presentation/pages/warehouse_settings_page.dart
```
  • SwitchListTile (line 78) — label comes from the caller / record data
  ✔ TextButton (line 200) → p.savings.cancelNew  [key:cancel]
  ✔ FilledButton (line 209) → p.budget.saveDetail  [key:save]
  ✔ IconButton (line 173) → o.inv.setExpiryWarn  [key:invSetExpiryWarn]
```
## features/inventory/presentation/widgets/falcon_message_bubble.dart
```
  • GestureDetector (line 71) — label comes from the caller / record data
```
## features/inventory/presentation/widgets/inventory_list_parts.dart
```
  ✔ IconButton (line 74) → o.inv.scan  [key:invScanBarcode]
  • InkWell (line 116) — label comes from the caller / record data
  • InventoryPill (line 193) — label comes from the caller / record data
  ✔ InkWell (line 258) → o.inv.statusLow  [key:invLow]
  • TextButton.icon (line 376) — label comes from the caller / record data
  ✔ InkWell (line 424) → o.inv.categoryTile  [key:invCatProductsCount]
```
## features/inventory/presentation/widgets/product_picker.dart
```
  ✔ IconButton (line 378) → o.inv.scan  [key:invScanBarcode]
  ✔ ListTile (line 430) → s.ai.markOne  [icon:Icons.check_circle]
  ✔ InventoryPill (line 473) → o.inv.noCategory  [key:invNoCategory]
  ✔ InventoryPill (line 479) → o.inv.withCategory  [key:invWithCategory]
  ✔ TextButton.icon (line 498) → o.inv.categories  [key:invCategories]
  • InventoryCategoryTile (line 567) — label comes from the caller / record data
  ✔ IconButton (line 588) → p.tree.zoomOut  [icon:Icons.remove]
  ✔ IconButton (line 599) → c.icon.add  [icon:Icons.add]
  ✔ FilledButton.icon (line 642) → p.budget.saveDetail  [key:save]
```
## features/invoices/presentation/pages/invoice_design_editor_page.dart
```
  ✔ TextButton (line 130) → p.savings.cancelNew  [key:cancel]
  ✔ TextButton (line 135) → b.nav.unsavedExit  [key:invExitWithoutSave]
  ✔ FilledButton (line 140) → b.nav.saveExit  [key:invSaveAndExit]
  ✔ IconButton (line 237) → c.icon.back  [icon:Icons.arrow_back_ios_new]
  ✔ IconButton (line 257) → b.design.saveCheck  [icon:Icons.check_rounded]
  • Slider (line 432) — label comes from the caller / record data
  ✔ FilledButton.icon (line 446) → p.budget.saveDetail  [key:save]
  ✔ IconButton (line 515) → c.icon.delete  [icon:Icons.delete_outline]
  ✔ TextButton.icon (line 520) → b.design.pickImage  [icon:Icons.upload_outlined]
  ✔ IconButton (line 557) → c.icon.delete  [icon:Icons.delete_outline]
  ✔ TextButton.icon (line 562) → c.icon.add  [icon:Icons.add]
  ✔ ListTile (line 588) → b.design.sigUpload  [key:sigUpload]
  ✔ ListTile (line 594) → b.design.sigDirect  [key:sigDirect]
  ✔ GestureDetector (line 623) → p.banks.pickerRow  [icon:Icons.chevron_left_rounded]
  • FyonaTextFormField (line 650) — label comes from the caller / record data
  • SwitchListTile (line 669) — label comes from the caller / record data
  • GestureDetector (line 707) — label comes from the caller / record data
  ✔ TextButton (line 726) → p.savings.cancelNew  [key:cancel]
```
## features/invoices/presentation/pages/invoice_design_hub_page.dart
```
  ✔ IconButton (line 65) → c.icon.back  [icon:Icons.arrow_back_ios_new]
  ✔ IconButton (line 214) → p.receipt.reset  [key:clear]
  ✔ InkWell (line 165) → c.icon.back  [icon:Icons.arrow_back_ios_new]
```
## features/invoices/presentation/pages/invoice_view_page.dart
```
  ✔ IconButton (line 215) → c.icon.back  [icon:Icons.arrow_back_ios_new]
  • OutlinedButton.icon (line 320) — label comes from the caller / record data
```
## features/invoices/presentation/pages/invoices_list_page.dart
```
  ✔ IconButton (line 145) → c.icon.back  [icon:Icons.arrow_back_ios_new]
  ✔ GestureDetector (line 235) → c.icon.close  [icon:Icons.close]
  ✔ GestureDetector (line 198) → b.inv.filterDate  [key:invFilterDate]
  • _ReturnTile (line 268) — label comes from the caller / record data
  • _InvoiceTile (line 274) — label comes from the caller / record data
  • GestureDetector (line 290) — label comes from the caller / record data
  • ListTile (line 355) — invoice row → b.sale.row
  • ListTile (line 409) — invoice row → b.sale.row
```
## features/invoices/presentation/widgets/invoice_preview_card.dart
```
  • _SigGesture (line 681) — label comes from the caller / record data
```
## features/invoices/presentation/widgets/signature_pad_dialog.dart
```
  ✔ _toolBtn (line 84) → b.design.sigUndo  [key:sigUndo]
  ✔ _toolBtn (line 92) → b.design.sigClear  [key:sigClear]
  ✔ OutlinedButton (line 105) → p.savings.cancelNew  [key:cancel]
  ✔ FilledButton (line 115) → p.budget.saveDetail  [key:save]
  • IconButton (line 139) — label comes from the caller / record data
```
## features/notifications/presentation/pages/notification_list_page.dart
```
  • GestureDetector (line 185) — label comes from the caller / record data
  • GestureDetector (line 286) — label comes from the caller / record data
```
## features/notifications/presentation/pages/notification_settings_page.dart
```
  ✔ TextButton (line 54) → p.budget.saveDetail  [key:save]
  ✔ _buildSwitch (line 67) → g.notif.email  [key:notificationsEmailAlerts]
  ✔ _buildSwitch (line 75) → p.banks.export  [icon:Icons.receipt_long]
  ✔ _buildSwitch (line 83) → g.notif.payments  [key:notificationsPaymentAlerts]
  ✔ _buildSwitch (line 91) → g.notif.system  [key:notificationsSystemUpdates]
  ✔ _buildSwitch (line 100) → g.notif.budget  [key:notificationsBudgetAlerts]
  ✔ _buildSwitch (line 108) → g.notif.lowBalance  [key:notificationsLowBalanceAlert]
  ✔ _buildSwitch (line 117) → g.notif.daily  [key:notificationsDailyReport]
  ✔ _buildSwitch (line 125) → g.notif.weekly  [key:weeklyReport]
  ✔ _buildSwitch (line 133) → c.icon.calendar  [icon:Icons.calendar_month]
  ✔ ElevatedButton (line 147) → s.settings.saveSettings  [key:adminSaveSettings]
  • SwitchListTile (line 172) — label comes from the caller / record data
```
## features/notifications/presentation/pages/reminder_list_page.dart
```
  ✔ FloatingActionButton (line 34) → c.icon.add  [icon:Icons.add]
  ✔ IconButton (line 142) → c.icon.edit  [icon:Icons.edit_outlined]
  ✔ IconButton (line 147) → c.icon.delete  [icon:Icons.delete_outline]
  ✔ InkWell (line 264) → c.icon.calendar  [icon:Icons.event]
  ✔ DropdownMenuItem (line 311) → s.reminder.frequency  [key:notificationsOnce]
  ✔ DropdownMenuItem (line 312) → p.recurring.frequency  [key:frequencyDaily]
  ✔ DropdownMenuItem (line 313) → p.recurring.frequency  [key:frequencyWeekly]
  ✔ DropdownMenuItem (line 314) → p.recurring.frequency  [key:frequencyMonthly]
  ✔ DropdownButtonFormField (line 307) → s.reminder.frequency  [key:frequency]
  ✔ TextButton (line 322) → p.savings.cancelNew  [key:cancel]
  ✔ ElevatedButton (line 326) → s.reminder.create  [key:actionCreate]
```
## features/notifications/presentation/widgets/unread_notification_bell.dart
```
  • GestureDetector (line 89) — label comes from the caller / record data
```
## features/personal/presentation/pages/all_banks_report_page.dart
```
  ✔ GestureDetector (line 238) → p.allBanks.back  [icon:Icons.arrow_forward_ios]
  ✔ IconButton (line 254) → p.banks.export  [icon:Icons.receipt_long]
  ✔ IconButton (line 275) → s.bank.periodPrev  [icon:Icons.chevron_right]
  ✔ IconButton (line 280) → s.bank.periodPrev  [icon:Icons.chevron_left]
```
## features/personal/presentation/pages/chat_page.dart
```
  ✔ GestureDetector (line 823) → s.sugg.play  [icon:Icons.play_circle_fill]
  ✔ GestureDetector (line 848) → c.icon.close  [icon:Icons.close]
  ✔ TextButton (line 891) → p.chat.cancel  [key:chatCancel]
  ✔ FilledButton (line 898) → p.chat.sendMedia  [key:chatSendMedia]
  ✔ IconButton (line 948) → c.icon.close  [icon:Icons.close]
  ✔ TextButton (line 1243) → p.chat.cancel  [key:chatCancel]
  ✔ FilledButton (line 1250) → p.chat.sendMedia  [key:chatSendMedia]
  ✔ TextButton (line 1525) → p.chat.cancel  [key:chatCancel]
  ✔ FilledButton (line 1532) → p.chat.sendMedia  [key:chatSendMedia]
  ✔ ListTile (line 1593) → p.chat.reply  [key:chatReply]
  ✔ ListTile (line 1605) → p.chat.copy  [key:chatCopy]
  ✔ ListTile (line 1618) → p.chat.edit  [key:chatEdit]
  ✔ ListTile (line 1630) → p.chat.delete  [key:chatDelete]
  ✔ TextButton (line 1675) → p.chat.cancel  [key:chatCancel]
  ✔ FilledButton (line 1682) → p.chat.edit  [key:chatEdit]
  ✔ TextButton (line 1727) → p.chat.cancel  [key:chatCancel]
  ✔ FilledButton (line 1734) → p.chat.delete  [key:chatDelete]
  ✔ IconButton (line 1840) → c.icon.refresh  [icon:Icons.refresh]
  • ListTile (line 1824) — outbox/upload row (message text); its retry/cancel icons are covered
  ✔ TextButton (line 1861) → p.chat.older  [icon:Icons.expand_less]
  • _ChatBubble (line 1895) — label comes from the caller / record data
  ✔ TextButton (line 1935) → p.chat.latest  [icon:Icons.keyboard_double_arrow_down]
  ✔ InkWell (line 2036) → s.bank.periodPrev  [icon:Icons.chevron_left]
  ✔ IconButton (line 2110) → c.icon.close  [icon:Icons.close]
  ✔ IconButton (line 2115) → c.icon.refresh  [icon:Icons.refresh]
  ✔ IconButton (line 2214) → p.chat.cancelUpload  [key:chatCancelUpload]
  ✔ IconButton (line 2324) → p.chat.cancelUpload  [key:chatCancelUpload]
  ✔ OutlinedButton.icon (line 2413) → p.chat.cancelRecord  [key:chatCancelRecord]
  ✔ OutlinedButton.icon (line 2441) → p.chat.pauseResume  [key:chatResume]
  ✔ FilledButton.icon (line 2472) → p.chat.sendRecord  [key:chatSendRecord]
  ✔ _circleButton (line 2552) → c.icon.add  [icon:Icons.add]
  ✔ _circleButton (line 2605) → p.chat.send  [icon:Icons.send]
  ✔ _circleButton (line 2610) → s.sugg.mic  [icon:Icons.mic]
  • InkWell (line 2632) — label comes from the caller / record data
  ✔ IconButton (line 2696) → c.icon.close  [icon:Icons.close]
  ✔ ListTile (line 2718) → p.chat.camera  [key:chatCamera]
  ✔ ListTile (line 2732) → p.chat.gallery  [key:chatGallery]
  ✔ ListTile (line 2750) → p.chat.files  [key:chatFiles]
  ✔ ListTile (line 2765) → p.chat.invoice  [key:chatInvoicePick]
  ✔ InkWell (line 2985) → p.chat.play  [icon:Icons.broken_image_outlined]
  ✔ InkWell (line 3012) → s.sugg.play  [icon:Icons.play_circle_fill]
  ✔ InkWell (line 3056) → s.sara.play  [icon:Icons.pause]
  • InkWell (line 3094) — label comes from the caller / record data
  ✔ IconButton (line 3197) → c.icon.download  [icon:Icons.download_outlined]
  ✔ InkWell (line 3156) → p.chat.files  [key:chatFiles]
  ✔ InkWell (line 3216) → p.mdebt.row  [key:debtInvoiceWord]
  • GestureDetector (line 2895) — chat bubble parts: the bubble owns a native long press → silent
  • GestureDetector (line 3334) — chat bubble parts: the bubble owns a native long press → silent
  • GestureDetector (line 3402) — chat bubble parts: the bubble owns a native long press → silent
  ✔ GestureDetector (line 3429) → s.sugg.play  [icon:Icons.play_circle_fill]
  • GestureDetector (line 3519) — label comes from the caller / record data
  ✔ SimpleDialogOption (line 3641) → p.chat.saveCurrent  [key:chatSaveCurrent]
  • SimpleDialogOption (line 3648) — label comes from the caller / record data
  ✔ IconButton (line 3613) → c.icon.download  [icon:Icons.download_outlined]
  ✔ IconButton (line 3675) → s.sugg.play  [icon:Icons.play_circle_fill]
  ✔ IconButton (line 3864) → s.sugg.play  [icon:Icons.play_circle_fill]
  ✔ IconButton (line 3983) → c.icon.download  [icon:Icons.download_outlined]
  ✔ IconButton (line 4041) → s.sara.play  [icon:Icons.pause]
  ✔ ListTile (line 4158) → p.chat.invoice  [icon:Icons.receipt_long_outlined]
```
## features/personal/presentation/pages/finance_overview_page.dart
```
  • GestureDetector (line 125) — label comes from the caller / record data
  • DropdownMenuItem (line 169) — label comes from the caller / record data
  • DropdownButton (line 165) — label comes from the caller / record data
  • DropdownMenuItem (line 182) — label comes from the caller / record data
  • DropdownButton (line 178) — label comes from the caller / record data
  ✔ IconButton (line 193) → p.banks.export  [icon:Icons.receipt_long]
  ✔ IconButton (line 194) → c.icon.search  [icon:TwoToneIcons.search]
  ✔ GestureDetector (line 195) → p.overview.addImage  [key:addImage]
  • Checkbox (line 217) — label comes from the caller / record data
  • Checkbox (line 235) — label comes from the caller / record data
  ✔ IconButton (line 371) → c.icon.search  [icon:TwoToneIcons.search]
  ✔ TextButton (line 401) → c.close  [key:close]
```
## features/personal/presentation/pages/merchant_accounts_page.dart
```
  ✔ IconButton (line 105) → p.merchants.unlinkMode  [key:merchantUnlinkTooltip]
  ✔ IconButton (line 115) → c.icon.notifications  [icon:Icons.notifications_outlined]
  ✔ FilledButton.icon (line 135) → p.merchants.unlink  [key:merchantUnlinkBtn]
  ✔ InkWell (line 246) → p.merchants.requests  [key:merchantRequestsBtn]
  ✔ FilledButton (line 439) → p.merchants.approve  [key:merchantApprove]
  ✔ OutlinedButton (line 463) → p.merchants.reject  [key:merchantCancelBtn]
  ✔ TextButton (line 550) → p.savings.cancelNew  [key:cancel]
  ✔ FilledButton (line 554) → p.merchants.confirm  [key:merchantConfirmBtn]
  ✔ InkWell (line 591) → p.merchants.card  [icon:Icons.storefront_outlined]
  ✔ TextButton (line 689) → p.savings.cancelNew  [key:cancel]
  ✔ FilledButton (line 693) → p.merchants.unlink  [key:merchantUnlinkBtn]
  ✔ TextButton (line 787) → p.savings.cancelNew  [key:cancel]
  ✔ FilledButton (line 791) → p.merchants.send  [key:merchantSend]
  ✔ Tab (line 843) → p.merchants.tabDebts  [key:merchantDebts]
  ✔ Tab (line 844) → p.merchants.tabInvoices  [key:merchantInvoices]
```
## features/personal/presentation/pages/merchant_debt_pages.dart
```
  ✔ TextButton (line 233) → b.sale.close  [key:saleClose]
  • Tab (line 371) — label comes from the caller / record data
  ✔ GestureDetector (line 409) → p.dnotif.tabSettlement  [key:debtNotifTabSettlement]
  • SimpleDialogOption (line 630) — label comes from the caller / record data
  • InkWell (line 694) — label comes from the caller / record data
  ✔ Tab (line 753) → p.mdebt.tabIndividual  [key:debtIndividualTab]
  ✔ Tab (line 754) → p.mdebt.tabSections  [key:debtSectionsTab]
  • ChatUnreadIcon (line 786) — label comes from the caller / record data
  ✔ IconButton (line 791) → c.icon.notifications  [icon:Icons.notifications_outlined]
  ✔ DebtPeriodFilter (line 815) → p.mdebt.periodAll  [key:debtFiltersAll]
  • DebtGroupTile (line 885) — label comes from the caller / record data
  ✔ GestureDetector (line 976) → p.home.currency  [icon:Icons.expand_more]
  ✔ DebtOperationTile (line 1082) → p.mdebt.row  [key:debtInvoiceWord]
  • SimpleDialogOption (line 1202) — label comes from the caller / record data
  • ChatUnreadIcon (line 1243) — label comes from the caller / record data
  ✔ IconButton (line 1248) → c.icon.notifications  [icon:Icons.notifications_outlined]
  ✔ DebtPeriodFilter (line 1267) → p.mdebt.periodAll  [key:debtFiltersAll]
  ✔ DebtOperationTile (line 1326) → p.mdebt.row  [key:debtInvoiceWord]
  • ChatUnreadIcon (line 1469) — label comes from the caller / record data
  ✔ IconButton (line 1516) → p.mdebt.editInvoice  [key:debtEditInvoice]
  ✔ IconButton (line 1522) → p.mdebt.deleteInvoice  [key:debtDeleteInvoice]
  ✔ FilledButton.icon (line 1582) → p.mdebt.settled  [key:debtSettledFull]
  ✔ FilledButton.icon (line 1634) → p.mdebt.viewInvoice  [key:debtViewInvoice]
  ✔ OutlinedButton.icon (line 1672) → p.mdebt.payments  [key:debtPayments]
  ✔ OutlinedButton.icon (line 1701) → p.mdebt.payments  [key:debtPayments]
  ✔ FilledButton.icon (line 1732) → p.mdebt.viewInvoice  [key:debtOriginalInvoice]
  ✔ TextButton (line 1791) → b.sale.close  [key:saleClose]
  ✔ IconButton (line 1862) → p.savings.cancelNew  [key:cancel]
  ✔ FilledButton (line 1954) → p.mdebt.saveChanges  [key:debtSaveChanges]
  ✔ TextButton (line 2054) → p.savings.cancelNew  [key:cancel]
  ✔ FilledButton (line 2058) → p.mdebt.deleteInvoice  [key:debtDeleteInvoice]
  • InkWell (line 2175) — label comes from the caller / record data
  ✔ InkWell (line 2227) → c.icon.close  [icon:Icons.close_rounded]
```
## features/personal/presentation/pages/personal_account_detail_page.dart
```
  ✔ TextButton (line 235) → p.savings.cancelNew  [key:cancel]
  ✔ TextButton (line 239) → p.debts.delete  [key:delete]
  • _chip (line 382) — label comes from the caller / record data
  • GestureDetector (line 413) — label comes from the caller / record data
  ✔ _dateChip (line 445) → p.account.from  [key:statementPeriodFrom]
  ✔ _dateChip (line 453) → p.account.to  [key:statementPeriodTo]
  ✔ IconButton (line 460) → c.icon.close  [icon:Icons.close]
  • GestureDetector (line 501) — label comes from the caller / record data
  ✔ _QuickBtn (line 529) → b.move.save  [key:addIncome]
  ✔ _QuickBtn (line 538) → b.move.save  [key:addExpense]
  ✔ _ActionIcon (line 602) → c.icon.delete  [icon:Icons.delete_outline_rounded]
  • GestureDetector (line 552) — label comes from the caller / record data
  • GestureDetector (line 624) — label comes from the caller / record data
  • GestureDetector (line 647) — label comes from the caller / record data
```
## features/personal/presentation/pages/personal_account_tree_page.dart
```
  ✔ TextButton (line 104) → p.savings.cancelNew  [key:cancel]
  ✔ TextButton (line 105) → p.accountTree.generate  [key:generateReport]
  ✔ GestureDetector (line 336) → p.allBanks.back  [icon:Icons.arrow_forward_ios]
  ✔ IconButton (line 352) → p.accountTree.export  [key:exportAccountTree]
  ✔ InkWell (line 464) → s.sub.expandCountry  [icon:Icons.keyboard_arrow_up]
```
## features/personal/presentation/pages/personal_backup_page.dart
```
  ✔ TextButton (line 260) → b.sale.ok  [key:ok]
  ✔ InkWell (line 586) → c.icon.close  [icon:Icons.close]
  ✔ ElevatedButton.icon (line 609) → p.backup.importDevice  [key:backupImportDevice]
  ✔ InkWell (line 759) → c.icon.close  [icon:Icons.close]
  ✔ OutlinedButton.icon (line 892) → p.backup.restoreThis  [key:backupRestoreThis]
  ✔ IconButton (line 912) → p.debts.delete  [key:delete]
  ✔ TextButton (line 956) → p.savings.cancelNew  [key:cancel]
  ✔ ElevatedButton (line 960) → p.backup.restoreThis  [key:backupRestoreAction]
  ✔ ElevatedButton (line 1025) → p.backup.retry  [key:backupRetry]
  ✔ TextButton (line 1036) → b.sale.ok  [key:ok]
  ✔ TextButton (line 1185) → p.savings.cancelNew  [key:cancel]
  ✔ ElevatedButton (line 1189) → p.debts.delete  [key:delete]
  ✔ TextButton (line 1221) → p.savings.cancelNew  [key:cancel]
  ✔ ElevatedButton (line 1225) → p.debts.delete  [key:delete]
  ✔ TextButton (line 1278) → b.sale.ok  [key:ok]
  ✔ TextButton (line 1282) → c.retry  [key:retry]
  ✔ _sourceOption (line 1333) → p.backup.sourceDevice  [key:backupSourceDevice]
  ✔ _sourceOption (line 1340) → p.backup.sourceServer  [key:backupSourceServer]
  ✔ _bigButton (line 1362) → p.backup.create  [key:backupCreateAction]
  ✔ _bigButton (line 1372) → p.backup.restoreTitle  [key:backupRestoreTitle]
  ✔ OutlinedButton.icon (line 1384) → p.backup.manage  [key:backupManageAction]
  ✔ ElevatedButton (line 1407) → p.backup.create  [key:backupCreateFirst]
  ✔ ElevatedButton.icon (line 1430) → p.backup.create  [key:backupSaveCurrentData]
  • InkWell (line 1460) — label comes from the caller / record data
  • ElevatedButton.icon (line 1616) — label comes from the caller / record data
  • Switch (line 1666) — label comes from the caller / record data
  ✔ InkWell (line 1692) → c.icon.close  [icon:Icons.close]
  ✔ TextButton (line 1725) → p.backup.retry  [key:backupRetry]
```
## features/personal/presentation/pages/personal_bank_statement_page.dart
```
  • GestureDetector (line 93) — label comes from the caller / record data
  • DropdownMenuItem (line 134) — label comes from the caller / record data
  • DropdownButton (line 130) — label comes from the caller / record data
  • DropdownMenuItem (line 147) — label comes from the caller / record data
  • DropdownButton (line 143) — label comes from the caller / record data
```
## features/personal/presentation/pages/personal_banks_page.dart
```
  ✔ ElevatedButton.icon (line 461) → c.close  [key:close]
  ✔ ElevatedButton.icon (line 478) → c.close  [key:close]
  ✔ CurrencySelector (line 512) → b.debts.currency  [key:currencyLabel]
  • DropdownMenuItem (line 524) — label comes from the caller / record data
  ✔ DropdownButton (line 519) → p.banks.accountType  [key:accountTypeLabel]
  ✔ TextButton (line 531) → p.savings.cancelNew  [key:cancel]
  ✔ ElevatedButton (line 537) → b.banks.saveForm  [key:update]
  ✔ _InputField (line 573) → c.amount  [key:amountLabel]
  ✔ ElevatedButton.icon (line 588) → p.transfer.go  [key:transfer]
  ✔ GestureDetector (line 672) → p.banks.pickerRow  [icon:Icons.chevron_left_rounded]
  ✔ GestureDetector (line 775) → p.banks.pickerBack  [icon:Icons.arrow_forward_ios_rounded]
  ✔ InkWell (line 799) → p.banks.pickerRow  [icon:Icons.chevron_left_rounded]
  ✔ InkWell (line 862) → p.banks.pickerRow  [icon:Icons.account_balance_rounded]
  ✔ GestureDetector (line 958) → p.home.currency  [icon:Icons.expand_more]
  • CurrencySelector (line 1006) — label comes from the caller / record data
  ✔ GestureDetector (line 1088) → c.icon.dropdown  [icon:TwoToneIcons.arrowDown]
  ✔ GestureDetector (line 1070) → b.banks.currencies  [key:bankCurrenciesCount]
  ✔ ElevatedButton.icon (line 1113) → b.banks.addCurrency  [key:addCurrency]
  ✔ OutlinedButton.icon (line 1128) → b.banks.deleteBank  [key:deleteBankCompletely]
  ✔ InkWell (line 1185) → p.banks.export  [icon:Icons.receipt_long]
  ✔ InkWell (line 1186) → c.icon.edit  [icon:TwoToneIcons.edit]
  ✔ InkWell (line 1187) → c.icon.delete  [icon:TwoToneIcons.delete]
```
## features/personal/presentation/pages/personal_budget_detail_page.dart
```
  ✔ IconButton (line 281) → c.icon.edit  [icon:Icons.edit_outlined]
  • GestureDetector (line 312) — label comes from the caller / record data
  ✔ _actionBtn (line 404) → p.budget.pdf  [text:PDF]
  ✔ _actionBtn (line 413) → p.budget.image  [key:budgetActionImage]
  ✔ _actionBtn (line 422) → p.budget.share  [key:share]
  • GestureDetector (line 435) — label comes from the caller / record data
  ✔ GestureDetector (line 711) → p.budget.addCategory  [key:budgetAddCategory]
  ✔ ElevatedButton.icon (line 842) → p.budget.saveDetail  [key:saving]
  ✔ IconButton (line 1124) → c.icon.close  [icon:Icons.close_rounded]
  ✔ _catActionBtn (line 1158) → p.budget.pdf  [text:PDF]
  ✔ _catActionBtn (line 1168) → p.budget.share  [key:share]
  • GestureDetector (line 1244) — label comes from the caller / record data
```
## features/personal/presentation/pages/personal_budget_form_page.dart
```
  ✔ GestureDetector (line 390) → s.sub.planCard  [icon:Icons.check_circle_rounded]
  • GestureDetector (line 458) — label comes from the caller / record data
  ✔ IconButton (line 590) → p.budget.addCustomCat  [icon:Icons.add_circle_rounded]
  ✔ GestureDetector (line 632) → c.icon.close  [icon:Icons.close_rounded]
  ✔ GestureDetector (line 903) → c.icon.calendar  [icon:Icons.calendar_today_rounded]
  ✔ OutlinedButton (line 944) → p.form.previous  [key:previous]
  ✔ ElevatedButton (line 958) → c.next  [key:next]
```
## features/personal/presentation/pages/personal_budget_page.dart
```
  ✔ TextButton (line 40) → p.savings.cancelNew  [key:cancel]
  ✔ TextButton (line 41) → p.debts.delete  [key:delete]
  • _BudgetCard (line 73) — label comes from the caller / record data
  ✔ ElevatedButton.icon (line 144) → p.budget.createNew  [key:budgetCreateNew]
  ✔ ElevatedButton.icon (line 193) → p.budget.createNew  [key:budgetCreate]
  ✔ ElevatedButton (line 234) → c.retry  [key:retry]
  ✔ PopupMenuItem (line 334) → p.debts.edit  [key:edit]
  ✔ PopupMenuItem (line 341) → p.debts.delete  [key:delete]
  ✔ PopupMenuButton (line 328) → c.icon.more  [icon:Icons.more_vert_rounded]
  ✔ GestureDetector (line 279) → p.budget.card  [key:budgetTotal]
```
## features/personal/presentation/pages/personal_categories_page.dart
```
  ✔ TextButton (line 45) → p.savings.cancelNew  [key:cancel]
  ✔ TextButton (line 46) → p.debts.delete  [key:delete]
  ✔ TextButton.icon (line 69) → p.categories.add  [key:addCategory]
  ✔ PopupMenuItem (line 107) → p.categories.edit  [key:editLabel]
  ✔ PopupMenuItem (line 108) → p.debts.delete  [key:delete]
  • PopupMenuButton (line 99) — label comes from the caller / record data
```
## features/personal/presentation/pages/personal_category_form_page.dart
```
  ✔ ElevatedButton (line 109) → p.savings.saveChanges  [key:saveChanges]
```
## features/personal/presentation/pages/personal_dashboard_page.dart
```
  ✔ ElevatedButton.icon (line 191) → c.retry  [key:retry]
  ✔ ElevatedButton.icon (line 221) → c.retry  [key:retry]
  ✔ CurrencySelector (line 362) → b.debts.currency  [key:currencyLabel]
  ✔ GestureDetector (line 406) → p.home.currency  [icon:Icons.expand_more]
  • _NetWorthToggleArrow (line 423) — label comes from the caller / record data
  • GestureDetector (line 472) — label comes from the caller / record data
  • _NetWorthToggleArrow (line 518) — label comes from the caller / record data
  ✔ GestureDetector (line 585) → b.home.recentViewAll  [key:viewAll]
  • GestureDetector (line 627) — label comes from the caller / record data
  ✔ ListTile (line 733) → p.home.txReceipt  [key:txViewReceipt]
  ✔ TextButton (line 750) → p.savings.cancelNew  [key:cancel]
  ✔ TextButton (line 751) → p.debts.delete  [key:delete]
  ✔ ListTile (line 738) → p.debts.delete  [key:delete]
  ✔ GestureDetector (line 837) → b.home.recentViewAll  [key:viewAll]
  ✔ GestureDetector (line 948) → p.home.manage  [key:manage]
  ✔ GestureDetector (line 955) → p.home.activeBudgets  [key:personalActiveBudgets]
  ✔ GestureDetector (line 993) → p.home.manage  [key:manage]
  ✔ GestureDetector (line 1000) → p.home.activeRecurring  [key:personalActiveTransactions]
```
## features/personal/presentation/pages/personal_debts_page.dart
```
  ✔ TextButton (line 98) → p.savings.cancelNew  [key:cancel]
  ✔ TextButton (line 99) → p.debts.delete  [key:delete]
  ✔ GestureDetector (line 206) → p.debts.addNew  [key:addNewDebt]
  ✔ _FilterChip (line 257) → p.debts.filterAll  [key:debtAllFilter]
  ✔ _FilterChip (line 259) → p.debts.filterOwedByMe  [key:debtOwedByMe]
  ✔ _FilterChip (line 261) → p.debts.filterOwedToMe  [key:debtOwedToMe]
  ✔ _FilterChip (line 263) → p.debts.filterOverdue  [key:debtOverdue]
  ✔ _FilterChip (line 265) → p.debts.filterPaid  [key:debtPaid]
  ✔ _FilterChip (line 267) → p.debts.filterPartial  [key:debtPartiallyPaid]
  ✔ TextButton (line 349) → p.savings.cancelNew  [key:cancel]
  ✔ GestureDetector (line 411) → p.home.currency  [icon:Icons.expand_more]
  • CurrencySelector (line 463) — label comes from the caller / record data
  • GestureDetector (line 521) — label comes from the caller / record data
  ✔ TextButton.icon (line 656) → p.debts.pay  [key:pay]
  ✔ TextButton.icon (line 662) → p.debts.edit  [key:edit]
  ✔ TextButton.icon (line 668) → p.debts.details  [key:details]
  ✔ TextButton.icon (line 674) → p.debts.delete  [key:delete]
  ✔ GestureDetector (line 559) → p.debts.filterOwedByMe  [key:debtOwedByMe]
  ✔ IconButton (line 848) → c.icon.close  [icon:TwoToneIcons.close]
  ✔ CurrencySelector (line 865) → b.debts.currency  [key:currencyLabel]
  • Switch (line 879) — label comes from the caller / record data
  ✔ GestureDetector (line 887) → p.debts.dueTime  [key:dueTime]
  ✔ ElevatedButton (line 907) → p.savings.saveChanges  [key:saveChanges]
  • GestureDetector (line 926) — label comes from the caller / record data
  ✔ GestureDetector (line 987) → c.icon.close  [icon:TwoToneIcons.close]
  ✔ GestureDetector (line 967) → p.debts.dueDate  [key:dueDateLabel]
  ✔ OutlinedButton.icon (line 1150) → p.debts.fullAmount  [key:fullAmount]
  • _currencyChip (line 1211) — label comes from the caller / record data
  • _currencyChip (line 1251) — label comes from the caller / record data
  • _currencyChip (line 1290) — label comes from the caller / record data
  ✔ TextButton (line 1340) → p.savings.cancelNew  [key:cancel]
  ✔ TextButton (line 1374) → p.savings.cancelNew  [key:cancel]
  ✔ TextButton (line 1452) → p.savings.cancelNew  [key:cancel]
  ✔ TextButton (line 1463) → p.savings.cancelNew  [key:cancel]
  ✔ ElevatedButton (line 1322) → p.debts.payAccount  [key:debtNoAccount]
  • GestureDetector (line 1491) — label comes from the caller / record data
  ✔ GestureDetector (line 1511) → b.design.saveCheck  [icon:Icons.check_rounded]
  ✔ IconButton (line 1592) → c.icon.back  [icon:Icons.arrow_back_ios]
  ✔ GestureDetector (line 1599) → p.debts.exportImage  [key:exportImage]
  ✔ IconButton (line 1796) → p.debts.delete  [key:delete]
  • ListTile (line 1748) — debt operation row → personal debts row help
  ✔ TextButton (line 1826) → p.savings.cancelNew  [key:cancel]
  ✔ TextButton (line 1830) → p.debts.delete  [key:delete]
```
## features/personal/presentation/pages/personal_executive_dashboard_page.dart
```
  • GestureDetector (line 179) — label comes from the caller / record data
```
## features/personal/presentation/pages/personal_invoice_document_page.dart
```
  ✔ OutlinedButton.icon (line 292) → p.invoiceDoc.savePdf  [key:invSavePdf]
  ✔ FilledButton.icon (line 316) → p.invoiceDoc.share  [key:saleShare]
  ✔ InkWell (line 342) → p.mdebt.modified  [key:debtModified]
  ✔ InkWell (line 427) → c.icon.close  [icon:Icons.close_rounded]
```
## features/personal/presentation/pages/personal_recurring_detail_page.dart
```
  ✔ IconButton (line 107) → c.icon.edit  [icon:Icons.edit_outlined]
  ✔ IconButton (line 111) → c.icon.delete  [icon:Icons.delete_outline_rounded]
  ✔ _ActionButton (line 434) → p.recurring.executeNow  [key:recurringExecuteNow]
  ✔ _ActionButton (line 439) → p.recurring.skip  [key:recurringSkipOnce]
  ✔ _ActionButton (line 450) → p.recurring.snooze  [key:snooze]
  ✔ _ActionButton (line 456) → p.recurring.pause  [key:recurringPause]
  ✔ _ActionButton (line 472) → p.debts.edit  [key:edit]
  ✔ _ActionButton (line 477) → p.recurring.delete  [key:recurringDeletePermanently]
  ✔ _PostponeOption (line 611) → p.recurring.postpone  [key:recurringTomorrow]
  ✔ _PostponeOption (line 615) → p.recurring.postpone  [key:recurringAfter3Days]
  ✔ _PostponeOption (line 619) → p.recurring.postpone  [key:recurringAfterWeek]
  ✔ _PostponeOption (line 623) → p.recurring.customDate  [key:recurringCustomDate]
  ✔ TextButton (line 651) → p.savings.cancelNew  [key:cancel]
  ✔ TextButton (line 652) → p.debts.delete  [key:delete]
  • InkWell (line 807) — label comes from the caller / record data
  ✔ ListTile (line 835) → p.banks.pickerBack  [icon:Icons.arrow_forward_ios_rounded]
  ✔ GestureDetector (line 914) → p.recurring.pickBank  [key:recurringAccountsCount]
  ✔ GestureDetector (line 942) → p.recurring.backToBanks  [key:recurringBackToBanks]
  ✔ GestureDetector (line 958) → p.recurring.pickAccount  [key:recurringBalanceIs]
  ✔ ElevatedButton (line 996) → p.recurring.executeNow  [key:recurringExecuteNow]
```
## features/personal/presentation/pages/personal_recurring_form_page.dart
```
  ✔ _TypeCard (line 304) → p.txs.filterIncome  [key:income]
  ✔ _TypeCard (line 306) → p.txs.filterExpense  [key:expense]
  • GestureDetector (line 339) — label comes from the caller / record data
  • GestureDetector (line 387) — label comes from the caller / record data
  • GestureDetector (line 421) — label comes from the caller / record data
  ✔ GestureDetector (line 502) → p.budget.pickDay  [key:startDate]
  ✔ GestureDetector (line 536) → p.recurring.reminderTime  [key:recurringReminderTimeLabel]
  ✔ GestureDetector (line 676) → p.recurring.pickBank  [key:recurringAccountsCount]
  ✔ GestureDetector (line 702) → p.recurring.backToBanks  [key:recurringBackToBanks]
  ✔ GestureDetector (line 718) → p.recurring.pickAccount  [key:recurringBalanceIs]
  ✔ GestureDetector (line 881) → s.ai.markOne  [icon:Icons.check_circle]
  ✔ GestureDetector (line 904) → c.icon.calendar  [icon:Icons.calendar_today_rounded]
  ✔ OutlinedButton (line 928) → p.form.previous  [key:previous]
  ✔ ElevatedButton (line 936) → c.next  [key:next]
  • GestureDetector (line 959) — label comes from the caller / record data
```
## features/personal/presentation/pages/personal_recurring_page.dart
```
  ✔ Tab (line 86) → p.txs.filterAll  [key:all]
  ✔ Tab (line 87) → p.recurring.tabActive  [key:recurringActiveLabel]
  ✔ Tab (line 88) → p.recurring.tabPaused  [key:recurringPausedLabel]
  ✔ FloatingActionButton.extended (line 97) → p.recurring.add  [key:recurringAddOperation]
  ✔ ElevatedButton.icon (line 132) → p.recurring.add  [key:recurringFormTitle]
  ✔ ElevatedButton.icon (line 158) → p.recurring.add  [key:recurringCreateNew]
  • _RecurringCard (line 222) — label comes from the caller / record data
  ✔ _PostponeOption (line 292) → p.recurring.postpone  [key:recurringTomorrow]
  ✔ _PostponeOption (line 296) → p.recurring.postpone  [key:recurringAfter3Days]
  ✔ _PostponeOption (line 300) → p.recurring.postpone  [key:recurringAfterWeek]
  ✔ _PostponeOption (line 304) → p.recurring.customDate  [key:recurringCustomDate]
  ✔ TextButton (line 329) → p.savings.cancelNew  [key:cancel]
  ✔ TextButton (line 330) → p.debts.delete  [key:delete]
  ✔ GestureDetector (line 381) → p.recurring.card  [key:recurringPausedOne]
  ✔ _ActionTile (line 530) → p.recurring.executeNow  [key:recurringExecuteNow]
  ✔ _ActionTile (line 531) → p.recurring.snooze  [key:snooze]
  ✔ _ActionTile (line 532) → p.recurring.skip  [key:recurringSkipOnce]
  ✔ _ActionTile (line 534) → p.debts.edit  [key:edit]
  ✔ _ActionTile (line 535) → p.recurring.pause  [key:recurringPause]
  ✔ _ActionTile (line 541) → p.debts.delete  [key:delete]
  • ListTile (line 558) — label comes from the caller / record data
  ✔ ListTile (line 574) → p.banks.pickerBack  [icon:Icons.arrow_forward_ios_rounded]
```
## features/personal/presentation/pages/personal_transactions_page.dart
```
  ✔ GestureDetector (line 151) → p.txs.from  [key:fromLabel]
  ✔ GestureDetector (line 182) → p.txs.to  [key:toLabel]
  ✔ TextButton (line 215) → p.savings.cancelNew  [key:cancel]
  ✔ ElevatedButton (line 227) → p.txs.applyFilter  [key:txApplyFilter]
  ✔ Tab (line 290) → p.txs.tab  [key:transactionsTab]
  ✔ Tab (line 291) → p.txs.recurringTab  [key:recurring]
  ✔ IconButton (line 324) → c.icon.close  [icon:TwoToneIcons.close]
  • GestureDetector (line 344) — label comes from the caller / record data
  ✔ GestureDetector (line 376) → c.icon.close  [icon:Icons.close]
  ✔ GestureDetector (line 363) → c.icon.calendar  [icon:Icons.date_range]
  ✔ ElevatedButton.icon (line 446) → p.recurring.add  [key:recurringCreateNew]
  ✔ Tab (line 475) → p.txs.filterAll  [key:all]
  ✔ Tab (line 476) → p.recurring.tabActive  [key:recurringActive]
  ✔ Tab (line 477) → p.recurring.tabPaused  [key:recurringPaused]
  ✔ ElevatedButton.icon (line 521) → p.recurring.add  [key:recurringFormTitle]
  ✔ GestureDetector (line 554) → p.recurring.card  [key:recurringPausedOne]
  • GestureDetector (line 661) — label comes from the caller / record data
  • GestureDetector (line 687) — transaction row inside ClickerQuiet (native long press) → silent
  ✔ ListTile (line 728) → p.home.txReceipt  [key:txViewReceipt]
  ✔ TextButton (line 745) → p.savings.cancelNew  [key:cancel]
  ✔ TextButton (line 746) → p.debts.delete  [key:delete]
  ✔ ListTile (line 733) → p.debts.delete  [key:delete]
```
## features/personal/presentation/pages/personal_transfer_page.dart
```
  ✔ GestureDetector (line 109) → p.banks.pickAccount  [key:selectAccount]
  ✔ ElevatedButton (line 237) → p.transfer.done  [key:completed]
  ✔ GestureDetector (line 481) → p.banks.pickerBack  [icon:Icons.arrow_forward_ios_rounded]
  ✔ InkWell (line 511) → p.banks.pickerRow  [icon:Icons.chevron_left_rounded]
  ✔ InkWell (line 578) → p.banks.pickerRow  [icon:Icons.account_balance_rounded]
```
## features/personal/presentation/pages/receipt_design_editor_page.dart
```
  ✔ IconButton (line 66) → c.icon.back  [icon:Icons.arrow_back_ios_new]
  ✔ TextButton (line 80) → p.budget.saveDetail  [key:save]
  ✔ ElevatedButton.icon (line 112) → p.budget.saveDetail  [key:save]
  • Slider (line 292) — label comes from the caller / record data
  • GestureDetector (line 348) — label comes from the caller / record data
  • Switch (line 384) — label comes from the caller / record data
  • OutlinedButton (line 411) — label comes from the caller / record data
  • GestureDetector (line 447) — label comes from the caller / record data
  ✔ TextButton (line 461) → p.savings.cancelNew  [key:cancel]
```
## features/personal/presentation/pages/receipt_design_hub_page.dart
```
  ✔ IconButton (line 34) → c.icon.back  [icon:Icons.arrow_back_ios_new]
  ✔ SwitchListTile (line 62) → p.receipt.unified  [key:receiptUnifiedTitle]
  ✔ IconButton (line 139) → p.receipt.reset  [key:clear]
  ✔ InkWell (line 115) → c.icon.back  [icon:Icons.arrow_back_ios_new]
```
## features/personal/presentation/pages/reports/personal_report_view_page.dart
```
  ✔ IconButton (line 235) → c.icon.back  [icon:Icons.arrow_back_ios_new]
  • PrCurrencyChip (line 249) — label comes from the caller / record data
  • PrPeriodBar (line 263) — label comes from the caller / record data
  ✔ FloatingActionButton.extended (line 280) → p.savingsDetail.exportPdf  [key:exportPdf]
```
## features/personal/presentation/pages/reports/personal_report_widgets.dart
```
  ✔ ListTile (line 111) → s.sub.planCard  [icon:Icons.check_circle_rounded]
  ✔ GestureDetector (line 979) → p.reports.currency  [icon:Icons.currency_exchange_rounded]
  • ChoiceChip (line 1065) — label comes from the caller / record data
```
## features/personal/presentation/pages/reports/personal_reports_page.dart
```
  ✔ IconButton (line 114) → c.icon.back  [icon:Icons.arrow_back_ios_new]
  • PrCurrencyChip (line 130) — label comes from the caller / record data
  • PrPeriodBar (line 141) — label comes from the caller / record data
  • ReportTileCard (line 197) — label comes from the caller / record data
```
## features/personal/presentation/pages/savings_goal_detail_page.dart
```
  ✔ GestureDetector (line 108) → p.allBanks.back  [icon:Icons.arrow_forward_ios]
  • ElevatedButton (line 380) — label comes from the caller / record data
```
## features/personal/presentation/pages/savings_goals_page.dart
```
  ✔ TextButton (line 264) → p.savings.cancelNew  [key:cancel]
  ✔ TextButton (line 265) → p.debts.delete  [key:delete]
  ✔ GestureDetector (line 314) → p.savings.cancelNew  [key:cancel]
  ✔ CurrencySelector (line 380) → b.debts.currency  [key:currencyLabel]
  ✔ GestureDetector (line 388) → p.savings.dueDate  [key:dueDateOptionalLabel]
  • GestureDetector (line 410) — label comes from the caller / record data
  ✔ GestureDetector (line 432) → p.savings.cancelNew  [key:cancel]
  ✔ GestureDetector (line 441) → p.savings.saveChanges  [key:saveChanges]
  ✔ PopupMenuItem (line 541) → p.savings.addAmount  [key:addAmount]
  ✔ PopupMenuItem (line 542) → p.debts.edit  [key:edit]
  ✔ PopupMenuItem (line 543) → p.debts.delete  [key:delete]
  ✔ PopupMenuButton (line 532) → c.icon.filter  [icon:TwoToneIcons.filter]
  ✔ GestureDetector (line 599) → p.savings.cancelNew  [key:cancel]
  ✔ GestureDetector (line 479) → p.transfer.done  [key:completed]
  ✔ GestureDetector (line 669) → p.tx.pickAccount  [icon:TwoToneIcons.bank]
  ✔ GestureDetector (line 707) → p.savings.cancelNew  [key:cancel]
  ✔ GestureDetector (line 716) → p.savings.addConfirm  [key:add]
  ✔ GestureDetector (line 758) → p.tx.pickCurrency  [icon:TwoToneIcons.coins]
  ✔ InkWell (line 853) → p.savings.cash  [key:accountTypeCash]
  ✔ InkWell (line 896) → c.currenciesCount  [key:personalCurrenciesCount]
  ✔ InkWell (line 1025) → p.tx.pickCurrency  [icon:TwoToneIcons.coins]
  ✔ GestureDetector (line 1104) → p.savings.new  [key:newGoal]
```
## features/personal/presentation/pages/widgets/home_account_card.dart
```
  • _WalletCard (line 189) — label comes from the caller / record data
  • _WalletCard (line 241) — label comes from the caller / record data
  ✔ GestureDetector (line 301) → c.currenciesCount  [key:personalCurrenciesCount]
  ✔ GestureDetector (line 515) → c.icon.back  [icon:TwoToneIcons.arrowRight]
  ✔ GestureDetector (line 554) → s.shared.pagePrev  [icon:TwoToneIcons.arrowLeft]
```
## features/personal/presentation/pages/widgets/home_bottom_nav.dart
```
  • LiquidGlassNavBar (line 29) — label comes from the caller / record data
```
## features/personal/presentation/pages/widgets/home_header.dart
```
  ✔ GestureDetector (line 93) → c.icon.menu  [icon:TwoToneIcons.menu]
  • GestureDetector (line 157) — label comes from the caller / record data
  • GestureDetector (line 296) — label comes from the caller / record data
  ✔ ElevatedButton (line 588) → p.home.subscribe  [key:subscribeNow]
  ✔ GestureDetector (line 601) → c.close  [key:close]
```
## features/personal/presentation/pages/widgets/home_promo_banner.dart
```
  ✔ GestureDetector (line 277) → p.home.promo  [key:tapForMore]
```
## features/personal/presentation/pages/widgets/home_services_grid.dart
```
  • Checkbox (line 152) — label comes from the caller / record data
  • ListTile (line 142) — label comes from the caller / record data
  ✔ ElevatedButton (line 182) → p.savings.saveChanges  [key:saveChanges]
  ✔ GestureDetector (line 221) → c.icon.edit  [icon:Icons.edit_outlined]
  • GestureDetector (line 287) — service tiles: label key comes from the item (homeService* keys covered)
  • GestureDetector (line 419) — service tiles: label key comes from the item (homeService* keys covered)
```
## features/personal/presentation/pages/widgets/tree/tree_action_bar.dart
```
  ✔ _toolButton (line 59) → p.tree.search  [key:searchTree]
  ✔ _toolButton (line 64) → p.tree.zoomIn  [key:zoomIn]
  ✔ _toolButton (line 69) → p.tree.zoomOut  [key:zoomOut]
  ✔ _toolButton (line 74) → p.tree.fit  [key:fitToScreen]
  ✔ _toolButton (line 79) → p.tree.reset  [key:resetView]
  ✔ _toolButton (line 84) → p.tree.legend  [key:nodeLegend]
  ✔ _primaryAddButton (line 92) → p.tree.addItem  [key:addQuickNode]
  ✔ PopupMenuItem (line 105) → p.tree.expandAll  [key:expandAll]
  ✔ PopupMenuItem (line 106) → p.tree.collapseAll  [key:collapseAll]
  ✔ PopupMenuItem (line 108) → p.tree.exportPdf  [key:exportTreePdf]
  ✔ PopupMenuButton (line 94) → c.icon.more  [icon:Icons.more_vert]
  • InkWell (line 128) — label comes from the caller / record data
  ✔ InkWell (line 143) → c.icon.add  [icon:Icons.add]
  ✔ InkWell (line 195) → c.icon.close  [icon:Icons.close]
```
## features/personal/presentation/pages/widgets/tree/tree_canvas_page.dart
```
  ✔ TextButton (line 255) → p.savings.cancelNew  [key:cancel]
  ✔ FilledButton (line 256) → p.debts.delete  [key:delete]
  ✔ IconButton (line 361) → p.tree.settings  [key:treeSettings]
  • TreeNodeCard (line 402) — label comes from the caller / record data
```
## features/personal/presentation/pages/widgets/tree/tree_create_page.dart
```
  ✔ IconButton (line 117) → c.icon.back  [icon:Icons.arrow_back_ios_new]
  ✔ CurrencySelector (line 260) → p.tree.currency  [key:treeCurrency]
  • _selectableCard (line 319) — label comes from the caller / record data
  ✔ _selectableCard (line 344) → p.tree.startEmpty  [key:startEmpty]
  ✔ _selectableCard (line 353) → p.tree.useTemplate  [key:useTemplate]
  ✔ InkWell (line 374) → s.ai.markOne  [icon:Icons.check_circle]
  ✔ OutlinedButton (line 431) → p.tree.back  [key:back]
  ✔ TreePrimaryButton (line 444) → p.tree.create  [key:createTree]
```
## features/personal/presentation/pages/widgets/tree/tree_list_page.dart
```
  ✔ FloatingActionButton.extended (line 34) → c.icon.add  [icon:Icons.add]
  • TextButton (line 128) — label comes from the caller / record data
  • FilledButton (line 129) — label comes from the caller / record data
  • PopupMenuItem (line 142) — label comes from the caller / record data
  • PopupMenuItem (line 143) — label comes from the caller / record data
  ✔ PopupMenuButton (line 112) → c.icon.more  [icon:Icons.more_vert]
  • InkWell (line 75) — tree row (user names) → p.tree.node
```
## features/personal/presentation/pages/widgets/tree/tree_move_dialog.dart
```
  ✔ ListTile (line 65) → p.tree.moveRoot  [key:moveToRoot]
  ✔ TextButton (line 80) → p.savings.cancelNew  [key:cancel]
  • ListTile (line 96) — label comes from the caller / record data
```
## features/personal/presentation/pages/widgets/tree/tree_node_card.dart
```
  ✔ GestureDetector (line 106) → p.home.currency  [icon:Icons.expand_more]
  • GestureDetector (line 43) — label comes from the caller / record data
```
## features/personal/presentation/pages/widgets/tree/tree_node_details_sheet.dart
```
  • InkWell (line 180) — label comes from the caller / record data
```
## features/personal/presentation/pages/widgets/tree/tree_node_form_sheet.dart
```
  ✔ CurrencySelector (line 186) → p.tree.currency  [key:nodeCurrency]
  ✔ TreePrimaryButton (line 200) → p.budget.saveDetail  [key:save]
  • GestureDetector (line 221) — label comes from the caller / record data
  ✔ InkWell (line 260) → p.tree.selectParent  [key:selectParent]
  ✔ ListTile (line 333) → p.tree.moveRoot  [key:rootLevel]
  • ListTile (line 366) — label comes from the caller / record data
```
## features/personal/presentation/pages/widgets/tree/tree_search_overlay.dart
```
  ✔ IconButton (line 80) → c.icon.close  [icon:Icons.close]
  ✔ ListTile (line 93) → p.tree.reset  [icon:Icons.center_focus_strong]
```
## features/personal/presentation/pages/widgets/tree/tree_settings_sheet.dart
```
  ✔ CurrencySelector (line 102) → p.tree.currency  [key:treeCurrency]
  ✔ FilledButton.icon (line 114) → p.budget.saveDetail  [key:save]
```
## features/personal/presentation/pages/widgets/tree/tree_shared_widgets.dart
```
  • FilledButton (line 77) — label comes from the caller / record data
  ✔ TreePrimaryButton (line 161) → c.icon.add  [icon:Icons.add]
```
## features/personal/presentation/widgets/add_transaction_sheet.dart
```
  ✔ IconButton (line 466) → c.icon.close  [icon:TwoToneIcons.close]
  ✔ _ActionChip (line 517) → p.tx.methodCash  [key:payMethodCash]
  ✔ _ActionChip (line 531) → p.tx.methodBank  [key:payMethodBank]
  ✔ GestureDetector (line 546) → p.tx.pickAccount  [key:selectAccountFirst]
  ✔ InkWell (line 624) → c.currenciesCount  [key:personalCurrenciesCount]
  ✔ GestureDetector (line 697) → b.debts.currency  [key:currencyLabel]
  ✔ ListTile (line 770) → b.move.pickRow  [icon:TwoToneIcons.check]
  ✔ GestureDetector (line 835) → b.debts.currency  [key:currencyLabel]
  ✔ ListTile (line 889) → b.move.pickRow  [icon:TwoToneIcons.check]
  • GestureDetector (line 955) — label comes from the caller / record data
  ✔ IconButton (line 1026) → c.icon.close  [icon:Icons.close]
  ✔ GestureDetector (line 1002) → p.tx.fromBudget  [key:txWithdrawFromBudget]
  ✔ ListTile (line 1065) → p.tx.budgetRow  [key:txBudgetRemaining]
  ✔ ListTile (line 1134) → p.tx.budgetRow  [key:txCategoryRemaining]
  ✔ ElevatedButton (line 1172) → b.move.save  [key:addIncome]
  • GestureDetector (line 1198) — label comes from the caller / record data
```
## features/personal/presentation/widgets/chat_video_surface.dart
```
  ✔ FilledButton.icon (line 58) → p.chat.videoRetry  [text:إعادة المحاولة]
```
## features/personal/presentation/widgets/sara_smart_notifications_tile.dart
```
  • Switch (line 119) — label comes from the caller / record data
  ✔ InkWell (line 68) → p.sara.smartNotif  [key:saraSmartNotifTitle]
  ✔ GestureDetector (line 136) → p.sara.smartNotifTime  [key:saraSmartNotifTimeDesc]
  ✔ TextButton (line 187) → p.sara.smartNotifAuto  [key:saraSmartNotifUseAuto]
```
## features/personal/services/debt_reminder_service.dart
```
  ✔ OutlinedButton.icon (line 632) → p.debtAlarm.snooze  [key:debtAlarmSnooze]
  ✔ ElevatedButton.icon (line 634) → p.debtAlarm.done  [key:debtAlarmDone]
```
## features/printing/presentation/pages/print_page.dart
```
  ✔ TextButton (line 161) → p.savings.cancelNew  [key:cancel]
  ✔ FilledButton (line 165) → b.design.pickImage  [key:addLabel]
  ✔ IconButton (line 267) → c.icon.back  [icon:Icons.arrow_back_ios_new]
  • GestureDetector (line 512) — label comes from the caller / record data
  • GestureDetector (line 558) — label comes from the caller / record data
  • Switch (line 590) — label comes from the caller / record data
  ✔ TextButton (line 627) → p.savings.cancelNew  [key:cancel]
  ✔ FilledButton (line 631) → p.budget.saveDetail  [key:save]
  • GestureDetector (line 646) — label comes from the caller / record data
  ✔ IconButton (line 672) → b.print.addNetwork  [key:printAddNetwork]
  ✔ IconButton (line 679) → b.print.scan  [key:printScan]
  ✔ GestureDetector (line 721) → s.sub.planCard  [icon:Icons.check_circle_rounded]
  ✔ OutlinedButton.icon (line 837) → b.print.test  [key:printTest]
  ✔ FilledButton.icon (line 867) → b.print.now  [key:printNow]
```
## features/profile/presentation/pages/business_backup_page.dart
```
  ✔ TextButton (line 272) → s.backup.cancel  [text:إلغاء]
  ✔ FilledButton (line 276) → s.backup.confirmCreate  [text:حفظت الرمز، أنشئ النسخة]
  ✔ IconButton (line 313) → s.backup.reload  [icon:Icons.sync_rounded]
  ✔ FilledButton.icon (line 333) → s.backup.create  [text:إنشاء نسخة احتياطية]
  ✔ OutlinedButton.icon (line 339) → s.backup.restoreFile  [text:استعادة من ملف مشفّر]
  ✔ TextButton (line 368) → s.backup.rowSave  [text:حفظ]
  ✔ TextButton (line 374) → s.backup.rowShare  [text:مشاركة]
  ✔ TextButton (line 381) → s.backup.rowRestore  [text:استعادة]
  ✔ TextButton (line 387) → s.backup.rowDelete  [text:حذف]
  ✔ TextButton (line 460) → s.backup.cancel  [text:إلغاء]
  ✔ FilledButton (line 464) → s.backup.continue  [text:متابعة]
```
## features/profile/presentation/pages/profile_page.dart
```
  ✔ IconButton (line 453) → c.icon.back  [icon:HugeIcons.strokeRoundedArrowRight01]
  ✔ ListTile (line 494) → s.profile.businessSetup  [key:businessSetupTitle]
  ✔ _avatarActionBtn (line 720) → s.profile.avatarCamera  [icon:HugeIcons.strokeRoundedCamera01]
  ✔ _avatarActionBtn (line 732) → s.profile.avatarDelete  [icon:HugeIcons.strokeRoundedDelete01]
  ✔ IconButton (line 792) → s.profile.saveName  [key:profileSaveName]
  • GestureDetector (line 982) — label comes from the caller / record data
  ✔ IconButton (line 1205) → c.icon.copy  [icon:Icons.copy_rounded]
  ✔ GestureDetector (line 1232) → s.profile.addPhone  [key:profileAddPhone]
  ✔ GestureDetector (line 1472) → s.profile.back  [icon:HugeIcons.strokeRoundedArrowLeft01]
  ✔ GestureDetector (line 1393) → s.profile.subStatus  [key:profileSubStatus]
  ✔ ElevatedButton.icon (line 1667) → s.profile.setupBackup  [key:profileSetupBackup]
  • Switch (line 1724) — label comes from the caller / record data
  ✔ _settingsTile (line 1720) → s.profile.helpClicker  [key:helpClickerTitle]
  ✔ GestureDetector (line 1737) → s.profile.helpClickerDuration  [key:helpClickerPressDuration]
  ✔ _settingsTile (line 1803) → s.profile.customizeReports  [key:invDesignHubTitle]
  • Switch (line 1831) — label comes from the caller / record data
  ✔ _settingsTile (line 1827) → s.profile.allowNegative  [key:prefAllowNegative]
  ✔ ListTile (line 1875) → s.profile.helpClickerSeconds  [key:helpClickerSeconds]
  ✔ ListTile (line 1896) → s.profile.customSeconds  [key:custom]
  ✔ TextButton (line 1957) → p.savings.cancelNew  [key:cancel]
  ✔ ElevatedButton (line 1967) → s.shared.confirm  [key:confirm]
  ✔ _settingsTile (line 2034) → s.profile.resetAccount  [key:profileResetAccount]
  ✔ _settingsTile (line 2046) → s.profile.sessions  [key:profileSessionsTile]
  ✔ _settingsTile (line 2086) → s.profile.sessionTimeout  [key:sessionTimeout]
  • ListTile (line 2196) — session-timeout radio options: label from a list of durations
  • _DayNightToggle (line 2353) — label comes from the caller / record data
  ✔ InkWell (line 2264) → s.profile.theme  [key:themeAppearance]
  ✔ _settingsTile (line 2370) → s.profile.language  [key:language]
  ✔ _settingsTile (line 2398) → s.profile.currencies  [key:profileCustomizeCurrencies]
  • _settingsTile (line 2412) — business-currency tile: title from a helper → g.profile.bizCurrencies
  ✔ _settingsTile (line 2572) → s.profile.moneyFormat  [key:profileMoneyFormat]
  ✔ SwitchListTile (line 2693) → s.profile.thousandsSep  [key:profileThousandsSep]
  ✔ SwitchListTile (line 2727) → s.profile.decimals  [key:profileDecimals]
  ✔ ListTile (line 2809) → s.profile.arabic  [key:arabic]
  ✔ ListTile (line 2828) → s.profile.english  [text:English]
  ✔ InkWell (line 2865) → s.profile.back  [icon:HugeIcons.strokeRoundedArrowLeft01]
  • Switch (line 2925) — label comes from the caller / record data
  ✔ ElevatedButton.icon (line 3123) → s.profile.sendCode  [key:profileSendCode]
  ✔ ElevatedButton.icon (line 3139) → s.shared.confirm  [key:confirm]
  ✔ TextButton (line 3156) → p.savings.cancelNew  [key:cancel]
  ✔ ElevatedButton.icon (line 3267) → s.profile.changePassword  [key:changePasswordTitle]
  ✔ InkWell (line 3330) → s.profile.logout  [key:logout]
  ✔ TextButton (line 3412) → p.savings.cancelNew  [key:cancel]
  ✔ TextButton (line 3433) → s.profile.exit  [key:adminExit]
  ✔ TextButton (line 3548) → p.savings.cancelNew  [key:cancel]
  ✔ TextButton (line 3569) → s.profile.resetBtn  [key:profileResetBtn]
  ✔ TextButton (line 3679) → p.savings.cancelNew  [key:cancel]
  ✔ TextButton (line 3700) → s.profile.resetBtn  [key:profileResetBtn]
  ✔ ElevatedButton (line 3845) → s.profile.restart  [key:restartApp]
  ✔ GestureDetector (line 4131) → s.profile.theme  [icon:Icons.nightlight_round]
  ✔ GestureDetector (line 4470) → c.icon.close  [icon:Icons.close_rounded]
  ✔ IconButton (line 4516) → c.icon.clear  [icon:Icons.clear]
  ✔ _selectAllBtn (line 4544) → s.profile.selectAll  [key:profileSelectAll]
  ✔ _selectAllBtn (line 4555) → s.profile.clearSelection  [key:profileClearSelection]
  • Checkbox (line 4620) — label comes from the caller / record data
  • ListTile (line 4576) — label comes from the caller / record data
  ✔ ElevatedButton (line 4650) → p.savings.saveChanges  [key:saveChanges]
  • GestureDetector (line 4693) — label comes from the caller / record data
  ✔ ElevatedButton.icon (line 4935) → s.profile.renewSub  [key:subRenewSubscription]
  ✔ GestureDetector (line 4966) → s.profile.viewPlans  [key:subDetailsViewPlans]
  ✔ IconButton (line 5359) → c.icon.close  [icon:Icons.close]
  ✔ ElevatedButton.icon (line 5479) → s.profile.cropApply  [key:avatarCropApply]
```
## features/purchases/presentation/pages/barcode_scan_page.dart
```
  ✔ IconButton (line 79) → b.scan.torch  [key:purCameraTorch]
  ✔ FilledButton.tonal (line 111) → b.scan.manual  [key:purManualEntry]
```
## features/purchases/presentation/pages/purchase_invoice_page.dart
```
  ✔ IconButton (line 325) → c.icon.back  [icon:Icons.arrow_back_ios_new]
  ✔ FilledButton (line 432) → b.pur.issue  [key:purIssue]
```
## features/purchases/presentation/pages/purchase_success_dialog.dart
```
  ✔ IconButton (line 133) → b.sale.close  [key:saleClose]
  ✔ FilledButton.icon (line 157) → b.pur.newPurchase  [key:purNewPurchase]
  ✔ FilledButton.tonalIcon (line 181) → b.sale.more  [key:saleMoreAboutInvoice]
  ✔ _MoreRow (line 207) → b.sale.print  [key:salePrint]
  ✔ _MoreRow (line 214) → p.invoiceDoc.share  [key:saleShare]
  ✔ _MoreRow (line 221) → b.sale.view  [key:saleViewInvoice]
  • OutlinedButton.icon (line 257) — label comes from the caller / record data
  ✔ InkWell (line 283) → p.banks.pickerRow  [icon:Icons.chevron_left_rounded]
```
## features/purchases/presentation/widgets/purchase_items_section.dart
```
  ✔ IconButton (line 172) → b.sale.scan  [key:purScanWithCamera]
  ✔ TextButton (line 188) → p.savings.cancelNew  [key:cancel]
  ✔ FilledButton (line 192) → b.sale.searchBarcode  [key:saleSearch]
  ✔ TextButton (line 227) → p.savings.cancelNew  [key:cancel]
  ✔ FilledButton (line 231) → b.pur.createProduct  [key:purCreateNewProduct]
  ✔ InkWell (line 289) → b.sale.currency  [key:invCurrency]
  ✔ FilledButton (line 358) → b.sale.ok  [key:ok]
  ✔ TextButton (line 440) → p.savings.cancelNew  [key:cancel]
  ✔ FilledButton (line 444) → b.design.pickImage  [key:addLabel]
  • IconButton (line 462) — label comes from the caller / record data
  ✔ OutlinedButton.icon (line 522) → b.sale.chooseUnit  [key:saleChooseUnit]
  ✔ OutlinedButton.icon (line 534) → b.sale.chooseUnit  [icon:Icons.straighten_outlined]
  ✔ IconButton (line 572) → b.sale.scan  [key:purScanWithCamera]
  ✔ GestureDetector (line 599) → b.sale.expiry  [key:invProductExpiry]
  ✔ GestureDetector (line 618) → b.sale.category  [key:invCategory]
  ✔ CheckboxListTile (line 647) → b.sale.saveToStock  [key:purSaveToInventory]
  ✔ TextButton (line 658) → p.savings.cancelNew  [key:cancel]
  ✔ FilledButton (line 662) → b.sale.addItem  [key:saleAdd]
  ✔ TextButton.icon (line 762) → b.pur.addProducts  [key:purAddProducts]
  ✔ IconButton (line 863) → c.icon.close  [icon:Icons.close]
  • QtyStepper (line 878) — label comes from the caller / record data
  ✔ UnitLineField (line 905) → b.sale.lineUnit  [key:saleUnit]
  ✔ InkWell (line 1055) → s.drawer.branchSwitch  [icon:Icons.keyboard_arrow_down_rounded]
```
## features/purchases/presentation/widgets/purchase_payment_section.dart
```
  ✔ SaleField (line 85) → b.sale.payMode  [key:saleTapToSelectPayMode]
  • DebtSectionPicker (line 95) — label comes from the caller / record data
  ✔ SaleField (line 130) → b.sale.invoiceCurrency  [key:invChooseInvoiceCurrency]
  ✔ TextButton.icon (line 186) → b.sale.split  [key:saleSplitPayment]
  ✔ TextButton.icon (line 201) → b.sale.changeCurrency  [key:saleChangeInvoiceCurrency]
  ✔ TextButton (line 534) → b.sale.close  [key:saleClose]
  ✔ FilledButton (line 538) → b.sale.rateSave  [key:saleValue]
  ✔ SaleField (line 569) → b.sale.payAccount  [key:saleTapToSelectPayAccount]
  ✔ IconButton (line 618) → b.sale.removePay  [icon:Icons.remove_circle_outline]
  ✔ IconButton (line 674) → c.icon.edit  [icon:Icons.edit_outlined]
```
## features/purchases/presentation/widgets/purchase_supplier_section.dart
```
  ✔ TextButton (line 118) → p.savings.cancelNew  [key:cancel]
  ✔ FilledButton (line 123) → p.budget.saveDetail  [key:save]
  ✔ SaleField (line 177) → b.pur.pickSupplier  [key:purTapToSelectSupplier]
```
## features/reconciliation/presentation/pages/recon_archive_page.dart
```
  ✔ IconButton (line 168) → c.icon.back  [icon:Icons.arrow_back_ios_new]
  ✔ _SectionButton (line 192) → o.recon.bankCard  [key:reconBankCashTab]
  ✔ _SectionButton (line 204) → o.recon.inventoryCard  [key:reconInventoryTab]
  ✔ ActionChip (line 232) → o.emp.dateRange  [key:reconFilterRange]
  • _ArchiveRow (line 282) — label comes from the caller / record data
  • ChoiceChip (line 300) — label comes from the caller / record data
  • GestureDetector (line 336) — label comes from the caller / record data
  ✔ ReconTiltCard (line 400) → p.banks.pickerRow  [icon:Icons.account_balance_rounded]
```
## features/reconciliation/presentation/pages/recon_bank_pages.dart
```
  ✔ IconButton (line 109) → c.icon.back  [icon:Icons.arrow_back_ios_new]
  ✔ FilledButton.icon (line 240) → o.recon.start  [key:reconStartRecon]
  ✔ ReconTiltCard (line 189) → o.recon.accountCard  [key:reconCash]
  ✔ IconButton (line 374) → c.icon.back  [icon:Icons.arrow_back_ios_new]
  • _CurrencyTickRow (line 434) — label comes from the caller / record data
  ✔ FilledButton.icon (line 473) → o.recon.next  [key:reconNext]
  • Checkbox (line 564) — label comes from the caller / record data
  • InkWell (line 525) — label comes from the caller / record data
  ✔ IconButton (line 752) → c.icon.back  [icon:Icons.arrow_back_ios_new]
  ✔ FilledButton.icon (line 825) → o.recon.start  [key:reconCheckNow]
  ✔ IconButton (line 1153) → c.icon.back  [icon:Icons.arrow_back_ios_new]
  ✔ FilledButton.icon (line 1214) → o.recon.equalize  [key:reconEqualizeSystem]
```
## features/reconciliation/presentation/pages/recon_detail_page.dart
```
  ✔ IconButton (line 271) → c.icon.back  [icon:Icons.arrow_back_ios_new]
  ✔ IconButton (line 289) → o.recon.exportPdf  [key:reconExportPdf]
  ✔ FilledButton.icon (line 480) → o.recon.equalize  [key:reconEqNow]
```
## features/reconciliation/presentation/pages/recon_inventory_count_page.dart
```
  ✔ IconButton (line 412) → c.icon.back  [icon:Icons.arrow_back_ios_new]
  ✔ InkWell (line 444) → o.recon.scan  [icon:Icons.qr_code_scanner_rounded]
  ✔ FilledButton.icon (line 496) → o.recon.start  [key:reconRunMatch]
```
## features/reconciliation/presentation/pages/recon_inventory_pick_page.dart
```
  ✔ IconButton (line 216) → c.icon.back  [icon:Icons.arrow_back_ios_new]
  ✔ InkWell (line 257) → o.recon.scan  [icon:Icons.qr_code_scanner_rounded]
  ✔ InkWell (line 321) → o.recon.pickProduct  [icon:Icons.inventory_2_outlined]
  ✔ GestureDetector (line 389) → o.recon.pickCategory  [icon:Icons.category_outlined]
```
## features/reconciliation/presentation/pages/recon_inventory_result_page.dart
```
  ✔ IconButton (line 216) → c.icon.back  [icon:Icons.arrow_back_ios_new]
  ✔ FilledButton.icon (line 294) → o.recon.equalize  [key:reconEqualizeSystem]
```
## features/reconciliation/presentation/pages/recon_inventory_scope_page.dart
```
  ✔ IconButton (line 63) → c.icon.back  [icon:Icons.arrow_back_ios_new]
  • _ScopeSquare (line 85) — label comes from the caller / record data
  • GestureDetector (line 118) — label comes from the caller / record data
```
## features/reconciliation/presentation/pages/reconciliation_home_page.dart
```
  ✔ IconButton (line 28) → c.icon.back  [icon:Icons.arrow_back_ios_new]
  ✔ _MainCard (line 52) → o.recon.bankCard  [key:reconBankTitle]
  ✔ _MainCard (line 60) → o.recon.inventoryCard  [key:reconInventoryTitle]
  ✔ OutlinedButton.icon (line 71) → o.recon.archive  [key:reconArchive]
  ✔ ReconTiltCard (line 112) → o.recon.start  [key:reconStartRecon]
```
## features/reconciliation/presentation/widgets/recon_motion.dart
```
  ✔ OutlinedButton.icon (line 94) → o.recon.again  [key:reconAgain]
  ✔ FilledButton.icon (line 102) → o.recon.exit  [key:reconExitHome]
```
## features/reconciliation/presentation/widgets/recon_results.dart
```
  ✔ FilledButton.icon (line 546) → o.recon.confirm  [key:reconConfirmBtn]
```
## features/reconciliation/presentation/widgets/recon_scenes.dart
```
  ✔ IconButton (line 380) → c.icon.back  [icon:Icons.arrow_back_ios_new]
```
## features/reconciliation/presentation/widgets/recon_widgets.dart
```
  • GestureDetector (line 188) — label comes from the caller / record data
  • TextButton (line 291) — label comes from the caller / record data
  • FilledButton (line 298) — label comes from the caller / record data
```
## features/reports/presentation/pages/report_view_page.dart
```
  ✔ IconButton (line 1059) → c.icon.back  [icon:Icons.arrow_back_ios_new]
  ✔ GestureDetector (line 1080) → o.rep.pdf  [icon:Icons.picture_as_pdf_outlined]
  ✔ FilledButton (line 1205) → o.rep.viewReport  [key:repViewReport]
  ✔ RefPill (line 1295) → o.rep.showProducts  [key:repShowFewerProducts]
  ✔ InkWell (line 1626) → o.recon.pickProduct  [icon:Icons.inventory_2_outlined]
  ✔ GestureDetector (line 1932) → o.rep.bankPick  [key:repCurrenciesCount]
  ✔ GestureDetector (line 2013) → o.rep.accountPick  [key:repBalanceLbl]
  ✔ RefPill (line 2336) → o.rep.showSettlements  [key:repShowLessSettlements]
  ✔ InkWell (line 2741) → o.rep.reconRow  [key:repReconciled]
  ✔ GestureDetector (line 2860) → o.rep.viewDetails  [key:repViewDetails]
  ✔ RefPill (line 3536) → o.rep.breakdown  [key:repHideBreakdown]
```
## features/reports/presentation/pages/reports_hub_page.dart
```
  ✔ OutlinedButton (line 341) → p.savings.cancelNew  [key:cancel]
  ✔ FilledButton (line 365) → o.rep.viewReport  [key:repViewReport]
  ✔ IconButton (line 460) → c.icon.back  [icon:Icons.arrow_back_ios_new]
  ✔ GestureDetector (line 479) → p.reports.currency  [icon:Icons.currency_exchange_rounded]
  • ChoiceChip (line 607) — label comes from the caller / record data
  • ReportTileCard (line 906) — label comes from the caller / record data
```
## features/reports/presentation/widgets/report_integrity_card.dart
```
  ✔ OutlinedButton (line 79) → o.rep.ratesRefresh  [text:تحديث]
  ✔ OutlinedButton.icon (line 166) → p.chat.videoRetry  [text:إعادة المحاولة]
```
## features/reports/presentation/widgets/report_widgets.dart
```
  • GestureDetector (line 366) — report tiles: label from the report definition (keys covered)
  • GestureDetector (line 494) — report tiles: label from the report definition (keys covered)
  ✔ InkWell (line 915) → s.sub.planCard  [icon:Icons.check_circle_rounded]
  • GestureDetector (line 1278) — label comes from the caller / record data
  ✔ GestureDetector (line 1361) → p.banks.pickerRow  [icon:Icons.chevron_left_rounded]
  • GestureDetector (line 1473) — label comes from the caller / record data
  ✔ TextButton (line 1601) → o.rep.gotIt  [key:repProfitWhyOk]
  ✔ GestureDetector (line 1631) → c.icon.info  [icon:Icons.info_outline_rounded]
```
## features/returns/presentation/pages/invoice_picker_page.dart
```
  ✔ IconButton (line 114) → c.icon.back  [icon:Icons.arrow_back_ios_new]
  • _InvoiceResultTile (line 200) — label comes from the caller / record data
  ✔ ListTile (line 247) → p.banks.pickerRow  [icon:Icons.chevron_left_rounded]
```
## features/returns/presentation/pages/return_create_page.dart
```
  ✔ TextButton (line 244) → b.sale.close  [key:saleClose]
  ✔ FilledButton (line 249) → b.sale.rateSave  [key:saleValue]
  ✔ TextButton (line 305) → b.pay.negAlways  [key:payNegAlways]
  ✔ TextButton (line 309) → b.pay.negOnce  [key:payNegOnce]
  ✔ FilledButton (line 313) → b.pay.negCancel  [key:payNegCancel]
  ✔ TextButton (line 356) → p.savings.cancelNew  [key:cancel]
  • FilledButton (line 360) — label comes from the caller / record data
  ✔ IconButton (line 556) → c.icon.back  [icon:Icons.arrow_back_ios_new]
  ✔ _PickerField (line 569) → b.ret.chooseInvoice  [key:retChooseInvoice]
  ✔ TextButton (line 588) → b.ret.selectAll  [key:retSelectAll]
  ✔ _PickerField (line 607) → b.ret.chooseAccount  [key:retChooseAccount]
  ✔ IconButton (line 661) → c.icon.edit  [icon:Icons.edit_outlined]
  ✔ FilledButton (line 708) → b.ret.confirm  [key:retConfirm]
  • _Stepper (line 840) — label comes from the caller / record data
  • Checkbox (line 867) — label comes from the caller / record data
  ✔ InkWell (line 860) → b.ret.restock  [key:retRestockProduct]
  ✔ GestureDetector (line 959) → s.drawer.branchSwitch  [icon:Icons.keyboard_arrow_down_rounded]
  • GestureDetector (line 1019) — label comes from the caller / record data
```
## features/returns/presentation/pages/return_success_dialog.dart
```
  ✔ _Option (line 206) → b.sale.print  [key:retPrintInvoice]
  ✔ _Option (line 212) → b.sale.share  [key:retShareInvoice]
  ✔ _Option (line 218) → b.sale.view  [key:retViewInvoiceFull]
  ✔ IconButton (line 250) → b.sale.close  [key:saleClose]
  ✔ FilledButton.icon (line 290) → b.ret.newReturn  [key:retNewReturn]
  ✔ FilledButton.tonalIcon (line 321) → b.ret.invoiceDetails  [key:retInvoiceDetails]
  ✔ InkWell (line 357) → p.banks.pickerRow  [icon:Icons.chevron_left_rounded]
```
## features/returns/presentation/pages/return_view_page.dart
```
  ✔ IconButton (line 236) → c.icon.back  [icon:Icons.arrow_back_ios_new]
  • OutlinedButton.icon (line 361) — label comes from the caller / record data
```
## features/returns/presentation/pages/returns_page.dart
```
  ✔ IconButton (line 80) → c.icon.back  [icon:Icons.arrow_back_ios_new]
  ✔ _NewOptionCard (line 102) → b.ret.customer  [key:retCustomerReturn]
  ✔ _NewOptionCard (line 117) → b.ret.supplier  [key:retSupplierReturn]
  ✔ _KindChip (line 135) → b.tx.filterAll  [key:txAll]
  ✔ _KindChip (line 142) → b.ret.customer  [key:retCustomerReturn]
  ✔ _KindChip (line 149) → b.ret.supplier  [key:retSupplierReturn]
  • _ReturnTile (line 212) — label comes from the caller / record data
  • GestureDetector (line 250) — label comes from the caller / record data
  • GestureDetector (line 312) — label comes from the caller / record data
  ✔ ListTile (line 366) → p.banks.pickerRow  [icon:Icons.chevron_left_rounded]
```
## features/sales/presentation/pages/sale_invoice_page.dart
```
  ✔ IconButton (line 336) → c.icon.back  [icon:Icons.arrow_back_ios_new]
  ✔ IconButton (line 487) → p.chat.older  [icon:Icons.expand_less]
  ✔ SaleField (line 501) → b.sale.kind  [key:saleTapToSelect]
  ✔ SaleField (line 536) → b.sale.kind  [key:saleTapToSelect]
  ✔ FilledButton (line 607) → b.sale.issue  [key:saleIssue]
```
## features/sales/presentation/pages/sale_invoices_page.dart
```
  ✔ IconButton (line 58) → c.icon.back  [icon:Icons.arrow_back_ios_new]
  ✔ IconButton (line 72) → c.icon.add  [icon:Icons.add]
  • _InvoiceTile (line 117) — label comes from the caller / record data
  • ListTile (line 161) — customer picker row (customer names) → b.sale.productRow / row help
```
## features/sales/presentation/pages/sale_success_dialog.dart
```
  ✔ IconButton (line 136) → b.sale.close  [key:saleClose]
  ✔ FilledButton.icon (line 161) → b.sale.newSale  [key:saleNewSale]
  ✔ FilledButton.tonalIcon (line 185) → b.sale.more  [key:saleMoreAboutInvoice]
  ✔ _MoreRow (line 211) → b.sale.print  [key:salePrint]
  ✔ _MoreRow (line 218) → p.invoiceDoc.share  [key:saleShare]
  ✔ _MoreRow (line 225) → b.sale.view  [key:saleViewInvoice]
  • OutlinedButton.icon (line 263) — label comes from the caller / record data
  ✔ InkWell (line 289) → p.banks.pickerRow  [icon:Icons.chevron_left_rounded]
```
## features/sales/presentation/widgets/sale_customer_section.dart
```
  ✔ TextButton (line 123) → p.savings.cancelNew  [key:cancel]
  ✔ FilledButton (line 128) → p.budget.saveDetail  [key:save]
  ✔ SaleField (line 189) → b.sale.pickCustomer  [key:saleTapToSelectCustomer]
```
## features/sales/presentation/widgets/sale_field.dart
```
  ✔ GestureDetector (line 32) → s.drawer.branchSwitch  [icon:Icons.keyboard_arrow_down_rounded]
```
## features/sales/presentation/widgets/sale_items_section.dart
```
  ✔ TextButton (line 193) → p.savings.cancelNew  [key:cancel]
  ✔ FilledButton (line 197) → b.design.pickImage  [key:addLabel]
  ✔ InkWell (line 229) → b.sale.currency  [key:invCurrency]
  ✔ FilledButton (line 298) → b.sale.ok  [key:ok]
  ✔ OutlinedButton.icon (line 378) → b.sale.chooseUnit  [key:saleChooseUnit]
  ✔ OutlinedButton.icon (line 412) → b.sale.chooseUnit  [icon:Icons.straighten_outlined]
  ✔ IconButton (line 469) → b.sale.scan  [key:purScanWithCamera]
  ✔ GestureDetector (line 496) → b.sale.expiry  [key:invProductExpiry]
  ✔ GestureDetector (line 520) → b.sale.category  [key:invCategory]
  ✔ CheckboxListTile (line 549) → b.sale.saveToStock  [key:purSaveToInventory]
  ✔ TextButton (line 561) → p.savings.cancelNew  [key:cancel]
  ✔ FilledButton (line 565) → b.sale.addItem  [key:saleAdd]
  ✔ TextButton.icon (line 624) → b.sale.addProducts  [key:saleAddProducts]
  • ListTile (line 785) — product picker row (product names) → b.sale.productRow
  • ListTile (line 838) — label comes from the caller / record data
  ✔ IconButton (line 886) → c.icon.delete  [icon:Icons.delete_outline]
  • _QtyStepper (line 897) — label comes from the caller / record data
  ✔ _MiniField (line 906) → b.sale.priceMode  [key:saleFullPrice]
  ✔ UnitLineField (line 940) → b.sale.lineUnit  [key:saleUnit]
  • GestureDetector (line 960) — stock badge inside the product row → b.sale.productRow
  ✔ IconButton (line 1140) → p.tree.zoomOut  [icon:Icons.remove]
  ✔ IconButton (line 1168) → c.icon.add  [icon:Icons.add]
  ✔ InkWell (line 1253) → s.drawer.branchSwitch  [icon:Icons.keyboard_arrow_down_rounded]
```
## features/sales/presentation/widgets/sale_payment_section.dart
```
  ✔ SaleField (line 102) → b.sale.payMode  [key:saleTapToSelectPayMode]
  • DebtSectionPicker (line 112) — label comes from the caller / record data
  ✔ SaleField (line 151) → b.sale.invoiceCurrency  [key:invChooseInvoiceCurrency]
  ✔ TextButton.icon (line 216) → b.sale.split  [key:saleSplitPayment]
  ✔ TextButton.icon (line 243) → b.sale.changeCurrency  [key:saleChangeInvoiceCurrency]
  ✔ TextButton (line 662) → b.sale.close  [key:saleClose]
  ✔ FilledButton (line 669) → b.sale.rateSave  [key:saleValue]
  ✔ SaleField (line 708) → b.sale.payAccount  [key:saleTapToSelectPayAccount]
  ✔ IconButton (line 771) → b.sale.removePay  [icon:Icons.remove_circle_outline]
  ✔ IconButton (line 836) → b.sale.editRate  [key:saleEditRate]
  ✔ IconButton (line 989) → c.icon.back  [icon:Icons.arrow_back_rounded]
  • _BankRow (line 1020) — label comes from the caller / record data
  • _CurrencyRow (line 1039) — label comes from the caller / record data
  ✔ InkWell (line 1102) → p.tx.methodCash  [key:payMethodCash]
  ✔ InkWell (line 1187) → s.ai.markOne  [icon:Icons.check_circle]
```
## features/settings/presentation/pages/company_settings_page.dart
```
  ✔ TextButton.icon (line 125) → p.budget.saveDetail  [key:save]
  ✔ OutlinedButton.icon (line 222) → s.settings.uploadLogo  [key:settingsRaisingASlogan]
  ✔ TextButton (line 231) → s.settings.deleteLogo  [key:settingsDeleteLogo]
```
## features/settings/presentation/pages/currency_settings_page.dart
```
  • DropdownMenuItem (line 109) — label comes from the caller / record data
  ✔ DropdownButtonFormField (line 95) → b.debts.currency  [key:currencyLabel]
  ✔ TextButton (line 131) → p.savings.cancelNew  [key:cancel]
  ✔ ElevatedButton (line 132) → p.savings.addConfirm  [key:add]
  ✔ IconButton (line 158) → c.icon.add  [icon:Icons.add]
  • DropdownMenuItem (line 197) — label comes from the caller / record data
  • DropdownButton (line 192) — label comes from the caller / record data
  ✔ IconButton (line 262) → c.icon.delete  [icon:TwoToneIcons.delete]
```
## features/settings/presentation/pages/custom_fields_page.dart
```
  ✔ IconButton (line 47) → c.icon.add  [icon:Icons.add]
  • DropdownMenuItem (line 71) — label comes from the caller / record data
  ✔ DropdownButtonFormField (line 57) → s.settings.fieldResource  [key:settingsResources]
  ✔ IconButton (line 109) → c.icon.edit  [icon:TwoToneIcons.edit]
  ✔ IconButton (line 110) → c.icon.delete  [icon:TwoToneIcons.delete]
  • DropdownMenuItem (line 179) — label comes from the caller / record data
  ✔ DropdownButtonFormField (line 166) → s.settings.fieldType  [key:settingsFieldType]
  ✔ CheckboxListTile (line 183) → s.settings.fieldRequired  [key:settingsRequired]
  ✔ TextButton (line 194) → p.savings.cancelNew  [key:cancel]
  ✔ ElevatedButton (line 195) → p.budget.saveDetail  [key:save]
```
## features/settings/presentation/pages/customization_page.dart
```
  ✔ GestureDetector (line 29) → c.icon.back  [icon:TwoToneIcons.arrowRight]
```
## features/settings/presentation/pages/design_studio_page.dart
```
  ✔ SwitchListTile (line 105) → s.settings.showProductImages  [key:settingsShowProductImages]
  ✔ ElevatedButton (line 163) → s.settings.saveDesign  [key:settingsSaveChanges]
  • DropdownMenuItem (line 225) — label comes from the caller / record data
  • DropdownButtonFormField (line 211) — label comes from the caller / record data
  ✔ InkWell (line 231) → s.ai.markOne  [icon:Icons.check_circle]
  • Slider (line 262) — label comes from the caller / record data
  • OutlinedButton (line 267) — label comes from the caller / record data
  • OutlinedButton (line 275) — label comes from the caller / record data
  ✔ ElevatedButton (line 336) → s.settings.saveDesign  [key:settingsSaveReportSettings]
  ✔ InkWell (line 377) → s.ai.markOne  [icon:Icons.check_circle]
  ✔ OutlinedButton (line 436) → s.settings.uploadLogo  [key:settingsChangeLogo]
  ✔ ElevatedButton (line 457) → s.settings.saveDesign  [key:settingsPreservingVisualIdentity]
  • Slider (line 538) — label comes from the caller / record data
  ✔ ElevatedButton (line 544) → s.settings.saveDesign  [key:settingsSavePrintSettings]
  • DropdownMenuItem (line 583) — label comes from the caller / record data
  • DropdownButtonFormField (line 569) — label comes from the caller / record data
```
## features/settings/presentation/pages/email_logs_page.dart
```
  ✔ IconButton (line 34) → c.icon.refresh  [icon:TwoToneIcons.refresh]
```
## features/settings/presentation/pages/email_templates_page.dart
```
  ✔ IconButton (line 30) → c.icon.add  [icon:Icons.add]
  ✔ IconButton (line 73) → c.icon.delete  [icon:TwoToneIcons.delete]
  ✔ ElevatedButton (line 136) → s.settings.saveTemplate  [key:designStudioSaveTheTemplate]
  ✔ OutlinedButton (line 149) → p.savings.cancelNew  [key:cancel]
```
## features/settings/presentation/pages/files_page.dart
```
  ✔ IconButton (line 28) → c.icon.refresh  [icon:Icons.refresh]
  ✔ ElevatedButton.icon (line 42) → s.settings.uploadFile  [key:settingsUploadAFile]
  ✔ IconButton (line 93) → c.icon.delete  [icon:TwoToneIcons.delete]
```
## features/settings/presentation/pages/settings_page.dart
```
  ✔ ListTile (line 55) → c.icon.back  [icon:Icons.arrow_back_ios_new]
```
## features/settings/presentation/pages/tax_settings_page.dart
```
  ✔ TextButton (line 142) → p.savings.cancelNew  [key:cancel]
  ✔ ElevatedButton (line 143) → p.budget.saveDetail  [key:save]
  ✔ FloatingActionButton (line 180) → c.icon.add  [icon:Icons.add]
  • Switch (line 240) — label comes from the caller / record data
  ✔ IconButton (line 245) → c.icon.edit  [icon:TwoToneIcons.edit]
  ✔ IconButton (line 249) → c.icon.delete  [icon:TwoToneIcons.delete]
```
## features/subscription/presentation/pages/account_entry_page.dart
```
  ✔ FilledButton (line 145) → c.retry  [key:retry]
```
## features/subscription/presentation/pages/auto_renew_sheet.dart
```
  ✔ IconButton (line 251) → c.icon.back  [icon:Icons.arrow_back_ios_new]
  ✔ GestureDetector (line 350) → s.sub.autoRenewConsent  [key:autoRenewConsent]
  ✔ ElevatedButton (line 396) → s.sub.autoRenewEnable  [key:autoRenewConfirm]
  ✔ GestureDetector (line 237) → s.sub.autoRenewEnable  [key:autoRenewEnableTitle]
```
## features/subscription/presentation/pages/fyona_card_payment_page.dart
```
  ✔ IconButton (line 442) → c.icon.back  [icon:Icons.arrow_back_ios_new]
  ✔ GestureDetector (line 428) → s.sub.card  [key:subPayCardTitle]
  ✔ ElevatedButton (line 724) → s.sub.payButton  [icon:Icons.lock_outline]
```
## features/subscription/presentation/pages/payment_page.dart
```
  ✔ IconButton (line 137) → c.icon.back  [icon:Icons.arrow_back_ios_new]
  ✔ ElevatedButton (line 214) → s.sub.goPending  [key:subPayGoPending]
  • InkWell (line 500) — label comes from the caller / record data
  ✔ ElevatedButton (line 708) → s.sub.payNow  [key:subPayNow]
  ✔ InkWell (line 1054) → s.sub.expandCountry  [icon:Icons.keyboard_arrow_down]
  ✔ InkWell (line 1254) → c.icon.copy  [icon:Icons.copy_rounded]
  ✔ InkWell (line 1279) → s.sub.expandCountry  [icon:Icons.keyboard_arrow_up]
  ✔ GestureDetector (line 1519) → c.icon.close  [icon:Icons.close]
  ✔ InkWell (line 1565) → s.sub.uploadProof  [key:subPayUploadProof]
  ✔ ElevatedButton (line 1631) → s.sub.submit  [key:subPaySubmit]
```
## features/subscription/presentation/pages/phone_entry_page.dart
```
  ✔ IconButton (line 184) → c.icon.back  [icon:Icons.arrow_back_ios_new]
  ✔ ElevatedButton (line 324) → s.sub.savePhone  [key:subPhoneSaveNew]
  ✔ GestureDetector (line 373) → s.drawer.branchSwitch  [icon:Icons.keyboard_arrow_down_rounded]
  ✔ InkWell (line 684) → s.sub.planCard  [icon:Icons.check_circle_rounded]
```
## features/subscription/presentation/pages/plans_page.dart
```
  ✔ IconButton (line 182) → c.icon.back  [icon:Icons.arrow_back_ios_new]
  ✔ TextButton (line 213) → s.profile.viewPlans  [text:عرض جميع الباقات]
  ✔ CurrencySelector (line 217) → s.sub.planCurrency  [key:planCurrency]
  ✔ OutlinedButton.icon (line 257) → s.profile.logout  [key:plansLogout]
  ✔ TextButton (line 674) → p.savings.cancelNew  [key:cancel]
  ✔ TextButton (line 686) → s.shared.confirm  [key:confirm]
  ✔ ElevatedButton (line 833) → s.sub.trial  [key:plansTrialSubscribe]
  ✔ ElevatedButton (line 1146) → s.sub.upgrade  [key:plansUpgrade]
  ✔ InkWell (line 1477) → s.sub.planCard  [icon:Icons.check_circle_rounded]
```
## features/subscription/presentation/pages/subscription_invoice_screen.dart
```
  ✔ OutlinedButton.icon (line 356) → s.sub.invoiceDownload  [key:invoiceDownload]
  ✔ ElevatedButton.icon (line 369) → s.sub.invoiceShare  [key:invoiceShare]
  ✔ ElevatedButton.icon (line 388) → s.sub.startNow  [key:subInvoiceStartNow]
  ✔ ElevatedButton (line 472) → c.retry  [key:retry]
  ✔ TextButton (line 481) → s.profile.viewPlans  [key:subInvoiceBrowsePlans]
```
## features/subscription/presentation/pages/subscription_pending_page.dart
```
  ✔ TextButton.icon (line 305) → s.sub.retryUpload  [key:subPendingUploadRetry]
  ✔ TextButton (line 310) → s.sub.cancelRequest  [key:subPendingUploadCancel]
  ✔ ElevatedButton (line 398) → s.sub.resubmit  [key:subRejectedRetry]
```
## features/subscription/presentation/pages/subscription_rejected_page.dart
```
  ✔ ElevatedButton (line 77) → s.sub.resubmit  [key:subRejectedRetry]
```
## features/subscription/presentation/widgets/auto_renew_section.dart
```
  ✔ TextButton (line 108) → p.savings.cancelNew  [key:cancel]
  ✔ TextButton (line 112) → s.sub.autoRenewDisable  [key:autoRenewDisableConfirm]
  ✔ ElevatedButton.icon (line 310) → s.sub.completePayment  [text:إكمال الدفعة الأولى]
  ✔ OutlinedButton.icon (line 334) → s.sub.autoRenewDisable  [key:autoRenewDisable]
  ✔ OutlinedButton.icon (line 374) → s.sub.changeCard  [text:تغيير البطاقة]
```
## features/suggestions/presentation/pages/suggestions_page.dart
```
  ✔ ListTile (line 179) → s.sugg.image  [key:suggestionsImage]
  ✔ ListTile (line 195) → s.sugg.video  [key:suggestionsVideo]
  ✔ IconButton (line 465) → c.icon.add  [icon:TwoToneIcons.plus]
  • GestureDetector (line 506) — label comes from the caller / record data
  • GestureDetector (line 537) — label comes from the caller / record data
  ✔ IconButton (line 565) → s.sugg.stop  [icon:Icons.stop_circle_outlined]
  • GestureDetector (line 589) — label comes from the caller / record data
  ✔ GestureDetector (line 628) → s.sugg.send  [icon:Icons.arrow_forward_rounded]
  ✔ GestureDetector (line 683) → s.sugg.attach  [icon:Icons.add_photo_alternate_outlined]
  ✔ GestureDetector (line 698) → s.sugg.stop  [icon:Icons.stop_rounded]
  ✔ GestureDetector (line 751) → s.sugg.stop  [icon:Icons.stop_rounded]
  ✔ GestureDetector (line 824) → c.retry  [key:retry]
  • _TicketTile (line 883) — label comes from the caller / record data
  ✔ GestureDetector (line 909) → s.sugg.row  [key:suggestionsSuggestion]
  ✔ GestureDetector (line 1049) → s.sugg.new  [key:suggestionsCreateYourFirst]
  ✔ GestureDetector (line 1227) → p.savings.cancelNew  [key:cancel]
  ✔ GestureDetector (line 1245) → s.sugg.new  [key:suggestionsCreateNew]
  ✔ GestureDetector (line 1329) → c.retry  [key:retry]
  ✔ GestureDetector (line 1384) → c.icon.back  [icon:Icons.arrow_back_ios_new]
  ✔ GestureDetector (line 1418) → s.sugg.status  [key:suggestionsStatusLabel]
  • _StatusRow (line 1511) — label comes from the caller / record data
  ✔ GestureDetector (line 1537) → s.sugg.status  [key:suggestionsCurrentStatus]
  ✔ GestureDetector (line 1691) → c.retry  [key:retry]
  • _UserMessageBubble (line 1745) — label comes from the caller / record data
  • _AdminBubble (line 1757) — label comes from the caller / record data
  ✔ ListTile (line 1811) → s.sugg.copy  [key:actionCopy]
  • GestureDetector (line 1969) — label comes from the caller / record data
  • GestureDetector (line 2113) — label comes from the caller / record data
  • GestureDetector (line 2165) — label comes from the caller / record data
  • GestureDetector (line 2259) — label comes from the caller / record data
```
## features/suggestions/presentation/widgets/conversation_ui.dart
```
  ✔ IconButton (line 164) → c.icon.close  [icon:Icons.close]
```
## features/suggestions/presentation/widgets/suggestion_media_widgets.dart
```
  ✔ InkWell (line 24) → s.sugg.play  [icon:Icons.play_circle_fill]
  ✔ IconButton (line 172) → s.sugg.stop  [icon:Icons.stop_circle_outlined]
```
## shared/widgets/app_bar.dart
```
  ✔ IconButton (line 55) → c.icon.back  [icon:TwoToneIcons.arrowRight]
  ✔ IconButton (line 91) → c.icon.notifications  [icon:TwoToneIcons.bell]
  • GestureDetector (line 128) — label comes from the caller / record data
  ✔ IconButton (line 133) → s.appbar.profile  [icon:TwoToneIcons.userCircle]
```
## shared/widgets/app_drawer.dart
```
  ✔ ListTile (line 142) → p.banks.pickerRow  [icon:Icons.chevron_left_rounded]
  ✔ ListTile (line 172) → s.drawer.jobs  [text:التوظيف]
  • GestureDetector (line 436) — label comes from the caller / record data
  • GestureDetector (line 613) — label comes from the caller / record data
  • GestureDetector (line 637) — label comes from the caller / record data
  ✔ _drawerItem (line 773) → s.drawer.branches  [key:branchManagement]
  ✔ GestureDetector (line 931) → s.drawer.branchSwitch  [icon:Icons.keyboard_arrow_down_rounded]
  ✔ PopupMenuItem (line 973) → s.drawer.branchHeaders  [text:الفروع حق التجار]
  ✔ PopupMenuItem (line 1083) → s.sub.planCard  [icon:Icons.check_circle_rounded]
  ✔ _drawerItem (line 1228) → s.drawer.activateSub  [key:activateSubscription]
  ✔ _drawerItem (line 1243) → s.drawer.feedback  [key:appFeedbackSuggestions]
  ✔ TextButton (line 1336) → p.savings.cancelNew  [key:cancel]
  ✔ FilledButton (line 1340) → s.drawer.activateSub  [key:activateSubscription]
  ✔ _drawerItem (line 1295) → s.drawer.toBusiness  [key:switchToBusiness]
  ✔ _drawerItem (line 1435) → s.drawer.contact  [key:contactSupportTitle]
  ✔ _contactOption (line 1461) → s.drawer.whatsapp  [key:contactSupportWhatsApp]
  ✔ _contactOption (line 1492) → s.drawer.call  [key:contactSupportCall]
  • InkWell (line 1528) — label comes from the caller / record data
  • ListTile (line 1591) — label comes from the caller / record data
```
## shared/widgets/bank_detail/bank_detail_view.dart
```
  ✔ IconButton (line 199) → s.bank.export  [key:exportReport]
  ✔ TextButton.icon (line 308) → c.icon.refresh  [icon:Icons.refresh_rounded]
  ✔ InkWell (line 590) → c.icon.back  [icon:Icons.arrow_back_ios_new_rounded]
  ✔ GestureDetector (line 777) → s.bank.allCurrencies  [key:allCurrencies]
  • InkWell (line 843) — label comes from the caller / record data
  • InkWell (line 1464) — label comes from the caller / record data
  • _OptionCard (line 1850) — label comes from the caller / record data
  ✔ _Segment (line 1872) → s.bank.scopeCurrency  [key:bdvScopeCurrency]
  ✔ _Segment (line 1878) → s.bank.scopeAll  [key:bdvScopeAll]
  ✔ FilledButton.icon (line 1889) → s.bank.export  [key:exportReport]
  ✔ GestureDetector (line 1940) → s.sub.planCard  [icon:Icons.check_circle_rounded]
  • GestureDetector (line 2008) — label comes from the caller / record data
```
## shared/widgets/biometric_setup_dialog.dart
```
  ✔ ElevatedButton (line 148) → p.recurring.enable  [key:enable]
  ✔ TextButton (line 177) → s.shared.later  [key:later]
```
## shared/widgets/business_selection_sheet.dart
```
  • _Row (line 264) — label comes from the caller / record data
  ✔ FilledButton.tonalIcon (line 282) → c.icon.add  [icon:Icons.add]
  ✔ InkWell (line 310) → s.ai.markOne  [icon:Icons.check_circle]
```
## shared/widgets/business_widgets.dart
```
  ✔ IconButton (line 31) → c.icon.back  [icon:TwoToneIcons.arrowRight]
  ✔ IconButton (line 114) → c.icon.filter  [icon:TwoToneIcons.filter]
```
## shared/widgets/chat_unread_icon.dart
```
  ✔ IconButton (line 22) → s.appbar.chat  [icon:Icons.chat_bubble_outline]
```
## shared/widgets/confirm_dialog.dart
```
  ✔ TextButton (line 115) → p.savings.cancelNew  [key:cancel]
  ✔ TextButton (line 126) → s.shared.confirm  [key:confirm]
```
## shared/widgets/connectivity_widgets.dart
```
  ✔ ElevatedButton (line 348) → c.retry  [key:retry]
  ✔ TextButton (line 379) → s.shared.offlineHide  [key:offlineDialogHide]
```
## shared/widgets/currency_selector.dart
```
  ✔ GestureDetector (line 298) → c.icon.dropdown  [icon:TwoToneIcons.arrowDown]
  ✔ GestureDetector (line 358) → g.currency.closeSearch  [icon:TwoToneIcons.arrowUp]
  • GestureDetector (line 394) — label comes from the caller / record data
```
## shared/widgets/data_components.dart
```
  ✔ IconButton (line 107) → c.icon.back  [icon:TwoToneIcons.arrowRight]
  ✔ IconButton (line 120) → s.shared.pagePrev  [icon:TwoToneIcons.arrowLeft]
  • GestureDetector (line 192) — label comes from the caller / record data
```
## shared/widgets/detail_components.dart
```
  ✔ TextButton (line 148) → p.savings.cancelNew  [key:cancel]
  ✔ TextButton (line 152) → s.shared.confirm  [key:confirm]
```
## shared/widgets/empty_states.dart
```
  ✔ InkWell (line 147) → b.move.pickRow  [icon:TwoToneIcons.check]
```
## shared/widgets/expiring_banner.dart
```
  ✔ InkWell (line 84) → s.shared.renew  [key:renew]
```
## shared/widgets/interactive_card.dart
```
  • GestureDetector (line 29) — label comes from the caller / record data
```
## shared/widgets/liquid_glass_nav_bar.dart
```
  • _Tab (line 280) — label comes from the caller / record data
  • GestureDetector (line 501) — label comes from the caller / record data
```
## shared/widgets/maintenance_page.dart
```
  ✔ ElevatedButton.icon (line 255) → s.shared.backHome  [key:maintenanceModalBackToHome]
```
## shared/widgets/merchant_workspace_gate.dart
```
  ✔ FilledButton (line 87) → s.shared.merchantGateBack  [text:حسناً، العودة لحسابي]
  ✔ TextButton (line 111) → s.shared.merchantGateCheck  [text:التحقق من تجديد الاشتراك]
```
## shared/widgets/pdf_actions.dart
```
  ✔ _actionButton (line 43) → c.icon.print  [icon:Icons.print_outlined]
  ✔ _actionButton (line 50) → c.icon.share  [icon:Icons.share_outlined]
  ✔ _actionButton (line 57) → c.icon.download  [icon:Icons.download_outlined]
  • OutlinedButton (line 76) — label comes from the caller / record data
```
## shared/widgets/receipt/receipt_modal.dart
```
  ✔ GestureDetector (line 156) → c.icon.close  [icon:Icons.close]
  ✔ _ActionBtn (line 179) → p.budget.pdf  [text:PDF]
  ✔ _ActionBtn (line 186) → p.budget.saveDetail  [key:save]
  ✔ _ActionBtn (line 193) → p.budget.share  [key:share]
  • GestureDetector (line 228) — label comes from the caller / record data
```
## shared/widgets/receipt_overlay.dart
```
  • IconButton (line 128) — label comes from the caller / record data
```
## shared/widgets/receipt_preview_screen.dart
```
  ✔ IconButton (line 35) → p.savingsDetail.exportPdf  [key:exportPdf]
  ✔ IconButton (line 40) → p.debts.exportImage  [key:exportImage]
  ✔ IconButton (line 45) → c.print  [key:print]
  ✔ IconButton (line 50) → p.budget.share  [key:share]
  • Slider (line 65) — label comes from the caller / record data
```
## shared/widgets/sara_action_dispatcher.dart
```
  ✔ TextButton (line 372) → s.sara.ok  [text:حسناً]
```
## shared/widgets/sara_chat_page.dart
```
  ✔ TextButton (line 1274) → s.backup.cancel  [text:إلغاء]
  ✔ FilledButton (line 1275) → s.sara.confirm  [text:تأكيد التنفيذ]
  ✔ GestureDetector (line 2917) → s.drawer.branchSwitch  [icon:Icons.keyboard_arrow_down_rounded]
  ✔ GestureDetector (line 3004) → c.icon.close  [icon:Icons.close]
  • _SaraPressable (line 3127) — Sara suggestion chips: text comes from the server
  • InkResponse (line 3215) — label comes from the caller / record data
  ✔ GestureDetector (line 3226) → s.sara.send  [icon:Icons.send_rounded]
  ✔ GestureDetector (line 3331) → s.sugg.stop  [icon:Icons.stop_rounded]
  ✔ GestureDetector (line 3387) → s.sara.send  [icon:Icons.send_rounded]
  ✔ GestureDetector (line 3399) → s.sugg.stop  [icon:Icons.stop_rounded]
  ✔ GestureDetector (line 3421) → c.icon.close  [icon:Icons.close_rounded]
  • GestureDetector (line 3690) — label comes from the caller / record data
  • GestureDetector (line 3729) — Sara message bubbles inside ClickerQuiet → silent
  • GestureDetector (line 3816) — Sara message bubbles inside ClickerQuiet → silent
  ✔ GestureDetector (line 3960) → s.sara.play  [icon:Icons.pause_rounded]
  ✔ GestureDetector (line 4099) → s.sara.play  [icon:Icons.pause_rounded]
  ✔ TextButton (line 4312) → s.sara.refreshAccounts  [text:Refresh accounts]
  ✔ ElevatedButton.icon (line 4365) → s.sara.confirm  [text:Confirm]
  ✔ OutlinedButton.icon (line 4380) → s.sara.cancel  [text:Cancel]
  ✔ InkWell (line 4475) → s.sara.goToSection  [key:goToSection]
  • _SaraPressable (line 4511) — label comes from the caller / record data
  ✔ InkResponse (line 4550) → c.icon.copy  [icon:Icons.copy_rounded]
  ✔ GestureDetector (line 4435) → s.sugg.copy  [key:actionCopy]
  • GestureDetector (line 4623) — label comes from the caller / record data
  ✔ _SaraPressable (line 4751) → c.retry  [key:retry]
```
## shared/widgets/search_field.dart
```
  ✔ IconButton (line 54) → c.icon.filter  [icon:TwoToneIcons.filter]
```
## shared/widgets/stat_card.dart
```
  • GestureDetector (line 34) — generic stat card: label passed by the caller
```
## shared/widgets/subscription_gate.dart
```
  ✔ ElevatedButton (line 446) → s.shared.gateTrial  [key:gateSubscribeTrial]
  ✔ ElevatedButton (line 605) → s.shared.gateChoosePlan  [key:gateChoosePlan]
  ✔ ElevatedButton.icon (line 741) → c.icon.refresh  [icon:Icons.refresh_rounded]
  ✔ InkWell (line 961) → s.sub.planCard  [icon:Icons.check_circle_rounded]
```
## shared/widgets/trial_banner.dart
```
  ✔ InkWell (line 82) → p.home.subscribe  [key:subscribeNow]
```
## shared/widgets/trial_countdown_timer.dart
```
  ✔ GestureDetector (line 133) → c.icon.close  [icon:TwoToneIcons.close]
```
## shared/widgets/unsaved_exit_dialog.dart
```
  ✔ TextButton (line 25) → s.shared.unsavedKeep  [key:unsavedExitKeep]
  ✔ TextButton (line 33) → s.shared.unsavedDiscard  [key:unsavedExitDiscard]
  ✔ TextButton (line 41) → p.savings.cancelNew  [key:cancel]
```
