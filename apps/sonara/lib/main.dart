import 'dart:async';
import 'dart:convert';
import 'dart:io'
    show InternetAddress, InternetAddressType, Platform, SocketException;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'discovery.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SonaraApp());
}

const ink = Color(0xFF17202A),
    indigo = Color(0xFF4057C8),
    mist = Color(0xFFF4F5F8);

class SonaraApp extends StatelessWidget {
  const SonaraApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Sonara',
    debugShowCheckedModeBanner: false,
    themeMode: ThemeMode.system,
    theme: theme(Brightness.light),
    darkTheme: theme(Brightness.dark),
    builder: (context, child) {
      final theme = Theme.of(context);
      final dark = theme.brightness == Brightness.dark;
      return AnnotatedRegion<SystemUiOverlayStyle>(
        value: (dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark)
            .copyWith(
              statusBarColor: theme.scaffoldBackgroundColor,
              systemNavigationBarColor: theme.colorScheme.surface,
              systemNavigationBarDividerColor: Colors.transparent,
              systemNavigationBarIconBrightness: dark
                  ? Brightness.light
                  : Brightness.dark,
              statusBarIconBrightness: dark
                  ? Brightness.light
                  : Brightness.dark,
              systemNavigationBarContrastEnforced: false,
            ),
        child: child ?? const SizedBox.shrink(),
      );
    },
    home: const SonaraShell(),
  );
}

ThemeData theme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final colors = ColorScheme.fromSeed(
    seedColor: indigo,
    brightness: brightness,
    surface: dark ? const Color(0xFF14171C) : Colors.white,
  );
  return ThemeData(
    colorScheme: colors,
    scaffoldBackgroundColor: dark ? const Color(0xFF101217) : mist,
    fontFamily: 'Inter',
    dividerColor: colors.outlineVariant.withValues(alpha: .35),
    appBarTheme: AppBarTheme(
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      backgroundColor: dark ? const Color(0xFF101217) : mist,
      foregroundColor: colors.onSurface,
      surfaceTintColor: Colors.transparent,
    ),
    navigationBarTheme: NavigationBarThemeData(
      elevation: 0,
      backgroundColor: colors.surface,
      indicatorColor: colors.primaryContainer,
      surfaceTintColor: Colors.transparent,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: colors.surfaceContainerHighest.withValues(alpha: .45),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: colors.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
  );
}

enum ListeningMode { synchronized, lowDelay }

enum BufferProfile { ultraLow, balanced, stable }

class SonaraShell extends StatefulWidget {
  const SonaraShell({super.key});
  @override
  State<SonaraShell> createState() => _SonaraShellState();
}

class _SonaraShellState extends State<SonaraShell> {
  static const receiverChannel = MethodChannel('dev.sonara/receiver');
  static const hostChannel = MethodChannel('dev.sonara/host');
  int page = 0;
  bool streaming = false;
  bool hostBusy = false;
  bool receiverBusy = false;
  bool statusRefreshInFlight = false;
  bool sourcesLoading = false;
  bool startWithWindows = false;
  int? selectedSourcePid;
  List<AppSource> sources = const [];
  Map<String, dynamic> hostStatus = const {};
  String? hostError;
  String receiverState = 'idle';
  Map<String, dynamic> receiverStatus = const {};
  SonaraDiscovery? discovery;
  StreamSubscription<List<DiscoveredHost>>? discoverySubscription;
  List<DiscoveredHost> discoveredHosts = const [];
  String? discoveryError;
  bool autoReconnect = true;
  bool autoConnectInFlight = false;
  Set<String> trustedFingerprints = const {};
  String? lastAutoInvitationId;
  String? connectedHostFingerprint;
  String? connectedHostName;
  String? manuallyDisconnectedFingerprint;
  Timer? statusTimer;
  ListeningMode mode = ListeningMode.lowDelay;
  BufferProfile profile = BufferProfile.balanced;
  static const labels = ['Session', 'Devices', 'Diagnostics', 'Settings'];
  static const icons = [
    Icons.graphic_eq,
    Icons.speaker_group_outlined,
    Icons.monitor_heart_outlined,
    Icons.settings_outlined,
  ];
  final outputs = [
    Output(
      'Current device',
      'Platform-selected output',
      true,
      'Timing not measured',
      null,
    ),
  ];

  @override
  void initState() {
    super.initState();
    if (defaultTargetPlatform == TargetPlatform.android) {
      statusTimer = Timer.periodic(
        const Duration(milliseconds: 100),
        (_) => refreshReceiverStatus(),
      );
      refreshReceiverStatus();
      if (Platform.isAndroid) {
        refreshTrustState();
        unawaited(startDiscovery());
      }
    } else if (defaultTargetPlatform == TargetPlatform.windows) {
      refreshSources();
      refreshHostStatus();
      refreshStartupSetting();
      statusTimer = Timer.periodic(
        const Duration(milliseconds: 100),
        (_) => refreshHostStatus(),
      );
    }
  }

  @override
  void dispose() {
    statusTimer?.cancel();
    unawaited(discoverySubscription?.cancel());
    final activeDiscovery = discovery;
    if (activeDiscovery != null) unawaited(activeDiscovery.stop());
    super.dispose();
  }

  Future<void> refreshReceiverStatus() async {
    if (statusRefreshInFlight) return;
    statusRefreshInFlight = true;
    try {
      final raw = await receiverChannel.invokeMethod<String>('status');
      if (raw == null || !mounted) return;
      final parsed = jsonDecode(raw) as Map<String, dynamic>;
      final nextState = parsed['state'] as String? ?? 'unknown';
      final becamePlaying =
          nextState == 'playing' && receiverState != 'playing';
      setState(() {
        receiverStatus = parsed;
        receiverState = nextState;
        outputs.first
          ..name =
              parsed['device_name'] as String? ??
              parsed['platform_model'] as String? ??
              'Current device'
          ..route = parsed['output_route'] as String? ?? 'Platform default'
          ..quality = receiverState == 'playing'
              ? 'Timestamp observed'
              : 'Timing not measured';
      });
      if (becamePlaying) unawaited(refreshTrustState());
    } catch (_) {
      // The native receiver is Android-only; the desktop UI remains usable.
    } finally {
      statusRefreshInFlight = false;
    }
  }

