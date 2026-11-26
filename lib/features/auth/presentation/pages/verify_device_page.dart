import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../../auth2/auth2_flow.dart';
import '../../auth2/auth2_service.dart';
import '../../auth2/auth2_strings.dart';
import '../../auth2/widgets/auth2_widgets.dart';

/// «Verify this device»: a new device with the right password chooses where
/// the code goes — the primary device in-app (default, free) or WhatsApp.
/// Never SMS for a new-device login.
class VerifyDevicePage extends ConsumerStatefulWidget {
  const VerifyDevicePage({super.key});

  @override
  ConsumerState<VerifyDevicePage> createState() => _VerifyDevicePageState();
}

class _VerifyDevicePageState extends ConsumerState<VerifyDevicePage> {
  String? _channel;
  bool _busy = false;
  String? _error;

  Future<void> _continue(String channel) async {
    final flow = ref.read(auth2FlowProvider);
    final v = flow.verification;
    if (v == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final challenge = await ref
          .read(auth2ServiceProvider)
          .loginVerifyStart(v.verificationId, channel);
      if (!mounted) return;
      ref.read(auth2FlowProvider.notifier).state =
          flow.copyWith(purpose: OtpPurpose.loginVerify, challenge: challenge);
      setState(() => _busy = false);
      context.go(RouteNames.authOtp);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = auth2ErrorTextOf(context, e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final v = ref.watch(auth2FlowProvider).verification;
    if (v == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.go(RouteNames.login);
      });
      return const Auth2Shell(child: SizedBox.shrink());
    }
    final canDevice = v.canUseDevice;
    final channel = _channel ?? (canDevice ? 'device' : 'whatsapp');
    final primaryName = v.primaryDevice?.label ?? '';
    return Auth2Shell(
      onBack: () => context.go(RouteNames.login),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Auth2Title(
            a2(context, 'verifyDeviceTitle'),
            subtitle: a2(context, 'verifyDeviceSubtitle'),
          ),
          if (canDevice)
            _OptionTile(
              key: const Key('option_device'),
              selected: channel == 'device',
              icon: Icons.phonelink_lock_rounded,
              title: a2(context, 'optPrimary'),
              subtitle: primaryName.isEmpty
                  ? a2(context, 'optPrimaryHintNoName')
                  : a2(context, 'optPrimaryHint', {'device': primaryName}),
              onTap: () => setState(() => _channel = 'device'),
            ),
          if (canDevice) const SizedBox(height: 10),
          _OptionTile(
            key: const Key('option_whatsapp'),
            selected: channel == 'whatsapp',
            icon: Icons.chat_rounded,
            title: a2(context, 'optWhatsapp'),
            subtitle: a2(context, 'optWhatsappHint'),
            onTap: () => setState(() => _channel = 'whatsapp'),
          ),
          if (_error != null) Auth2ErrorBox(_error!),
          const SizedBox(height: 20),
          Auth2PrimaryButton(
            key: const Key('verify_device_continue'),
            label: a2(context, 'continue'),
            loading: _busy,
            onPressed: () => _continue(channel),
          ),
        ],
      ),
    );
  }
}

class _OptionTile extends StatelessWidget {
  const _OptionTile({
    super.key,
    required this.selected,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final bool selected;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = selected ? AppColors.primary : AppColors.border;
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: accent, width: selected ? 1.8 : 1),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: AppColors.primary.withAlpha(selected ? 40 : 18),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(icon, color: AppColors.primary, size: 21),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          color: AppColors.textPrimary,
                        )),
                    Text(subtitle,
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 12,
                          color: AppColors.textSecondary,
                        )),
                  ],
                ),
              ),
              Icon(
                selected ? Icons.radio_button_checked : Icons.radio_button_off,
                color: selected ? AppColors.primary : AppColors.textTertiary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
