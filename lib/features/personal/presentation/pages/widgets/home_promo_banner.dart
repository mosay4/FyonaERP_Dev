import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:fyona_flutter/core/config/app_config.dart';
import 'package:fyona_flutter/core/responsive/r_api.dart';
import 'package:fyona_flutter/core/network/dio_provider.dart';
import 'package:fyona_flutter/core/network/api_endpoints.dart';
import '../../../../../core/localization/app_localizations.dart';
import '../../../../../core/theme/app_colors.dart';
import '../../../../../shared/widgets/secure_image.dart';

/// Builds a cache-busting image URL for a banner (relative `/uploads/...`
/// paths get the API base prefix + a version query for fresh reloads).
String bannerImageUrl(String? url, dynamic updatedAt) {
  final raw = url?.trim() ?? '';
  if (raw.isEmpty) return '';
  final base = raw.startsWith('http') ? '' : _apiBase;
  final stamp = updatedAt?.toString().isNotEmpty == true ? '&v=${updatedAt}' : '';
  return '$base$raw${raw.contains('?') ? stamp : stamp.replaceFirst('&', '?')}';
}

String get _apiBase => AppConfig.apiHostUrl;

class HomePromoBanners extends ConsumerStatefulWidget {
  const HomePromoBanners({super.key});

  @override
  ConsumerState<HomePromoBanners> createState() => _HomePromoBannersState();
}

class _HomePromoBannersState extends ConsumerState<HomePromoBanners> with WidgetsBindingObserver {
  late PageController _pageCtrl;
  final ValueNotifier<int> _currentPage = ValueNotifier(0);
  Timer? _flipTimer;
  Timer? _refreshTimer;
  List<Map<String, dynamic>> _apiBanners = [];

  /// Internal-storage mirror of the last banners received while online, so a
  /// cold offline launch still shows them.
  static const _cacheKey = 'home_promo_banners_v1';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pageCtrl = PageController(viewportFraction: 0.88);
    // Show the cached banners instantly, then refresh from the network when
    // available (which also re-caches, so admin changes propagate).
    _loadCachedBanners();
    _loadBanners();
    _refreshTimer = Timer.periodic(const Duration(seconds: 60), (_) => _loadBanners());
  }

  /// Duration (seconds) the banner at [index] must stay visible, from its own
  /// admin-configured `carousel_seconds` (default 4 when missing/invalid).
  int _flipSecondsFor(int index) {
    if (_apiBanners.isEmpty) return 4;
    final s = (_apiBanners[index % _apiBanners.length]['carousel_seconds'] as num?)?.toInt();
    return (s != null && s > 0) ? s : 4;
  }

  /// Arms a one-shot flip for the CURRENTLY visible banner: it stays on
  /// screen for exactly its own duration, then advances. Re-armed on every
  /// page change (auto or manual swipe), so each banner always gets its full
  /// configured time — never a fixed global interval.
  void _scheduleFlip() {
    _flipTimer?.cancel();
    if (_apiBanners.isEmpty || !_pageCtrl.hasClients) return;
    final secs = _flipSecondsFor(_currentPage.value);
    _flipTimer = Timer(Duration(seconds: secs), () {
      if (!mounted || !_pageCtrl.hasClients || _apiBanners.isEmpty) return;
      final count = _apiBanners.length;
      final next = (_currentPage.value + 1) % count;
      _pageCtrl.animateToPage(next,
          duration: const Duration(milliseconds: 400), curve: Curves.easeInOut);
    });
  }

  void _scheduleFlipSoon() {
    // The controller has no clients until the first frame is laid out.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scheduleFlip();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _loadBanners();
    }
  }

  Future<void> _loadCachedBanners() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_cacheKey);
      if (raw == null || raw.isEmpty || !mounted) return;
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        final cached = decoded
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
        if (cached.isNotEmpty && mounted) {
          setState(() => _apiBanners = cached);
          _scheduleFlipSoon();
        }
      }
    } catch (_) {}
  }

  Future<void> _saveBannersCache(List<Map<String, dynamic>> banners) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_cacheKey, jsonEncode(banners));
    } catch (_) {}
  }

  Future<void> _loadBanners() async {
    try {
      final client = ref.read(apiClientProvider);
      final resp = await client.getSafe<Map<String, dynamic>>(ApiEndpoints.banners);
      final raw = resp.data?['banners'];
      final banners = raw is List
          ? raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
          : const <Map<String, dynamic>>[];
      // ALWAYS mirror what the server returns — even an empty list — so when
      // the admin deletes every banner, the section collapses to nothing.
      await _saveBannersCache(banners);
      if (mounted) {
        setState(() => _apiBanners = banners);
        _scheduleFlipSoon();
      }
    } catch (_) {
      // Network error: leave the previously known (or cached) banners in
      // place; if we never loaded any, render nothing (never show built-in
      // placeholder cards).
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _flipTimer?.cancel();
    _refreshTimer?.cancel();
    _pageCtrl.dispose();
    _currentPage.dispose();
    super.dispose();
  }

  Color _parseColor(String? hex) {
    if (hex == null || hex.isEmpty) return AppColors.primary;
    return Color(int.parse(hex.replaceFirst('#', '0xFF')));
  }

  @override
  Widget build(BuildContext context) {
    // No banners from the admin → render nothing (zero height) so the space is
    // removed entirely and the layout flows naturally without empty padding.
    if (_apiBanners.isEmpty) return const SizedBox.shrink();

    // Spacing lives inside this widget so the whole block (including top/bottom
    // gaps) collapses to zero when there are no banners.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 12),
        SizedBox(
          height: 110,
          child: PageView.builder(
            controller: _pageCtrl,
            itemCount: _apiBanners.length,
            onPageChanged: (i) {
              _currentPage.value = i;
              // Manual swipe or auto flip landed on a new banner: restart the
              // timer so the newly visible banner gets its full duration.
              _scheduleFlip();
            },
            itemBuilder: (_, i) => Padding(
              padding: EdgeInsets.symmetric(horizontal: 6),
              child: _ApiBannerCard(
                banner: _apiBanners[i],
                colorStart: _parseColor(_apiBanners[i]['color_start']),
                colorEnd: _parseColor(_apiBanners[i]['color_end']),
              ),
            ),
          ),
        ),
        const SizedBox(height: 20),
      ],
    );
  }
}

