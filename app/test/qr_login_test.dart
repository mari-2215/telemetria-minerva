import 'package:flutter_test/flutter_test.dart';
import 'package:telemetria_minerva_app/qr_login.dart';

void main() {
  test('parses Minerva login QR', () {
    final value = MinervaLoginQr.parse(
      'minerva://login?server=http%3A%2F%2F192.168.1.20%3A8080'
      '&token=abcdefghijklmnopqrstuvwxyz1234567890'
      '&role=crew',
    );

    expect(value.server, 'http://192.168.1.20:8080');
    expect(value.token, 'abcdefghijklmnopqrstuvwxyz1234567890');
    expect(value.role, 'crew');
  });

  test('rejects non-Minerva QR', () {
    expect(
      () => MinervaLoginQr.parse('https://example.com'),
      throwsFormatException,
    );
  });

  test('rejects short token', () {
    expect(
      () => MinervaLoginQr.parse(
        'minerva://login?server=http%3A%2F%2Flocalhost%3A8080&token=123',
      ),
      throwsFormatException,
    );
  });
}
