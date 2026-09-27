import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sonara/discovery.dart';

void main() {
  test('accepts a valid LAN announcement without device assumptions', () {
    final host = DiscoveredHost.tryParse(
      utf8.encode(
        jsonEncode({
          'protocol': sonaraDiscoveryProtocol,
          'name': 'Living room PC',
          'invitation': 'sonara1:encoded',
        }),
      ),
      InternetAddress('192.168.1.20'),
    );

    expect(host, isNotNull);
    expect(host!.name, 'Living room PC');
    expect(host.address, '192.168.1.20');
    expect(host.invitation, 'sonara1:encoded');
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
