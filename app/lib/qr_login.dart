class MinervaLoginQr {
  const MinervaLoginQr({
    required this.server,
    required this.token,
    this.role,
  });

  final String server;
  final String token;
  final String? role;

  static MinervaLoginQr parse(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null || uri.scheme != 'minerva' || uri.host != 'login') {
      throw const FormatException(
        'QR Code não pertence à Telemetria Minerva.',
      );
    }

    final server = uri.queryParameters['server']?.trim() ?? '';
    final token = uri.queryParameters['token']?.trim() ?? '';
    final role = uri.queryParameters['role']?.trim();
    final serverUri = Uri.tryParse(server);

    if (serverUri == null ||
        !serverUri.hasAuthority ||
        !const {'http', 'https'}.contains(serverUri.scheme)) {
      throw const FormatException('Servidor inválido no QR Code.');
    }
    if (token.length < 32) {
      throw const FormatException(
        'Credencial inválida ou incompleta no QR Code.',
      );
    }

    return MinervaLoginQr(
      server: serverUri.toString().replaceAll(RegExp(r'/$'), ''),
      token: token,
      role: role?.isEmpty == true ? null : role,
    );
  }
}
