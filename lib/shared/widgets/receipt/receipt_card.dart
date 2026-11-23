import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/utils/currency_formatter.dart';
import 'receipt_data.dart';
import '../../../features/personal/presentation/providers/receipt_design_models.dart';

class ReceiptCard extends StatelessWidget {
  final ReceiptData data;
  final ReceiptDesignPreset? preset;

  ReceiptCard({super.key, required this.data, this.preset});

  ReceiptDesignPreset get _p => preset ?? ReceiptDesignPreset.defaults('default');

  @override
  Widget build(BuildContext context) {
    final cardWidth = MediaQuery.of(context).size.width > 420 ? 360.0 : MediaQuery.of(context).size.width * 0.86;
    final s = _p.fontSizeScale;

    return Container(
      width: cardWidth,
      padding: EdgeInsets.symmetric(horizontal: 28 * s, vertical: 32 * s),
      decoration: BoxDecoration(
        color: _p.backgroundColor,
        borderRadius: BorderRadius.circular(24 * s),
        boxShadow: [
          BoxShadow(color: Colors.black.withAlpha(16), blurRadius: 60 * s, offset: Offset(0, 20 * s)),
          BoxShadow(color: Colors.black.withAlpha(8), blurRadius: 24 * s, offset: Offset(0, 8 * s)),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (_p.showAccentBar) _buildAccentBar(s),
          if (_p.showAccentBar) SizedBox(height: 22 * s),
          _buildHeader(s),
          SizedBox(height: 28 * s),
          _buildDivider(s),
          SizedBox(height: 24 * s),
          _buildAmount(s),
          SizedBox(height: 28 * s),
          if (_p.showSender || _p.showReceiver) _buildDivider(s),
          if (_p.showSender || _p.showReceiver) SizedBox(height: 22 * s),
          if (data.referenceNumber != null && _p.showReference) ...[
            _buildInfoRow(AppLocalizations.t('referenceNumber'), data.referenceNumber!, s),
            SizedBox(height: 14 * s),
          ],
          if (_p.showSender && (data.senderName != null || data.senderAccount != null)) ...[
            _buildSenderSection(s),
            if (_p.showReceiver && (data.receiverName != null || data.receiverAccount != null)) SizedBox(height: 10 * s),
          ],
          if (_p.showReceiver && (data.receiverName != null || data.receiverAccount != null))
            _buildReceiverSection(s),
          if (_p.showDetails && data.details.isNotEmpty) ...[
            SizedBox(height: 20 * s),
            _buildDivider(s),
            SizedBox(height: 18 * s),
            ...data.details.map((d) => Padding(
              padding: EdgeInsets.only(bottom: 10 * s),
              child: _buildInfoRow(d.label, d.value, s),
            )),
          ],
          if (_p.showFooter) ...[
            SizedBox(height: 24 * s),
            _buildFooter(s),
          ],
        ],
      ),
    );
  }

  Widget _buildAccentBar(double s) {
    return Container(
      width: 48 * s, height: 3.5,
      decoration: BoxDecoration(
        color: _p.accentBarColor,
        borderRadius: BorderRadius.circular(4 * s),
      ),
    );
  }

  Widget _buildHeader(double s) {
    return Column(
      children: [
        if (_p.showBrandLogo)
          _p.logoBytes != null
              ? ClipRRect(
                  borderRadius: BorderRadius.circular(14 * s),
                  child: Image.memory(_p.logoBytes!, width: 50 * s, height: 50 * s, fit: BoxFit.cover),
                )
              : ClipRRect(
                  borderRadius: BorderRadius.circular(14 * s),
                  child: Image.asset('assets/images/logo.png', width: 50 * s, height: 50 * s, fit: BoxFit.cover),
                ),
        if (_p.showBrandLogo) SizedBox(height: 14 * s),
        Text(_p.brandName,
          style: TextStyle(fontFamily: 'Cairo', fontSize: 16 * s, fontWeight: FontWeight.w800, color: _p.primaryColor, letterSpacing: 4.5 * s),
        ),
        SizedBox(height: 4 * s),
        Text(data.dateTime,
          style: TextStyle(fontFamily: 'Cairo', fontSize: 11 * s, color: _p.secondaryTextColor),
        ),
      ],
    );
  }

