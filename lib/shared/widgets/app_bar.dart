import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_radius.dart';
import '../../core/router/route_names.dart';
import 'package:fyona_flutter/core/responsive/r_api.dart';
import 'two_tone_icon.dart';
import 'two_tone_icons.dart';

class AppBarWidget extends StatelessWidget implements PreferredSizeWidget {
  final String title;
  final bool showBack;
  final int? notifCount;
  final VoidCallback? onNotificationTap;
  final VoidCallback? onProfileTap;
  final VoidCallback? onMenuTap;
  final Widget? avatar;
  final List<Widget>? actions;
  final Widget? leading;
  final bool transparent;

  const AppBarWidget({
    super.key,
    required this.title,
    this.showBack = false,
    this.notifCount,
    this.onNotificationTap,
    this.onProfileTap,
    this.onMenuTap,
    this.avatar,
    this.actions,
    this.leading,
    this.transparent = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: transparent
          ? null
          : BoxDecoration(
              color: AppColors.background,
              border: Border(
                bottom: BorderSide(color: AppColors.border, width: 0.5),
              ),
            ),
      child: SafeArea(
        bottom: false,
        child: Row(
          children: [
            if (leading != null)
              leading!
            else
              IconButton(
                icon: TwoToneIcon(
                  data: showBack ? TwoToneIcons.arrowRight : TwoToneIcons.menu,
                  outlineColor: AppColors.textPrimary,
                  size: 22,
                ),
                onPressed: showBack
                    ? () {
                        if (GoRouter.of(context).canPop()) {
                          GoRouter.of(context).pop();
                        } else {
                          GoRouter.of(context).go(RouteNames.personalDashboard);
                        }
                      }
                    : onMenuTap,
              ),
             SizedBox(width: 4),
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: R.fontSize(context, 17),
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
                textAlign: TextAlign.center,
              ),
            ),
            if (notifCount != null)
              SizedBox(
                width: 40,
                height: 40,
                child: Stack(
                  children: [
                    Center(
                      child: IconButton(
                        icon: TwoToneIcon(
                          data: TwoToneIcons.bell,
                          outlineColor: AppColors.textPrimary,
                          size: 22,
                        ),
                        onPressed: onNotificationTap,
                      ),
                    ),
                    if (notifCount! > 0)
                      Positioned(
                        top: 4,
                        right: 4,
                        child: Container(
                          padding: EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.primary,
                            borderRadius: AppRadius.fullBorder,
                          ),
                          child: Text(
                            '$notifCount',
                            style: TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: R.fontSize(context, 10),
                              fontWeight: FontWeight.w800,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            if (avatar != null)
              GestureDetector(
                onTap: onProfileTap,
                child: avatar!,
              )
            else
              IconButton(
                icon: TwoToneIcon(
                  data: TwoToneIcons.userCircle,
                  outlineColor: AppColors.textPrimary,
                  size: 24,
                ),
                onPressed: onProfileTap,
              ),
            ...?actions,
          ],
        ),
      ),
    );
  }

  @override
  Size get preferredSize => const Size.fromHeight(56);
}

