import 'package:flutter_riverpod/flutter_riverpod.dart';

class AppEnvironment {
  final String name;
  final Uri apiBaseUrl;
  const AppEnvironment._(this.name, this.apiBaseUrl);
  factory AppEnvironment.parse(String name, String baseUrl) {
    final uri = Uri.tryParse(baseUrl);
    if (!{'development', 'test', 'production'}.contains(name) ||
        uri == null ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        !{'https', 'http'}.contains(uri.scheme) ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (name == 'production' && uri.scheme != 'https') ||
        !uri.path.endsWith('/')) {
      throw const FormatException('FLOW_ENV/API_BASE_URL inválidos');
    }
    return AppEnvironment._(name, uri);
  }
  factory AppEnvironment.fromDefines() => AppEnvironment.parse(
    const String.fromEnvironment('FLOW_ENV', defaultValue: 'development'),
    const String.fromEnvironment('API_BASE_URL'),
  );
}

final environmentProvider = Provider<AppEnvironment>(
  (ref) => AppEnvironment.fromDefines(),
);