  Future<void> startDiscovery() async {
    if (receiverActive || receiverBusy) return;
    if (discovery != null) {
      discovery?.scan();
      return;
    }
    List<InternetAddress>? probeAddresses;
    try {
      final preparation = await receiverChannel
          .invokeMapMethod<String, dynamic>('ensureLocalNetworkAccess');
      final rawAddresses = preparation?['probe_addresses'];
      if (rawAddresses is List) {
        final parsed = rawAddresses
            .whereType<String>()
            .map(InternetAddress.tryParse)
            .whereType<InternetAddress>()
            .where((address) => address.type == InternetAddressType.IPv4)
            .toList();
        if (parsed.isNotEmpty) probeAddresses = parsed;
      }
    } on PlatformException {
      if (mounted) {
        setState(() {
          discoveryError = 'Sonara could not request local network access.';
        });
      }
      return;
    }
    if (!mounted) return;
    setState(() => discoveryError = null);
    final service = SonaraDiscovery(
      probeAddresses: probeAddresses,
      nativeScan: Platform.isAndroid ? scanAndroidNetwork : null,
    );
    discovery = service;
    discoverySubscription = service.updates.listen(
      (hosts) {
        if (!mounted) return;
        setState(() {
          discoveredHosts = hosts;
          discoveryError = null;
        });
        unawaited(maybeAutoConnect(hosts));
      },
      onError: (Object error) {
        if (mounted) {
          setState(() => discoveryError = discoveryErrorMessage(error));
        }
      },
    );
    try {
      await service.start();
    } catch (error) {
      if (mounted) {
        setState(() => discoveryError = discoveryErrorMessage(error));
      }
    }
  }

