import '../config/app_config.dart';

/// Uploads are served from the server root, not from the API route prefix.
String? serverImageUrl(String? value, {String? baseUrl}) {
  final raw = value?.trim() ?? '';
  if (raw.isEmpty) return null;
  final image = Uri.tryParse(raw);
  if (image == null) return null;
  final base = Uri.tryParse(baseUrl ?? AppConfig.effectiveApiBaseUrl);
  if (image.hasScheme) {
    return (image.scheme == 'http' || image.scheme == 'https') &&
            image.host.isNotEmpty
        ? image.toString()
        : null;
  }
  if (base == null || !base.hasAuthority) return null;
  return Uri.parse('${base.origin}/').resolveUri(image).toString();
}

String? versionedServerImageUrl(String? raw, String? version) {
  final url = serverImageUrl(raw);
  if (url == null || version == null || version.isEmpty) return url;
  final uri = Uri.parse(url);
  if (uri.queryParameters.keys.any((k) => k.toLowerCase().contains('signature'))) return url;
  return uri.replace(queryParameters: {...uri.queryParameters, 'v': version}).toString();
}
