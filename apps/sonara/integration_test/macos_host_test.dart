import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.sonara/host');
  String? firstFingerprint;

  testWidgets('macOS host exposes sources and starts a LAN session', (
    tester,
  ) async {
    addTearDown(() async => channel.invokeMethod<bool>('stop'));
    final sources = await channel.invokeMethod<List<dynamic>>('listSources');
    expect(sources, isNotEmpty);
    expect((sources!.first as Map)['pid'], 0);
    final started = await channel.invokeMapMethod<String, dynamic>('start', {
      'pid': 0,
      'systemAudio': true,
      'sourceLabel': 'System audio',
      'mode': 'synchronized',
      'profile': 'balanced',
    });
    expect(started?['active'], isTrue);
    Map<String, dynamic>? status;
    for (var attempt = 0; attempt < 100; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      status = await channel.invokeMapMethod<String, dynamic>('status');
      if ((status?['invitation'] as String? ?? '').isNotEmpty) break;
    }
    expect(status?['invitation'], startsWith('sonara1:'));
    final engine = File(
      '${File(Platform.resolvedExecutable).parent.path}/sonara_engine',
    );
    final recording = File(
      '${Directory.systemTemp.path}/sonara-mac-loopback-$pid.wav',
    );
    final secondRecording = File(
      '${Directory.systemTemp.path}/sonara-mac-loopback-$pid-2.wav',
    );
    final invitation = status!['invitation'] as String;
    final payload =
        jsonDecode(
              utf8.decode(
                base64Url.decode(
                  base64Url.normalize(invitation.substring('sonara1:'.length)),
                ),
              ),
            )
            as Map<String, dynamic>;
    firstFingerprint = payload['host_fingerprint'] as String;
    payload['endpoints'] = ['127.0.0.1:49812'];
    final loopbackInvitation =
        'sonara1:${base64Url.encode(utf8.encode(jsonEncode(payload))).replaceAll('=', '')}';
    final receiver = await Process.start(engine.path, [
      'receive',
      '--invitation',
      loopbackInvitation,
      '--output',
      recording.path,
    ]);
    final secondReceiver = await Process.start(engine.path, [
      'receive',
      '--invitation',
      loopbackInvitation,
      '--output',
      secondRecording.path,
    ]);
    await Future<void>.delayed(const Duration(seconds: 6));
    expect(
      (await channel.invokeMapMethod<String, dynamic>('status'))?['active'],
      isTrue,
    );
    final sound = await Process.start('/usr/bin/say', [
      '-r',
      '120',
      'Sonara Mac audio capture test. Sonara Mac audio capture test.',
    ]);
    final soundExit = await sound.exitCode.timeout(const Duration(seconds: 10));
    expect(soundExit, 0);
    await Future<void>.delayed(const Duration(seconds: 1));
    final live = await channel.invokeMapMethod<String, dynamic>('status');
    expect((live?['capture'] as Map)['sent_blocks'] as int, greaterThan(0));
    expect((live?['connected_devices'] as List).length, 2);
    expect(await channel.invokeMethod<bool>('stop'), isTrue);
    final receiverExit = await receiver.exitCode.timeout(
      const Duration(seconds: 10),
    );
    final secondExit = await secondReceiver.exitCode.timeout(
      const Duration(seconds: 10),
    );
    if (receiverExit != 0) {
      final error = await receiver.stderr
          .transform(SystemEncoding().decoder)
          .join();
      fail('Receiver exited $receiverExit: $error');
    }
    final report =
        jsonDecode(await receiver.stdout.transform(utf8.decoder).join())
            as Map<String, dynamic>;
    if (secondExit != 0) {
      final error = await secondReceiver.stderr
          .transform(SystemEncoding().decoder)
          .join();
      fail('Second receiver exited $secondExit: $error');
    }
    final secondReport =
        jsonDecode(await secondReceiver.stdout.transform(utf8.decoder).join())
            as Map<String, dynamic>;
    expect(report['packets_received'] as int, greaterThan(0));
    expect(report['rms'] as num, greaterThan(0));
    expect(secondReport['packets_received'] as int, greaterThan(0));
    expect(secondReport['rms'] as num, greaterThan(0));
    expect(await recording.length(), greaterThan(44));
    expect(await secondRecording.length(), greaterThan(44));
    await recording.delete();
    await secondRecording.delete();
    expect(
      (await channel.invokeMapMethod<String, dynamic>('status'))?['active'],
      isFalse,
    );
  });

  testWidgets('unavailable application source leaves the host idle', (
    tester,
  ) async {
    await expectLater(
      channel.invokeMapMethod<String, dynamic>('start', {
        'pid': 2000000000,
        'systemAudio': false,
        'sourceLabel': 'Unavailable application',
        'mode': 'synchronized',
        'profile': 'balanced',
      }),
      throwsA(isA<PlatformException>()),
    );
    final status = await channel.invokeMapMethod<String, dynamic>('status');
    expect(status?['active'], isFalse);
    expect(status?['error'], isNotEmpty);
  });

  testWidgets('selected audio process can stream to a receiver', (
    tester,
  ) async {
    addTearDown(() async => channel.invokeMethod<bool>('stop'));
    final speech = await Process.start('/usr/bin/say', [
      '-r',
      '90',
      List.filled(12, 'Selected application audio from Sonara.').join(' '),
    ]);
    addTearDown(() => speech.kill());
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final started = await channel.invokeMapMethod<String, dynamic>('start', {
      'pid': speech.pid,
      'systemAudio': false,
      'sourceLabel': 'Speech test process',
      'mode': 'synchronized',
      'profile': 'balanced',
    });
    expect(started?['active'], isTrue);
    Map<String, dynamic>? status;
    for (var attempt = 0; attempt < 100; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      status = await channel.invokeMapMethod<String, dynamic>('status');
      if ((status?['invitation'] as String? ?? '').isNotEmpty) break;
    }
    final invitation = status?['invitation'] as String? ?? '';
    expect(invitation, startsWith('sonara1:'));
    final payload =
        jsonDecode(
              utf8.decode(
                base64Url.decode(
                  base64Url.normalize(invitation.substring('sonara1:'.length)),
                ),
              ),
            )
            as Map<String, dynamic>;
    expect(payload['host_fingerprint'], firstFingerprint);
    payload['endpoints'] = ['127.0.0.1:49812'];
    final localInvitation =
        'sonara1:${base64Url.encode(utf8.encode(jsonEncode(payload))).replaceAll('=', '')}';
    final engine = File(
      '${File(Platform.resolvedExecutable).parent.path}/sonara_engine',
    );
    final recording = File(
      '${Directory.systemTemp.path}/sonara-selected-$pid.wav',
    );
    final receiver = await Process.start(engine.path, [
      'receive',
      '--invitation',
      localInvitation,
      '--output',
      recording.path,
    ]);
    await Future<void>.delayed(const Duration(seconds: 3));
    speech.kill();
    await speech.exitCode.timeout(const Duration(seconds: 5));
    Map<String, dynamic>? ended;
    for (var attempt = 0; attempt < 50; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      ended = await channel.invokeMapMethod<String, dynamic>('status');
      if (ended?['active'] == false) break;
    }
    expect(ended?['active'], isFalse);
    expect(ended?['error'], contains('selected application closed'));
    final exit = await receiver.exitCode.timeout(const Duration(seconds: 10));
    if (exit != 0) {
      fail(
        'Selected-process receiver exited $exit: '
        '${await receiver.stderr.transform(SystemEncoding().decoder).join()}',
      );
    }
    final report =
        jsonDecode(await receiver.stdout.transform(utf8.decoder).join())
            as Map<String, dynamic>;
    expect(report['packets_received'] as int, greaterThan(0));
    expect(report['rms'] as num, greaterThan(0));
    await recording.delete();
  });
}