  Future<List<NativeDiscoveryDatagram>> scanAndroidNetwork() async {
    final raw = await receiverChannel.invokeListMethod<dynamic>(
      'scanLocalNetwork',
    );
    if (raw == null) return const [];
    final datagrams = <NativeDiscoveryDatagram>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      final data = entry['data'];
      final address = InternetAddress.tryParse('${entry['address'] ?? ''}');
      if (data is Uint8List && address != null) {
        datagrams.add(NativeDiscoveryDatagram(data: data, address: address));
      }
    }
    return datagrams;
  }

  Future<void> stopDiscovery() async {
    final activeDiscovery = discovery;
    discovery = null;
    discoveredHosts = const [];
    discoveryError = null;
    await discoverySubscription?.cancel();
    discoverySubscription = null;
    if (activeDiscovery != null) await activeDiscovery.stop();
    if (mounted) setState(() {});
  }

  String discoveryErrorMessage(Object error) {
    if (error is SocketException && error.osError?.errorCode == 1) {
      return 'Local network access is blocked. Allow Nearby devices for Sonara, then tap Scan again.';
    }
    return 'Could not scan this network. Check Wi-Fi and try again.';
  }

  String? validateInvitation(String? value) {
    final invitation = value?.trim() ?? '';
    if (invitation.isEmpty) return 'Enter an invitation first.';
    if (!invitation.startsWith('sonara1:')) {
      return 'This is not a Sonara invitation.';
    }
    final payload = _invitationPayload(invitation);
    if (payload == null ||
        payload['id'] is! String ||
        payload['host_fingerprint'] is! String ||
        payload['endpoints'] is! List ||
        payload['token'] is! String) {
      return 'This invitation is damaged or incomplete.';
    }
    return null;
  }

  Future<void> connectInvitation(
    Object? value, {
    bool trust = true,
    bool quiet = false,
  }) async {
    if (receiverBusy) return;
    final invitation = value is String ? value.trim() : '';
    final validation = validateInvitation(invitation);
    if (validation != null) {
      if (!quiet) showError(validation);
      return;
    }
    if (mounted) setState(() => receiverBusy = true);
    try {
      final started = await receiverChannel.invokeMethod<bool>('start', {
        'invitation': invitation,
        'trust': trust,
      });
      if (started != true) {
        if (!quiet) showError('Android did not start the receiver.');
        return;
      }
      connectedHostName = discoveredHosts
          .where((host) => host.invitation == invitation)
          .map((host) => host.name)
          .firstOrNull;
      connectedHostFingerprint = _invitationFingerprint(invitation);
      await stopDiscovery();
      if (!quiet) manuallyDisconnectedFingerprint = null;
      if (trust) await refreshTrustState();
      await refreshReceiverStatus();
    } on PlatformException catch (error) {
      if (!quiet) showError(error.message ?? 'Could not start receiver');
    } catch (error) {
      if (!quiet) showError('Could not start receiver: $error');
    } finally {
      if (mounted) setState(() => receiverBusy = false);
    }
  }

  Future<void> refreshTrustState() async {
    try {
      final raw = await receiverChannel.invokeMethod<Map<dynamic, dynamic>>(
        'trustState',
      );
      if (raw == null || !mounted) return;
      final fingerprints = (raw['fingerprints'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .toSet();
      setState(() {
        autoReconnect = raw['auto_reconnect'] as bool? ?? true;
        trustedFingerprints = fingerprints;
      });
      unawaited(maybeAutoConnect(discoveredHosts));
    } catch (_) {}
  }

  Future<void> setAutoReconnect(bool enabled) async {
    final applied = await receiverChannel.invokeMethod<bool>(
      'setAutoReconnect',
      {'enabled': enabled},
    );
    if (mounted) setState(() => autoReconnect = applied ?? enabled);
    if (enabled) unawaited(maybeAutoConnect(discoveredHosts));
  }

  Future<void> forgetTrusted(String fingerprint) async {
    await receiverChannel.invokeMethod<bool>('forgetTrusted', {
      'fingerprint': fingerprint,
    });
    await refreshTrustState();
  }

  Future<void> copyDiagnostics() async {
    final report = <String, dynamic>{
      'generated_at': DateTime.now().toUtc().toIso8601String(),
      'platform': defaultTargetPlatform.name,
      'session': defaultTargetPlatform == TargetPlatform.windows
          ? hostStatus
          : receiverStatus,
      'trusted_host_count': trustedFingerprints.length,
      'auto_reconnect': autoReconnect,
    };
    await Clipboard.setData(
      ClipboardData(text: const JsonEncoder.withIndent('  ').convert(report)),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Diagnostics copied to the clipboard.')),
    );
  }

  String get timingConfidence {
    if (defaultTargetPlatform == TargetPlatform.windows) {
      return streaming ? 'Awaiting receiver measurements' : 'Not measured';
    }
    if (receiverState != 'playing') return 'Not measured';
    final uncertainty = (receiverStatus['clock_uncertainty_ms'] as num?)
        ?.toDouble();
    if (uncertainty == null) return 'Clock measurement unavailable';
    if (uncertainty <= 2) return 'Clock synchronized';
    if (uncertainty <= 5) return 'Clock stable';
    return 'Clock settling';
  }

  String get timingExplanation {
    if (defaultTargetPlatform == TargetPlatform.windows) {
      return 'Receivers share one timestamped presentation timeline. Acoustic measurement is required to qualify speaker-to-speaker alignment.';
    }
    final route = receiverStatus['output_route_type'] as String? ?? 'output';
    return '$route · Network-clock confidence is measured live. Acoustic speaker delay is reported separately.';
  }

  Future<void> maybeAutoConnect(List<DiscoveredHost> hosts) async {
    if (!mounted || !autoReconnect || receiverActive || autoConnectInFlight) {
      return;
    }
    final suppressed = manuallyDisconnectedFingerprint;
    if (suppressed != null) {
      if (hosts.any((host) => host.hostFingerprint == suppressed)) return;
      manuallyDisconnectedFingerprint = null;
    }
    DiscoveredHost? candidate;
    for (final host in hosts) {
      if (trustedFingerprints.contains(host.hostFingerprint) &&
          host.invitationId != lastAutoInvitationId) {
        candidate = host;
        break;
      }
    }
    if (candidate == null) return;
    autoConnectInFlight = true;
    lastAutoInvitationId = candidate.invitationId;
    try {
      await connectInvitation(candidate.invitation, trust: false, quiet: true);
    } finally {
      autoConnectInFlight = false;
    }
  }

  Future<void> importInvitation() async {
    final invitation = await showDialog<String>(
      context: context,
      builder: (context) => InvitationDialog(validator: validateInvitation),
    );
    if (invitation != null && mounted) await connectInvitation(invitation);
  }

  Future<void> stopReceiver() async {
    if (receiverBusy) return;
    setState(() {
      receiverBusy = true;
      receiverState = 'stopping';
      manuallyDisconnectedFingerprint = connectedHostFingerprint;
      connectedHostFingerprint = null;
      connectedHostName = null;
    });
    try {
      final stopped = await receiverChannel.invokeMethod<bool>('stop');
      if (stopped != true) showError('The receiver did not stop.');
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await refreshReceiverStatus();
    } on PlatformException catch (error) {
      showError(error.message ?? 'Could not stop the receiver');
    } finally {
      if (mounted) setState(() => receiverBusy = false);
      unawaited(startDiscovery());
    }
  }

  String? _invitationFingerprint(String invitation) {
    final fingerprint = _invitationPayload(invitation)?['host_fingerprint'];
    return fingerprint is String && fingerprint.isNotEmpty ? fingerprint : null;
  }

  Map<String, dynamic>? _invitationPayload(String invitation) {
    try {
      final encoded = invitation.substring('sonara1:'.length);
      final decoded = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(encoded))),
      );
      return decoded is Map<String, dynamic> ? decoded : null;
    } on Object {
      return null;
    }
  }

  Future<void> refreshSources() async {
    if (sourcesLoading) return;
    setState(() => sourcesLoading = true);
    try {
      final raw = await hostChannel.invokeMethod<List<dynamic>>('listSources');
      final discovered = (raw ?? const <dynamic>[])
          .whereType<Map<dynamic, dynamic>>()
          .map(AppSource.fromMap)
          .toList();
      if (!mounted) return;
      setState(() {
        sources = discovered;
        if (selectedSourcePid != null &&
            !sources.any((source) => source.pid == selectedSourcePid)) {
          selectedSourcePid = null;
        }
      });
    } catch (_) {
      // Widget tests and non-Windows builds do not register this channel.
    } finally {
      if (mounted) setState(() => sourcesLoading = false);
    }
  }

  Future<void> refreshHostStatus() async {
    if (statusRefreshInFlight) return;
    statusRefreshInFlight = true;
    try {
      final raw = await hostChannel.invokeMethod<Map<dynamic, dynamic>>(
        'status',
      );
      if (raw == null || !mounted) return;
      final status = raw.map((key, value) => MapEntry('$key', value));
      setState(() {
        hostStatus = status;
        streaming = status['active'] == true;
        if (streaming) hostError = null;
      });
    } catch (_) {
      // The native host is Windows-only.
    } finally {
      statusRefreshInFlight = false;
    }
  }

  Future<void> refreshStartupSetting() async {
    try {
      final enabled = await hostChannel.invokeMethod<bool>('getStartup');
      if (mounted && enabled != null) {
        setState(() => startWithWindows = enabled);
      }
    } catch (_) {}
  }

  Future<void> setStartup(bool enabled) async {
    try {
      final applied = await hostChannel.invokeMethod<bool>('setStartup', {
        'enabled': enabled,
      });
      if (mounted) setState(() => startWithWindows = applied ?? false);
    } on PlatformException catch (error) {
      showError(error.message ?? 'Could not update startup settings');
    }
  }

  Future<void> startHost() async {
    if (selectedSourcePid == null) {
      showError('Choose a running application first.');
      return;
    }
    setState(() {
      hostBusy = true;
      hostError = null;
    });
    try {
      final raw = await hostChannel
          .invokeMethod<Map<dynamic, dynamic>>('start', {
            'pid': selectedSourcePid,
            'systemAudio': selectedSourcePid == 0,
            'sourceLabel': sources
                .where((source) => source.pid == selectedSourcePid)
                .map((source) => source.name)
                .firstOrNull,
            'mode': mode == ListeningMode.synchronized
                ? 'synchronized'
                : 'low-delay',
            'profile': switch (profile) {
              BufferProfile.ultraLow => 'ultra-low',
              BufferProfile.balanced => 'balanced',
              BufferProfile.stable => 'stable',
            },
          });
      if (!mounted || raw == null) return;
      setState(() {
        hostStatus = raw.map((key, value) => MapEntry('$key', value));
        streaming = true;
      });
    } on PlatformException catch (error) {
      final message = error.message?.trim();
      if (mounted) {
        setState(
          () => hostError = message?.isNotEmpty == true
              ? message
              : 'Could not start the host',
        );
        showError(hostError!);
      }
    } finally {
      if (mounted) setState(() => hostBusy = false);
    }
  }

  Future<void> stopHost() async {
    setState(() => hostBusy = true);
    try {
      await hostChannel.invokeMethod<bool>('stop');
      if (mounted) {
        setState(() {
          streaming = false;
          hostStatus = const {};
        });
      }
    } finally {
      if (mounted) setState(() => hostBusy = false);
    }
  }

  void showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> copyInvitation() async {
    final invitation = hostStatus['invitation'] as String?;
    if (invitation == null || invitation.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: invitation));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Invitation copied to clipboard')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 760;
    return Scaffold(
      appBar: wide
          ? null
          : AppBar(
              toolbarHeight: 44,
              titleSpacing: 16,
              title: const Wordmark(compact: true),
            ),
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: page,
              onDestinationSelected: (v) => setState(() => page = v),
              destinations: [
                for (var i = 0; i < labels.length; i++)
                  NavigationDestination(icon: Icon(icons[i]), label: labels[i]),
              ],
            ),
      body: Row(
        children: [
          if (wide)
            SideNav(page: page, onSelect: (v) => setState(() => page = v)),
          Expanded(
            child: SafeArea(
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1050),
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      wide ? 32 : 16,
                      wide ? 32 : 10,
                      wide ? 32 : 16,
                      24,
                    ),
                    child: currentPage(),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget currentPage() => switch (page) {
    0 => session(),
    1 => devices(),
    2 => diagnostics(),
    _ => settings(),
  };

  bool get receiverActive =>
      receiverState != 'idle' &&
      receiverState != 'stopped' &&
      receiverState != 'error';

  bool get receiverConnected =>
      receiverState == 'buffering' || receiverState == 'playing';

  bool get discoveryScanning =>
      defaultTargetPlatform == TargetPlatform.android &&
      !receiverActive &&
      !receiverBusy &&
      discoveredHosts.isEmpty &&
      discoveryError == null;

  String get receiverDeviceName =>
      receiverStatus['device_name'] as String? ?? outputs.first.name;

  List<String> get connectedDevices {
    final raw = hostStatus['connected_devices'];
    if (raw is! List) return const [];
    return raw.whereType<String>().where((name) => name.isNotEmpty).toList();
  }

  bool get canStartHost => selectedSourcePid != null && !hostBusy;

  String get sessionActionHint {
    if (defaultTargetPlatform == TargetPlatform.android) {
      if (receiverBusy) return 'Applying receiver state…';
      if (receiverActive) {
        return 'Audio continues in the background until stopped.';
      }
      if (discoveredHosts.isEmpty) {
        return 'Looking for Sonara PCs on this network.';
      }
      return 'Ready to connect securely.';
    }
    if (hostBusy) return 'Applying session state…';
    if (streaming) return 'Active on the local network and safe to minimize.';
    if (selectedSourcePid == null) {
      return 'Select System audio or an application to continue.';
    }
    return 'Ready to open the session.';
  }

  Widget nearbyHostsPanel() => Panel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(child: Label('NEARBY SONARA HOSTS')),
            IconButton.filledTonal(
              tooltip: 'Scan again',
              onPressed: () => unawaited(startDiscovery()),
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (discoveredHosts.isEmpty)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: SizedBox(
              width: 24,
              height: 24,
              child: discoveryError == null
                  ? const CircularProgressIndicator(strokeWidth: 2)
                  : Icon(
                      Icons.wifi_off_rounded,
                      color: Theme.of(context).colorScheme.error,
                    ),
            ),
            title: Text(
              discoveryError == null
                  ? 'Scanning the local network…'
                  : 'Local network scan paused',
            ),
            subtitle: Text(
              discoveryError ??
                  'Keep Sonara open on the PC and use the same Wi-Fi, Ethernet, or tethered LAN.',
            ),
          )
        else
          for (final host in discoveredHosts)
            NearbyHostTile(
              host: host,
              trusted: trustedFingerprints.contains(host.hostFingerprint),
              enabled: !receiverActive && !receiverBusy,
              busy: receiverBusy,
              onConnect: () => connectInvitation(host.invitation),
            ),
        const Divider(),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: receiverActive ? null : importInvitation,
            icon: const Icon(Icons.keyboard_outlined),
            label: const Text('Enter invitation manually'),
          ),
        ),
      ],
    ),
  );

  Widget receiverConnectionPanel() => Panel(
    child: Row(
      children: [
        CircleAvatar(
          backgroundColor: receiverConnected
              ? Colors.green.withValues(alpha: .14)
              : Theme.of(context).colorScheme.secondaryContainer,
          child: Icon(
            receiverConnected ? Icons.link_rounded : Icons.sync_rounded,
            color: receiverConnected
                ? Colors.green.shade700
                : Theme.of(context).colorScheme.onSecondaryContainer,
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                receiverConnected
                    ? 'Connected to ${connectedHostName ?? 'Sonara PC'}'
                    : 'Connecting to ${connectedHostName ?? 'Sonara PC'}…',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 3),
              Text(
                receiverConnected
                    ? '$receiverDeviceName is receiving audio.'
                    : 'Securing the connection and synchronizing audio.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        StatusPill(
          label: receiverConnected ? 'CONNECTED' : 'CONNECTING',
          active: receiverConnected,
        ),
      ],
    ),
  );

  Widget androidSessionStatePanel() {
    final state = receiverConnected
        ? 'connected'
        : receiverActive
        ? 'connecting'
        : 'idle';
    return AnimatedSize(
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 280),
        reverseDuration: const Duration(milliseconds: 220),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, .035),
              end: Offset.zero,
            ).animate(animation),
            child: child,
          ),
        ),
        child: KeyedSubtree(
          key: ValueKey(state),
          child: receiverActive
              ? receiverConnectionPanel()
              : nearbyHostsPanel(),
        ),
      ),
    );
  }

  Widget sessionActionArea() {
    return AnimatedSize(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 240),
        child: discoveryScanning
            ? const SizedBox.shrink(key: ValueKey('scanning-action-hidden'))
            : Column(
                key: const ValueKey('session-action-visible'),
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    style: (streaming || receiverActive)
                        ? FilledButton.styleFrom(
                            backgroundColor: Theme.of(
                              context,
                            ).colorScheme.errorContainer,
                            foregroundColor: Theme.of(
                              context,
                            ).colorScheme.onErrorContainer,
                          )
                        : null,
                    onPressed: defaultTargetPlatform == TargetPlatform.android
                        ? (receiverBusy
                              ? null
                              : receiverActive
                              ? stopReceiver
                              : discoveredHosts.isNotEmpty
                              ? () => connectInvitation(
                                  discoveredHosts.first.invitation,
                                )
                              : () => unawaited(startDiscovery()))
                        : (hostBusy
                              ? null
                              : streaming
                              ? stopHost
                              : canStartHost
                              ? startHost
                              : null),
                    icon: receiverBusy || hostBusy
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            streaming || receiverActive
                                ? Icons.stop_rounded
                                : defaultTargetPlatform ==
                                      TargetPlatform.android
                                ? Icons.wifi_find_rounded
                                : Icons.play_arrow_rounded,
                          ),
                    label: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      child: Text(
                        defaultTargetPlatform == TargetPlatform.android
                            ? (receiverBusy
                                  ? (receiverState == 'stopping'
                                        ? 'Stopping receiver…'
                                        : 'Connecting…')
                                  : receiverActive
                                  ? 'Stop receiver'
                                  : discoveredHosts.isNotEmpty
                                  ? 'Connect to ${discoveredHosts.first.name}'
                                  : 'Try scanning again')
                            : (hostBusy
                                  ? (streaming
                                        ? 'Stopping session…'
                                        : 'Starting session…')
                                  : streaming
                                  ? 'Stop session'
                                  : 'Start session'),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          streaming || receiverActive
                              ? Icons.check_circle_outline
                              : Icons.info_outline,
                          size: 16,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 7),
                        Flexible(
                          child: Text(
                            sessionActionHint,
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (hostError != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        hostError!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                ],
              ),
      ),
    );
  }

  Widget session() => ListView(
    children: [
      Heading(
        'Session',
        defaultTargetPlatform == TargetPlatform.windows
            ? 'Choose an application and open a synchronized LAN session.'
            : 'Connect this device to a nearby Sonara PC.',
      ),
      const SizedBox(height: 22),
      if (defaultTargetPlatform == TargetPlatform.windows) ...[
        Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Label('SOURCE'),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                key: ValueKey('source-$selectedSourcePid-${sources.length}'),
                isExpanded: true,
                initialValue: selectedSourcePid?.toString() ?? 'none',
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.apps),
                  labelText: 'Audio source',
                ),
                items: [
                  DropdownMenuItem(
                    value: 'none',
                    child: Text(
                      sourcesLoading
                          ? 'Finding running applications…'
                          : 'Select a running application',
                    ),
                  ),
                  for (final source in sources)
                    DropdownMenuItem(
                      value: source.pid.toString(),
                      child: Text(
                        '${source.name} — ${source.title}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: streaming || hostBusy
                    ? null
                    : (value) => setState(
                        () =>
                            selectedSourcePid = value == null || value == 'none'
                            ? null
                            : int.tryParse(value),
                      ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: streaming || sourcesLoading
                      ? null
                      : refreshSources,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Refresh apps'),
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Capture copies audio. It cannot delay the app’s original speaker output.',
                style: TextStyle(fontSize: 13),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
      ],
      if (defaultTargetPlatform == TargetPlatform.android) ...[
        androidSessionStatePanel(),
        const SizedBox(height: 16),
      ],
      Panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(child: Label('OUTPUTS')),
                if (defaultTargetPlatform == TargetPlatform.windows &&
                    streaming)
                  Chip(label: Text('${hostStatus['address'] ?? 'LAN'}:49812')),
              ],
            ),
            if (defaultTargetPlatform == TargetPlatform.windows) ...[
              const Divider(height: 24),
              if (connectedDevices.isEmpty)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    streaming ? Icons.wifi_tethering : Icons.phone_android,
                  ),
                  title: Text(
                    streaming
                        ? 'Waiting for mobile devices'
                        : 'No mobile devices connected',
                  ),
                  subtitle: Text(
                    streaming
                        ? 'Nearby Android devices can discover this PC automatically.'
                        : 'Start the session to accept mobile listeners.',
                  ),
                  trailing: StatusPill(
                    label: streaming ? 'READY' : 'OFFLINE',
                    active: streaming,
                  ),
                )
              else
                for (final device in connectedDevices)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.phone_android_rounded),
                    title: Text(device),
                    subtitle: const Text('Receiving audio from this PC'),
                    trailing: const StatusPill(
                      label: 'CONNECTED',
                      active: true,
                    ),
                  ),
              if (streaming &&
                  (hostStatus['invitation'] as String? ?? '').isNotEmpty) ...[
                const SizedBox(height: 8),
                TextFormField(
                  readOnly: true,
                  minLines: 2,
                  maxLines: 4,
                  initialValue: hostStatus['invitation'] as String? ?? '',
                  decoration: InputDecoration(
                    labelText: 'Receiver invitation',
                    suffixIcon: IconButton(
                      tooltip: 'Copy invitation',
                      onPressed: copyInvitation,
                      icon: const Icon(Icons.copy),
                    ),
                  ),
                ),
              ] else if (streaming) ...[
                const SizedBox(height: 8),
                const LinearProgressIndicator(),
                const SizedBox(height: 8),
                const Text('Starting the secure host…'),
              ],
            ] else ...[
              const Divider(height: 24),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.speaker_phone_outlined),
                title: Text(outputs.first.name),
                subtitle: Text(
                  receiverConnected
                      ? 'Connected · ${outputs.first.route}'
                      : '${outputs.first.route} · ${outputs.first.quality}',
                ),
                trailing: StatusPill(
                  label: receiverConnected
                      ? 'CONNECTED'
                      : receiverActive
                      ? 'CONNECTING'
                      : 'READY',
                  active: receiverConnected,
                ),
              ),
              const Text(
                'Sonara follows Android’s current media output route. Change it from the system media output panel.',
                style: TextStyle(fontSize: 13),
              ),
            ],
          ],
        ),
      ),
      if (defaultTargetPlatform == TargetPlatform.windows) ...[
        const SizedBox(height: 16),
        Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Label('LISTENING'),
              const SizedBox(height: 14),
              SegmentedButton<ListeningMode>(
                segments: const [
                  ButtonSegment(
                    value: ListeningMode.synchronized,
                    label: Text('Synchronized'),
                  ),
                  ButtonSegment(
                    value: ListeningMode.lowDelay,
                    label: Text('Low delay'),
                  ),
                ],
                selected: {mode},
                onSelectionChanged: streaming
                    ? null
                    : (v) => setState(() => mode = v.first),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<BufferProfile>(
                isExpanded: true,
                initialValue: profile,
                decoration: const InputDecoration(labelText: 'Buffer profile'),
                items: const [
                  DropdownMenuItem(
                    value: BufferProfile.ultraLow,
                    child: Text('Ultra Low · adaptive 10–30 ms buffer'),
                  ),
                  DropdownMenuItem(
                    value: BufferProfile.balanced,
                    child: Text('Balanced · adaptive 20–60 ms buffer'),
                  ),
                  DropdownMenuItem(
                    value: BufferProfile.stable,
                    child: Text('Stable · adaptive 50–240 ms buffer'),
                  ),
                ],
                onChanged: streaming
                    ? null
                    : (v) => setState(() => profile = v!),
              ),
            ],
          ),
        ),
      ],
      sessionActionArea(),
    ],
  );

  Widget devices() => ListView(
    children: [
      const Heading('Devices', 'Trusted peers and available output routes.'),
      const SizedBox(height: 22),
      if (defaultTargetPlatform == TargetPlatform.android) ...[
        Card(
          child: ListTile(
            leading: Icon(
              receiverConnected
                  ? Icons.check_circle_rounded
                  : Icons.speaker_phone_outlined,
              color: receiverConnected ? Colors.green : null,
            ),
            title: Text(receiverDeviceName),
            subtitle: Text(
              receiverStatus['error'] as String? ??
                  (receiverConnected
                      ? 'Connected to Sonara PC · ${receiverStatus['output_route'] ?? 'Platform output'}'
                      : receiverActive
                      ? 'Connecting to Sonara PC…'
                      : 'Not connected'),
            ),
            trailing: receiverActive
                ? FilledButton.tonalIcon(
                    onPressed: receiverBusy ? null : stopReceiver,
                    icon: receiverBusy
                        ? const SizedBox.square(
                            dimension: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.stop_rounded, size: 18),
                    label: Text(receiverBusy ? 'Stopping…' : 'Stop'),
                  )
                : const StatusPill(label: 'OFFLINE', active: false),
          ),
        ),
        const SizedBox(height: 14),
        if (receiverActive) receiverConnectionPanel() else nearbyHostsPanel(),
        const SizedBox(height: 14),
      ] else if (defaultTargetPlatform == TargetPlatform.windows) ...[
        Card(
          child: Column(
            children: [
              ListTile(
                leading: Icon(
                  streaming ? Icons.wifi_tethering : Icons.wifi_off,
                ),
                title: Text(
                  streaming ? 'Windows host active' : 'Windows host idle',
                ),
                subtitle: Text(
                  streaming
                      ? '${hostStatus['source_label'] ?? 'Audio source'} · ${hostStatus['address']}:49812'
                      : '${sources.where((source) => source.pid > 0).length} capturable windowed applications found',
                ),
                trailing: streaming
                    ? TextButton(onPressed: stopHost, child: const Text('Stop'))
                    : null,
              ),
              if (streaming) ...[
                const Divider(height: 1),
                if (connectedDevices.isEmpty)
                  const ListTile(
                    leading: Icon(Icons.phone_android_outlined),
                    title: Text('No mobile devices connected'),
                    subtitle: Text('Waiting for a Sonara receiver'),
                    trailing: StatusPill(label: 'WAITING', active: false),
                  )
                else
                  for (final device in connectedDevices)
                    ListTile(
                      leading: const Icon(Icons.phone_android_rounded),
                      title: Text(device),
                      subtitle: const Text('Mobile receiver'),
                      trailing: const StatusPill(
                        label: 'CONNECTED',
                        active: true,
                      ),
                    ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 14),
      ],
      if (defaultTargetPlatform == TargetPlatform.android)
        Card(
          child: Column(
            children: [
              for (final o in outputs)
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 22,
                    vertical: 8,
                  ),
                  leading: CircleAvatar(
                    child: Icon(
                      defaultTargetPlatform == TargetPlatform.windows
                          ? Icons.computer_outlined
                          : Icons.phone_android,
                    ),
                  ),
                  title: Text(o.name),
                  subtitle: Text('${o.route} · ${o.quality}'),
                  trailing: Chip(
                    label: Text(
                      defaultTargetPlatform == TargetPlatform.windows
                          ? 'Host'
                          : 'Local',
                    ),
                  ),
                ),
            ],
          ),
        ),
      if (defaultTargetPlatform == TargetPlatform.windows) ...[
        const SizedBox(height: 18),
        OutlinedButton.icon(
          onPressed: streaming ? copyInvitation : null,
          icon: const Icon(Icons.copy),
          label: const Padding(
            padding: EdgeInsets.all(12),
            child: Text('Copy receiver invitation'),
          ),
        ),
      ],
    ],
  );

  List<DiagnosticDatum> get diagnosticItems {
    if (defaultTargetPlatform == TargetPlatform.windows) {
      return [
        DiagnosticDatum(
          'Session',
          streaming ? 'Active' : 'Idle',
          streaming ? 'Host process is running' : 'No active capture',
          streaming ? Icons.podcasts_rounded : Icons.pause_circle_outline,
        ),
        DiagnosticDatum(
          'Source',
          hostStatus['source_label'] as String? ?? '—',
          hostStatus['source_kind'] == 'system'
              ? 'All audible applications'
              : 'Selected process tree',
          Icons.graphic_eq_rounded,
        ),
        DiagnosticDatum(
          'Network',
          hostStatus['address'] as String? ?? '—',
          streaming ? 'QUIC · port 49812' : 'Not listening',
          Icons.lan_outlined,
        ),
        DiagnosticDatum(
          'Pairing',
          (hostStatus['invitation'] as String? ?? '').isNotEmpty
              ? 'Ready'
              : streaming
              ? 'Starting'
              : 'Closed',
          'Secure invitation state',
          Icons.verified_user_outlined,
        ),
        DiagnosticDatum(
          'Listening mode',
          _readableValue(hostStatus['mode'] ?? mode.name),
          'Shared presentation policy',
          Icons.sync_rounded,
        ),
        DiagnosticDatum(
          'Buffer profile',
          _readableValue(hostStatus['profile'] ?? profile.name),
          'Applied to connected receivers',
          Icons.tune_rounded,
        ),
      ];
    }
    return [
      DiagnosticDatum(
        'Receiver',
        _readableValue(receiverState),
        receiverStatus['output_route'] as String? ?? 'Platform output',
        receiverActive ? Icons.speaker_rounded : Icons.speaker_outlined,
      ),
      DiagnosticDatum(
        'Packets',
        '${receiverStatus['packets_received'] ?? 0}',
        '${receiverStatus['packets_lost'] ?? 0} lost · ${receiverStatus['redundant_packets'] ?? 0} duplicates',
        Icons.swap_vert_circle_outlined,
      ),
      DiagnosticDatum(
        'Adaptive buffer',
        receiverStatus['adaptive_buffer_ms'] == null
            ? '—'
            : '${_compactNumber(receiverStatus['adaptive_buffer_ms'])} ms',
        '${receiverStatus['buffered_frames'] ?? 0} frames queued',
        Icons.storage_rounded,
      ),
      DiagnosticDatum(
        'Clock uncertainty',
        receiverStatus['clock_uncertainty_ms'] == null
            ? '—'
            : '${_compactNumber(receiverStatus['clock_uncertainty_ms'])} ms',
        '${receiverStatus['rate_correction_ppm'] ?? 0} ppm correction',
        Icons.schedule_rounded,
      ),
      DiagnosticDatum(
        'Output health',
        '${receiverStatus['output_underruns'] ?? 0} underruns',
        '${receiverStatus['rebuffer_events'] ?? 0} recoveries · ${receiverStatus['output_dropped_frames'] ?? 0} stale frames',
        Icons.monitor_heart_outlined,
      ),
      DiagnosticDatum(
        'Rendered',
        '${receiverStatus['frames_rendered'] ?? 0} frames',
        '${receiverStatus['output_silence_frames'] ?? 0} silence frames inserted',
        Icons.multiline_chart_rounded,
      ),
    ];
  }

  String _readableValue(Object? value) => '$value'
      .replaceAll('_', ' ')
      .replaceAllMapped(
        RegExp(r'([a-z])([A-Z])'),
        (match) => '${match.group(1)} ${match.group(2)}',
      )
      .trim()
      .split(' ')
      .where((part) => part.isNotEmpty)
      .map((part) => '${part[0].toUpperCase()}${part.substring(1)}')
      .join(' ');

  String _compactNumber(Object? value) {
    if (value is! num) return '$value';
    if (value == value.roundToDouble()) return value.toInt().toString();
    return value.toStringAsFixed(2);
  }

  Widget diagnostics() => ListView(
    children: [
      const Heading(
        'Diagnostics',
        'Live engine state and measured playback health.',
      ),
      const SizedBox(height: 18),
      Panel(
        child: Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: streaming || receiverActive
                    ? Colors.green
                    : Theme.of(context).colorScheme.outline,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                streaming || receiverActive
                    ? 'Live telemetry · 10t/s'
                    : 'Live telemetry · offline',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            StatusPill(
              label: streaming || receiverActive ? 'LIVE' : 'IDLE',
              active: streaming || receiverActive,
            ),
          ],
        ),
      ),
      const SizedBox(height: 14),
      DiagnosticsGrid(items: diagnosticItems),
      const SizedBox(height: 14),
      Panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Label('TIMING CONFIDENCE'),
            const SizedBox(height: 9),
            Text(
              timingConfidence,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(timingExplanation),
          ],
        ),
      ),
      const SizedBox(height: 18),
      OutlinedButton.icon(
        onPressed: copyDiagnostics,
        icon: const Icon(Icons.copy_all_outlined),
        label: const Padding(
          padding: EdgeInsets.all(12),
          child: Text('Copy privacy-scrubbed diagnostics'),
        ),
      ),
    ],
  );

  Widget settings() => ListView(
    children: [
      const Heading(
        'Settings',
        'Local preferences. Sonara has no account or telemetry.',
      ),
      const SizedBox(height: 22),
      Card(
        child: Column(
          children: [
            if (defaultTargetPlatform == TargetPlatform.android)
              SwitchListTile(
                value: autoReconnect,
                onChanged: setAutoReconnect,
                title: const Text('Reconnect to trusted hosts'),
                subtitle: const Text(
                  'Connect automatically when an approved PC returns to this network',
                ),
              ),
            if (defaultTargetPlatform == TargetPlatform.windows)
              SwitchListTile(
                value: startWithWindows,
                onChanged: setStartup,
                title: const Text('Start with Windows'),
                subtitle: const Text(
                  'Open Sonara in the notification area after sign-in',
                ),
              ),
            if (defaultTargetPlatform == TargetPlatform.android &&
                trustedFingerprints.isNotEmpty) ...[
              const Divider(height: 1),
              for (final fingerprint in trustedFingerprints)
                ListTile(
                  leading: const Icon(Icons.verified_user_outlined),
                  title: const Text('Trusted PC'),
                  subtitle: Text(
                    fingerprint.length > 16
                        ? '${fingerprint.substring(0, 8)}…${fingerprint.substring(fingerprint.length - 8)}'
                        : fingerprint,
                  ),
                  trailing: IconButton(
                    tooltip: 'Forget this PC',
                    onPressed: () => forgetTrusted(fingerprint),
                    icon: const Icon(Icons.delete_outline),
                  ),
                ),
            ],
            if (defaultTargetPlatform == TargetPlatform.android &&
                trustedFingerprints.isEmpty)
              const ListTile(
                leading: Icon(Icons.devices_outlined),
                title: Text('No trusted PCs yet'),
                subtitle: Text(
                  'A PC becomes trusted after you connect to it manually.',
                ),
              ),
          ],
        ),
      ),
      const SizedBox(height: 16),
      const Card(
        child: ListTile(
          leading: Icon(Icons.shield_outlined),
          title: Text('Private by design'),
          subtitle: Text(
            'No cloud relay, stored audio, microphone recording, or telemetry.',
          ),
        ),
      ),
      const SizedBox(height: 16),
      Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              leading: ClipRRect(
                borderRadius: BorderRadius.circular(9),
                child: Image.asset(
                  'assets/branding/app_mark.png',
                  width: 40,
                  height: 40,
                  filterQuality: FilterQuality.high,
                ),
              ),
              title: const Text('Sonara'),
              subtitle: const Text('Version 1.0.0 · Open source under MIT'),
            ),
            const Divider(height: 1),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: Text(
                'Built with Flutter, Rust, QUIC, and Oboe for direct local-network audio. '
                'The source code and license are included with this project.',
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: Wrap(
                spacing: 7,
                runSpacing: 7,
                children: [
                  Chip(label: Text('Flutter')),
                  Chip(label: Text('Rust')),
                  Chip(label: Text('QUIC')),
                  Chip(label: Text('Oboe')),
                  Chip(label: Text('MIT License')),
                ],
              ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => showLicensePage(
                  context: context,
                  applicationName: 'Sonara',
                  applicationVersion: '1.0.0',
                  applicationLegalese:
                      '© 2026 Sonara contributors · MIT License',
                  applicationIcon: ClipRRect(
                    borderRadius: BorderRadius.circular(9),
                    child: Image.asset(
                      'assets/branding/app_mark.png',
                      width: 44,
                      height: 44,
                    ),
                  ),
                ),
                icon: const Icon(Icons.article_outlined),
                label: const Text('Open-source licenses'),
              ),
            ),
          ],
        ),
      ),
    ],
  );
}

