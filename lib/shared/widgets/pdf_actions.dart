import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_radius.dart';
import '../../core/responsive/r_api.dart';

class PdfActions extends StatelessWidget {
  final String title;
  final List<int>? pdfBytes;
  final String? fileName;
  final VoidCallback? onPrint;
  final VoidCallback? onShare;
  final VoidCallback? onDownload;

  const PdfActions({
    super.key,
    required this.title,
    this.pdfBytes,
    this.fileName,
    this.onPrint,
    this.onShare,
    this.onDownload,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontFamily: 'Cairo',
            fontSize: R.font(context, 'body'),
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            _actionButton(
              context,
              icon: Icons.print_outlined,
              label: '?????',
              onTap: onPrint ?? () {},
            ),
            const SizedBox(width: 12),
            _actionButton(
              context,
              icon: Icons.share_outlined,
              label: '??????',
              onTap: onShare ?? () => _share(context),
            ),
            const SizedBox(width: 12),
            _actionButton(
              context,
              icon: Icons.download_outlined,
              label: '????? PDF',
              onTap: onDownload ?? () {},
            ),
          ],
        ),
      ],
    );
  }

  Widget _actionButton(
    BuildContext context, {
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: OutlinedButton(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 12),
          side: BorderSide(color: AppColors.border),
          shape: RoundedRectangleBorder(borderRadius: AppRadius.mdBorder),
        ),
        child: Column(
          children: [
            Icon(icon, size: 22, color: AppColors.textSecondary),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.font(context, 'caption'),
                fontWeight: FontWeight.w600,
                color: AppColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _share(BuildContext context) {
    if (pdfBytes != null && fileName != null) {
      Share.shareXFiles(
        [XFile.fromData(Uint8List.fromList(pdfBytes!), name: fileName)],
        subject: fileName,
      );
    }
  }
}

