import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../responsive/responsive_helper.dart';
import '../../shared/widgets/dots_loader.dart';

class AppLoading extends StatelessWidget {
  final String? message;
  final double? size;

  AppLoading({super.key, this.message, this.size});

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final iconSize = ResponsiveHelper.iconSize(size ?? 48, width);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          DotsLoader(size: (iconSize / 3.4).clamp(10.0, 16.0)),
          if (message != null) ...[
             SizedBox(height: 16),
            Text(
              message!,
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: ResponsiveHelper.fontSize(14, width),
                color: AppColors.textSecondary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class AppLoadingOverlay extends StatelessWidget {
  final Widget child;
  final bool isLoading;
  final String? message;

  const AppLoadingOverlay({
    super.key,
    required this.child,
    required this.isLoading,
    this.message,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        child,
        if (isLoading)
          Container(
            color: Colors.black38,
            child: AppLoading(message: message),
          ),
      ],
    );
  }
}