class InvitationDialog extends StatefulWidget {
  const InvitationDialog({super.key, required this.validator});
  final FormFieldValidator<String> validator;

  @override
  State<InvitationDialog> createState() => _InvitationDialogState();
}

class _InvitationDialogState extends State<InvitationDialog> {
  final controller = TextEditingController();
  final formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Connect this receiver'),
    content: Form(
      key: formKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextFormField(
            controller: controller,
            autofocus: true,
            minLines: 3,
            maxLines: 6,
            validator: widget.validator,
            textInputAction: TextInputAction.done,
            onFieldSubmitted: (_) => submit(),
            decoration: const InputDecoration(
              labelText: 'Sonara invitation',
              hintText: 'sonara1:…',
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: pasteInvitation,
              icon: const Icon(Icons.content_paste_rounded, size: 18),
              label: const Text('Paste from clipboard'),
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: submit, child: const Text('Connect')),
    ],
  );

  void submit() {
    if (formKey.currentState?.validate() == true) {
      Navigator.pop(context, controller.text.trim());
    }
  }

  Future<void> pasteInvitation() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (!mounted || text == null || text.isEmpty) return;
    controller.text = text;
    formKey.currentState?.validate();
  }
}

class SideNav extends StatelessWidget {
  const SideNav({super.key, required this.page, required this.onSelect});
  final int page;
  final ValueChanged<int> onSelect;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 228,
    child: Material(
      color: Theme.of(context).colorScheme.surface,
      child: SafeArea(
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(24, 26, 24, 30),
              child: Align(alignment: Alignment.centerLeft, child: Wordmark()),
            ),
            for (var i = 0; i < _SonaraShellState.labels.length; i++)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 2,
                ),
                child: ListTile(
                  selected: page == i,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  leading: Icon(_SonaraShellState.icons[i]),
                  title: Text(_SonaraShellState.labels[i]),
                  onTap: () => onSelect(i),
                ),
              ),
            const Spacer(),
            const Padding(
              padding: EdgeInsets.all(22),
              child: Text(
                'Local network only\nProtocol sonara/1',
                style: TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class Wordmark extends StatelessWidget {
  const Wordmark({super.key, this.compact = false});
  final bool compact;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(7),
        child: Image.asset(
          'assets/branding/app_mark.png',
          width: compact ? 24 : 28,
          height: compact ? 24 : 28,
          filterQuality: FilterQuality.high,
        ),
      ),
      SizedBox(width: compact ? 7 : 9),
      Text(
        'sonara',
        style: TextStyle(
          fontSize: compact ? 19 : 22,
          fontWeight: FontWeight.w700,
          letterSpacing: -.5,
        ),
      ),
    ],
  );
}

