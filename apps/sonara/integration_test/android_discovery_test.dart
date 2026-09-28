import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sonara/discovery.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Android receives and validates a local Sonara announcement', (
    tester,
  ) async {
    final discovery = SonaraDiscovery();
    final sender = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(() async {
      sender.close();
      await discovery.stop();
    });

    final found = Completer<DiscoveredHost>();
    final subscription = discovery.updates.listen((hosts) {
      if (hosts.isNotEmpty && !found.isCompleted) found.complete(hosts.first);
    });
    addTearDown(subscription.cancel);
    await discovery.start();

    final invitationPayload = base64Url
        .encode(
          utf8.encode(
            jsonEncode({
              'id': 'device-test',
              'host_fingerprint': 'test-fingerprint',
              'endpoints': ['127.0.0.1:49812'],
              'token': 'test-token',
            }),
          ),
        )
        .replaceAll('=', '');
    final invitation = 'sonara1:$invitationPayload';

    final announcement = utf8.encode(
      jsonEncode({
        'protocol': sonaraDiscoveryProtocol,
        'name': 'Dynamic test host',
        'invitation': invitation,
      }),
    );
    for (var attempt = 0; attempt < 10 && !found.isCompleted; attempt++) {
      sender.send(
        announcement,
        InternetAddress.loopbackIPv4,
        sonaraDiscoveryPort,
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    final host = await found.future.timeout(const Duration(seconds: 3));
    expect(host.name, 'Dynamic test host');
    expect(host.address, InternetAddress.loopbackIPv4.address);
    expect(host.invitation, invitation);
  });
}