  Widget _buildAmount(double s) {
    return Column(
      children: [
        Text(data.title,
          style: TextStyle(fontFamily: 'Cairo', fontSize: 11 * s, fontWeight: FontWeight.w600, color: _p.secondaryTextColor, letterSpacing: 0.5 * s),
        ),
        SizedBox(height: 10 * s),
        Text('${fmtNum(data.amount)} ${data.currencySymbol}',
          style: TextStyle(fontFamily: 'Cairo', fontSize: 34 * s, fontWeight: FontWeight.w800, color: _p.amountColor, height: 1.1),
          textDirection: ui.TextDirection.ltr,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _buildDivider(double s) {
    return Container(height: 1, color: _p.dividerColor);
  }

  Widget _buildSenderSection(double s) {
    return _buildPartySection(
      icon: Icons.arrow_upward,
      iconColor: _p.dangerColor,
      label: AppLocalizations.t('statementPeriodFrom'),
      name: data.senderName,
      account: data.senderAccount,
      s: s,
    );
  }

  Widget _buildReceiverSection(double s) {
    return _buildPartySection(
      icon: Icons.arrow_downward,
      iconColor: _p.successColor,
      label: AppLocalizations.t('statementPeriodTo'),
      name: data.receiverName,
      account: data.receiverAccount,
      s: s,
    );
  }

  Widget _buildPartySection({
    required IconData icon,
    required Color iconColor,
    required String label,
    String? name,
    String? account,
    required double s,
  }) {
    return Container(
      padding: EdgeInsets.all(14 * s),
      decoration: BoxDecoration(
        color: _p.cardBackground,
        borderRadius: BorderRadius.circular(14 * s),
        border: Border.all(color: _p.dividerColor.withAlpha(180), width: 0.5),
      ),
      child: Row(
        children: [
          Container(
            width: 32 * s, height: 32 * s,
            decoration: BoxDecoration(
              color: iconColor.withAlpha(20),
              borderRadius: BorderRadius.circular(10 * s),
            ),
            child: Icon(icon, size: 16 * s, color: iconColor),
          ),
          SizedBox(width: 12 * s),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                  style: TextStyle(fontFamily: 'Cairo', fontSize: 10 * s, fontWeight: FontWeight.w700, color: _p.secondaryTextColor),
                ),
                SizedBox(height: 2 * s),
                if (name != null)
                  Text(name,
                    style: TextStyle(fontFamily: 'Cairo', fontSize: 13 * s, fontWeight: FontWeight.w600, color: _p.textColor),
                  ),
                if (account != null)
                  Text(account,
                    style: TextStyle(fontFamily: 'Cairo', fontSize: 11 * s, color: _p.secondaryTextColor),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoRow(String label, String value, double s) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
          style: TextStyle(fontFamily: 'Cairo', fontSize: 11 * s, color: _p.secondaryTextColor),
        ),
        SizedBox(width: 12 * s),
        Expanded(
          child: Text(value,
            textAlign: TextAlign.end,
            softWrap: true,
            style: TextStyle(fontFamily: 'Cairo', fontSize: 11 * s, fontWeight: FontWeight.w600, color: _p.textColor),
          ),
        ),
      ],
    );
  }

  Widget _buildFooter(double s) {
    return Column(
      children: [
        _buildDivider(s),
        SizedBox(height: 14 * s),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Flexible(
              child: Text(_p.footerText,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontFamily: 'Cairo', fontSize: 9 * s, fontWeight: FontWeight.w600, color: _p.secondaryTextColor.withAlpha(180)),
              ),
            ),
            SizedBox(width: 8 * s),
            Flexible(
              child: Text(data.dateTime,
                textAlign: TextAlign.end,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontFamily: 'Cairo', fontSize: 9 * s, color: _p.secondaryTextColor.withAlpha(200)),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