class Heading extends StatelessWidget {
  const Heading(this.title, this.subtitle, {super.key});
  final String title, subtitle;
  @override
  Widget build(BuildContext context) {
    final showSubtitle =
        defaultTargetPlatform != TargetPlatform.android &&
        subtitle.trim().isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.w700,
            color: Theme.of(context).brightness == Brightness.light
                ? ink
                : null,
          ),
        ),
        if (showSubtitle) ...[
          const SizedBox(height: 5),
          Text(subtitle, style: Theme.of(context).textTheme.bodyLarge),
        ],
      ],
    );
  }
}

class Label extends StatelessWidget {
  const Label(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Text(
    text,
    style: TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w700,
      letterSpacing: 1.1,
      color: Theme.of(context).colorScheme.primary,
    ),
  );
}

class Panel extends StatelessWidget {
  const Panel({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(padding: const EdgeInsets.all(22), child: child),
  );
}

class Output {
  Output(this.name, this.route, this.selected, this.quality, this.delayMs);
  String name, route, quality;
  bool selected;
  final int? delayMs;
}

class AppSource {
  const AppSource({required this.pid, required this.name, required this.title});

  factory AppSource.fromMap(Map<dynamic, dynamic> map) => AppSource(
    pid: map['pid'] as int,
    name: map['name'] as String? ?? 'Application',
    title: map['title'] as String? ?? '',
  );

