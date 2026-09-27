import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sonara/discovery.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.sonara/host');

  testWidgets(
    'Windows host discovers, starts, reports, and stops dynamically',
    (tester) async {
      addTearDown(() async {
        await channel.invokeMethod<bool>('stop');
      });
      final rawSources = await channel.invokeMethod<List<dynamic>>(
        'listSources',
      );
      expect(rawSources, isNotNull);
      expect(rawSources, isNotEmpty);

      final source = Map<dynamic, dynamic>.from(rawSources!.first as Map);
      final pid = source['pid'];
      expect(pid, isA<int>());
      expect(pid as int, greaterThan(0));
      expect(source['name'], isNotEmpty);
      expect(source['title'], isNotEmpty);

      final rawStart = await channel.invokeMethod<Map<dynamic, dynamic>>(
        'start',
        {'pid': pid, 'mode': 'synchronized', 'profile': 'balanced'},
      );
      expect(rawStart, isNotNull);
      final started = Map<dynamic, dynamic>.from(rawStart!);
      expect(started['active'], isTrue);
      expect(started['source_pid'], pid);
      expect(started['address'], matches(RegExp(r'^\d{1,3}(\.\d{1,3}){3}$')));
      expect(started['address'], isNot('YOUR_PC_IP'));

      Map<dynamic, dynamic> status = const {};
      for (var attempt = 0; attempt < 100; attempt++) {
        final rawStatus = await channel.invokeMethod<Map<dynamic, dynamic>>(
          'status',
        );
        status = Map<dynamic, dynamic>.from(rawStatus!);
        if ((status['invitation'] as String? ?? '').isNotEmpty) break;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(status['active'], isTrue);
      expect(status['invitation'], startsWith('sonara1:'));

      final discoverySocket = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(discoverySocket.close);
      final announcement = Completer<DiscoveredHost>();
      final discoverySubscription = discoverySocket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final datagram = discoverySocket.receive();
        if (datagram == null) return;
        final host = DiscoveredHost.tryParse(datagram.data, datagram.address);
        if (host != null && !announcement.isCompleted) {
          announcement.complete(host);
        }
      });
      addTearDown(discoverySubscription.cancel);
      for (
        var attempt = 0;
        attempt < 10 && !announcement.isCompleted;
        attempt++
      ) {
        discoverySocket.send(
          utf8.encode(sonaraDiscoveryProbe),
          InternetAddress.loopbackIPv4,
          sonaraDiscoveryPort,
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      final discovered = await announcement.future.timeout(
        const Duration(seconds: 3),
      );
      expect(discovered.invitation, status['invitation']);
      expect(discovered.name, isNotEmpty);

      expect(await channel.invokeMethod<bool>('stop'), isTrue);
      final rawStopped = await channel.invokeMethod<Map<dynamic, dynamic>>(
        'status',
      );
      expect(rawStopped!['active'], isFalse);
    },
  );
}