// ── API Banner Card (from admin) ──
class _ApiBannerCard extends ConsumerStatefulWidget {
  final Map<String, dynamic> banner;
  final Color colorStart;
  final Color colorEnd;

  const _ApiBannerCard({
    required this.banner,
    required this.colorStart,
    required this.colorEnd,
  });

  @override
  ConsumerState<_ApiBannerCard> createState() => _ApiBannerCardState();
}

class _ApiBannerCardState extends ConsumerState<_ApiBannerCard> {
  bool _reportedView = false;

  String get _id => (widget.banner['id'] ?? '').toString();

  void _report(String kind) {
    try {
      final client = ref.read(apiClientProvider);
      final path = ApiEndpoints.bannerClick(_id);
      if (kind == 'click') {
        client.postSafe<Map<String, dynamic>>(path);
      } else if (kind == 'view') {
        client.postSafe<Map<String, dynamic>>(ApiEndpoints.bannerView(_id));
      } else if (kind == 'watch') {
        client.postSafe<Map<String, dynamic>>(ApiEndpoints.bannerWatch(_id));
      }
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    // Report a view once per banner lifecycle + track watch time.
    WidgetsBinding.instance.addPostFrameCallback((_) => _report('view'));
    Future.delayed(const Duration(seconds: 4), () {
      if (mounted) _report('watch');
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final titleKey = widget.banner['title_key'] as String? ?? '';
    final subtitleKey = widget.banner['subtitle_key'] as String? ?? '';
    // The admin editor saves the visible line as `text` (subtitle_key is a
    // legacy key rarely set) — fall back to the raw text so the admin-typed
    // line always appears. Raw text is shown as-is (not via localization).
    final rawText = (widget.banner['text'] as String?)?.trim() ?? '';
    final subtitle = subtitleKey.isNotEmpty
        ? l10n.translate(subtitleKey)
        : rawText;
    // The admin uploads images through the media endpoint which stores the
    // path in `media_url`; treat it as a first-class image source alongside
    // the classic `image_url` so uploaded banners actually appear.
    String? rawMedia = (widget.banner['image_url'] ?? widget.banner['media_url']) as String?;
    // If a fresh upload came back through upload-image it lands in image_url;
    // prefer whichever one actually points at a stable /uploads/ file.
    final mediaS = (widget.banner['media_url'] as String?)?.trim() ?? '';
    final imageS = (widget.banner['image_url'] as String?)?.trim() ?? '';
    if (imageS.isEmpty && mediaS.isNotEmpty) rawMedia = mediaS;
    if (imageS.isNotEmpty) rawMedia = imageS;
    final imageUrl = bannerImageUrl(rawMedia, widget.banner['updated_at']);
    final clickUrl = widget.banner['click_url'] as String?;
    // The backend reports `image_missing` when the referenced file no longer
    // exists on the server — show the branded gradient card instead of a
    // broken image, and never treat the device cache as the source of truth.
    final imageMissing = widget.banner['image_missing'] == true;
    final isVideoMedia = rawMedia != null &&
        RegExp(r'\.(mp4|webm|ogg|mov|m4v|m3u8)$', caseSensitive: false)
            .hasMatch(rawMedia);
    final hasImage = !imageMissing && imageUrl.isNotEmpty && !isVideoMedia;

    return GestureDetector(
      onTap: () async {
        HapticFeedback.lightImpact();
        _report('click');
        if (clickUrl != null && clickUrl.isNotEmpty) {
          try {
            await launchUrl(Uri.parse(clickUrl), mode: LaunchMode.externalApplication);
          } catch (_) {
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text(l10n.translate('cannotOpenLink'), style: TextStyle(fontFamily: 'Cairo')),
                backgroundColor: AppColors.warning,
              ));
            }
          }
        }
      },
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            // Always fill the admin-customized gradient behind the media so
            // the card matches the admin live preview exactly (previously the
            // gradient vanished whenever an image existed, hiding the
            // customized start/end colors).
            gradient: LinearGradient(
              colors: [widget.colorStart, widget.colorEnd],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(14),
            boxShadow: [BoxShadow(color: widget.colorStart.withAlpha(60), blurRadius: 16, offset: Offset(0, 6))],
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (hasImage)
                _BannerMedia(
                  banner: widget.banner,
                  url: imageUrl,
                  colorStart: widget.colorStart,
                  colorEnd: widget.colorEnd,
                ),
              Container(
                padding: EdgeInsets.all(16),
                decoration: BoxDecoration(
                  gradient: hasImage
                      ? LinearGradient(colors: [Colors.black.withAlpha(110), Colors.transparent], begin: Alignment.centerRight, end: Alignment.centerLeft)
                      : null,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (titleKey.isNotEmpty)
                            Text(l10n.translate(titleKey), style: TextStyle(
                              fontFamily: 'Cairo', fontSize: R.fontSize(context, 14),
                              fontWeight: FontWeight.w700, color: Colors.white,
                            )),
                          if (subtitle.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(subtitle, style: TextStyle(
                              fontFamily: 'Cairo', fontSize: R.fontSize(context, 11),
                              color: Colors.white.withAlpha(220),
                            )),
                          ],
                          if (clickUrl != null && clickUrl.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            Row(children: [
                              Icon(Icons.link, size: 12, color: Colors.white.withAlpha(200)),
                              const SizedBox(width: 4),
                              Text(l10n.translate('tapForMore'), style: TextStyle(
                                fontFamily: 'Cairo', fontSize: 10,
                                color: Colors.white.withAlpha(200),
                              )),
                            ]),
                          ],
                        ],
                      ),
                    ),
                    if (!hasImage) ...[
                      const SizedBox(width: 12),
                      Container(
                        width: 44, height: 44,
                        decoration: BoxDecoration(
                          color: Colors.white.withAlpha(38),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(Icons.campaign, color: Colors.white, size: 22),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── (No hardcoded fallback banners — the section renders nothing when the
//    admin has not created any banners, so deleted banners stay deleted.) ──


// Renders the banner media honoring the admin-set display mode (media_fit:
// cover | contain | fill) plus the saved crop box (media_x/y/w/h in % of the
// banner width) so uploaded art appears exactly where/how the admin placed it.
class _BannerMedia extends StatelessWidget {
  final Map<String, dynamic> banner;
  final String url;
  final Color colorStart;
  final Color colorEnd;
  const _BannerMedia({required this.banner, required this.url, required this.colorStart, required this.colorEnd});

  @override
  Widget build(BuildContext context) {
    final x = (banner['media_x'] as num?)?.toDouble() ?? 0;
    final y = (banner['media_y'] as num?)?.toDouble() ?? 0;
    final w = (banner['media_w'] as num?)?.toDouble();
    final h = (banner['media_h'] as num?)?.toDouble();
    final fit = _bannerFit(banner);
    if (w == null || h == null) {
      return SecureImage(
        url: url,
        fit: fit,
        errorBuilder: (_, __, ___) => Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: [colorStart, colorEnd], begin: Alignment.topLeft, end: Alignment.bottomRight),
          ),
          child: const Center(child: Icon(Icons.broken_image, color: Colors.white)),
        ),
      );
    }
    // NOTE: x/w are % of the *banner* width and y/h are % of the *banner*
    // height — exactly matching the admin interactive frame — so what the
    // admin positions is pixel-identical to what the user sees.
    return LayoutBuilder(
      builder: (context, cons) {
        final bw = cons.maxWidth;
        final bh = cons.maxHeight;
        if (!bw.isFinite || !bh.isFinite || bw <= 0 || bh <= 0) {
          return SecureImage(url: url, fit: fit);
        }
        return Stack(
          fit: StackFit.expand,
          alignment: Alignment.topLeft,
          children: [
            Positioned(
              left: x * bw / 100,
              top: y * bh / 100,
              width: w * bw / 100,
              height: h * bh / 100,
              child: ClipRect(
                child: SecureImage(
                  url: url,
                  fit: fit,
                  errorBuilder: (_, __, ___) => Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(colors: [colorStart, colorEnd], begin: Alignment.topLeft, end: Alignment.bottomRight),
                    ),
                    child: const Center(child: Icon(Icons.broken_image, color: Colors.white)),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

BoxFit _bannerFit(Map<String, dynamic> banner) {
  final f = (banner['media_fit'] as String?)?.toLowerCase();
  if (f == 'contain') return BoxFit.contain;
  if (f == 'fill') return BoxFit.fill;
  return BoxFit.cover;
}