  final int pid;
  final String name;
  final String title;
}

class OutputRow extends StatelessWidget {
  const OutputRow({
    super.key,
    required this.output,
    required this.enabled,
    required this.onChanged,
  });
  final Output output;
  final bool enabled;
  final ValueChanged<bool?> onChanged;
  @override
  Widget build(BuildContext context) => Column(
    children: [
      const Divider(height: 1),
      CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        value: output.selected,
        onChanged: enabled ? onChanged : null,
        title: Text(output.name),
        subtitle: Text('${output.route} · ${output.quality}'),
        secondary: output.delayMs == null
            ? const Text('—')
            : Text('${output.delayMs} ms'),
      ),
    ],
  );
}

class NearbyHostTile extends StatelessWidget {
  const NearbyHostTile({
    super.key,
    required this.host,
    required this.trusted,
    required this.enabled,
    required this.busy,
    required this.onConnect,
  });

  final DiscoveredHost host;
  final bool trusted;
  final bool enabled;
  final bool busy;
  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final button = FilledButton.tonalIcon(
        onPressed: enabled ? onConnect : null,
        icon: busy
            ? const SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.link),
        label: Text(busy ? 'Connecting…' : 'Connect'),
      );
      final tile = ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const CircleAvatar(child: Icon(Icons.computer)),
        title: Text(host.name, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          '${host.address} · ${trusted ? 'trusted host' : 'encrypted session'}',
        ),
        trailing: constraints.maxWidth >= 520 ? button : null,
      );
      if (constraints.maxWidth >= 520) return tile;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [tile, button, const SizedBox(height: 8)],
      );
    },
  );
}

class DiagnosticDatum {
  const DiagnosticDatum(this.label, this.value, this.note, this.icon);
  final String label;
  final String value;
  final String note;
  final IconData icon;
}

class DiagnosticsGrid extends StatelessWidget {
  const DiagnosticsGrid({super.key, required this.items});
  final List<DiagnosticDatum> items;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final columns = constraints.maxWidth >= 850
          ? 3
          : constraints.maxWidth >= 520
          ? 2
          : 1;
      const gap = 12.0;
      final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [for (final item in items) Metric(item: item, width: width)],
      );
    },
  );
}

class Metric extends StatelessWidget {
  const Metric({super.key, required this.item, required this.width});
  final DiagnosticDatum item;
  final double width;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    height: 136,
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  item.icon,
                  size: 18,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(item.label, style: Theme.of(context).textTheme.labelLarge),
              ],
            ),
            const Spacer(),
            Text(
              item.value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              item.note,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    ),
  );
}

class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.label, required this.active});
  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: active
            ? Colors.green.withValues(alpha: .13)
            : colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: .8,
          color: active ? Colors.green.shade700 : colors.onSurfaceVariant,
        ),
      ),
    );
  }
}
