import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sonara/discovery.dart';

void main() {
  test('accepts a valid LAN announcement without device assumptions', () {
    final invitationPayload = base64Url
        .encode(
          utf8.encode(
            jsonEncode({
              'id': 'invite-123',
              'host_fingerprint': 'sha256:host-key',
            }),
          ),
        )
        .replaceAll('=', '');
    final host = DiscoveredHost.tryParse(
      utf8.encode(
        jsonEncode({
          'protocol': sonaraDiscoveryProtocol,
          'name': 'Living room PC',
          'invitation': 'sonara1:$invitationPayload',
        }),
      ),
      InternetAddress('192.168.1.20'),
    );

    expect(host, isNotNull);
    expect(host!.name, 'Living room PC');
    expect(host.address, '192.168.1.20');
    expect(host.invitation, 'sonara1:$invitationPayload');
    expect(host.invitationId, 'invite-123');
    expect(host.hostFingerprint, 'sha256:host-key');
  });

  test('ignores malformed, blank, and unrelated announcements', () {
    final sender = InternetAddress.loopbackIPv4;
    expect(DiscoveredHost.tryParse(utf8.encode('not json'), sender), isNull);
    expect(
      DiscoveredHost.tryParse(
        utf8.encode(
          jsonEncode({'protocol': sonaraDiscoveryProtocol, 'invitation': ''}),
        ),
        sender,
      ),
      isNull,
    );
    expect(
      DiscoveredHost.tryParse(
        utf8.encode(
          jsonEncode({
            'protocol': 'something-else',
            'invitation': 'sonara1:encoded',
          }),
        ),
        sender,
      ),
      isNull,
    );
  });
}
