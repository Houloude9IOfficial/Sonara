import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'discovery.dart';

void main() => runApp(const SonaraApp());

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
    dividerColor: colors.outlineVariant.withValues(alpha: .6),
    inputDecorationTheme: const InputDecorationTheme(
      border: OutlineInputBorder(),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: colors.outlineVariant),
      ),
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
        const Duration(milliseconds: 500),
        (_) => refreshReceiverStatus(),
      );
      refreshReceiverStatus();
      if (Platform.isAndroid) startDiscovery();
    } else if (defaultTargetPlatform == TargetPlatform.windows) {
      refreshSources();
      refreshHostStatus();
      refreshStartupSetting();
      statusTimer = Timer.periodic(
        const Duration(seconds: 1),
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
    try {
      final raw = await receiverChannel.invokeMethod<String>('status');
      if (raw == null || !mounted) return;
      final parsed = jsonDecode(raw) as Map<String, dynamic>;
      setState(() {
        receiverStatus = parsed;
        receiverState = parsed['state'] as String? ?? 'unknown';
        outputs.first
          ..name = parsed['platform_model'] as String? ?? 'Current device'
          ..route = parsed['output_route'] as String? ?? 'Platform default'
          ..quality = receiverState == 'playing'
              ? 'Timestamp observed'
              : 'Timing not measured';
      });
    } catch (_) {
      // The native receiver is Android-only; the desktop UI remains usable.
    }
  }

  Future<void> startDiscovery() async {
    final service = SonaraDiscovery();
    discovery = service;
    discoverySubscription = service.updates.listen(
      (hosts) {
        if (!mounted) return;
        setState(() {
          discoveredHosts = hosts;
          discoveryError = null;
        });
      },
      onError: (Object error) {
        if (mounted) {
          setState(() => discoveryError = 'LAN scan unavailable: $error');
        }
      },
    );
    try {
      await service.start();
    } catch (error) {
      if (mounted) {
        setState(() => discoveryError = 'LAN scan unavailable: $error');
      }
    }
  }

  String? validateInvitation(String? value) {
    final invitation = value?.trim() ?? '';
    if (invitation.isEmpty) return 'Enter an invitation first.';
    if (!invitation.startsWith('sonara1:')) {
      return 'This is not a Sonara invitation.';
    }
    return null;
  }

  Future<void> connectInvitation(Object? value) async {
    final invitation = value is String ? value.trim() : '';
    final validation = validateInvitation(invitation);
    if (validation != null) {
      showError(validation);
      return;
    }
    try {
      final started = await receiverChannel.invokeMethod<bool>('start', {
        'invitation': invitation,
      });
      if (started != true) {
        showError('Android did not start the receiver.');
        return;
      }
      await refreshReceiverStatus();
    } on PlatformException catch (error) {
      showError(error.message ?? 'Could not start receiver');
    } catch (error) {
      showError('Could not start receiver: $error');
    }
  }

  Future<void> importInvitation() async {
    final controller = TextEditingController();
    final formKey = GlobalKey<FormState>();
    final invitation = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Connect this receiver'),
        content: Form(
          key: formKey,
          child: TextFormField(
            controller: controller,
            autofocus: true,
            minLines: 3,
            maxLines: 6,
            validator: validateInvitation,
            decoration: const InputDecoration(
              labelText: 'Sonara invitation',
              hintText: 'sonara1:…',
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState?.validate() == true) {
                Navigator.pop(context, controller.text.trim());
              }
            },
            child: const Text('Connect'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (invitation != null) await connectInvitation(invitation);
  }

  Future<void> stopReceiver() async {
    await receiverChannel.invokeMethod<bool>('stop');
    await refreshReceiverStatus();
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
      appBar: wide ? null : AppBar(title: const Wordmark()),
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
                    padding: const EdgeInsets.all(28),
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

  Widget nearbyHostsPanel() => Panel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(child: Label('NEARBY SONARA HOSTS')),
            TextButton.icon(
              onPressed: () => discovery?.scan(),
              icon: const Icon(Icons.radar),
              label: const Text('Scan'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (discoveredHosts.isEmpty)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            title: const Text('Scanning the local network…'),
            subtitle: Text(
              discoveryError ??
                  'Keep Sonara open on the PC and use the same Wi-Fi, Ethernet, or tethered LAN.',
            ),
          )
        else
          for (final host in discoveredHosts)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const CircleAvatar(child: Icon(Icons.computer)),
              title: Text(host.name),
              subtitle: Text('${host.address} · encrypted Sonara session'),
              trailing: FilledButton(
                onPressed: receiverActive
                    ? null
                    : () => connectInvitation(host.invitation),
                child: const Text('Connect'),
              ),
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

  Widget session() => ListView(
    children: [
      const Heading(
        'Session',
        'Choose a source and the outputs Sonara controls.',
      ),
      const SizedBox(height: 22),
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
              items: defaultTargetPlatform == TargetPlatform.windows
                  ? [
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
                    ]
                  : const [
                      DropdownMenuItem(
                        value: 'none',
                        child: Text('Receive from a Sonara host'),
                      ),
                    ],
              onChanged: streaming || hostBusy
                  ? null
                  : (value) => setState(
                      () => selectedSourcePid = value == null || value == 'none'
                          ? null
                          : int.tryParse(value),
                    ),
            ),
            if (defaultTargetPlatform == TargetPlatform.windows)
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
            Text(
              defaultTargetPlatform == TargetPlatform.windows
                  ? 'Capture copies audio. It cannot delay the app’s original speaker output.'
                  : 'The native receiver follows the output route selected by Android.',
              style: TextStyle(fontSize: 13),
            ),
          ],
        ),
      ),
      const SizedBox(height: 16),
      if (defaultTargetPlatform == TargetPlatform.android) ...[
        nearbyHostsPanel(),
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
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  streaming ? Icons.wifi_tethering : Icons.phone_android,
                ),
                title: Text(
                  streaming
                      ? 'Ready for an Android receiver'
                      : 'Android receiver',
                ),
                subtitle: Text(
                  streaming
                      ? 'Nearby Android listeners can now discover this host automatically.'
                      : 'Start the session to create a secure, device-independent invitation.',
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
            ] else
              for (final o in outputs)
                OutputRow(
                  output: o,
                  enabled: !streaming,
                  onChanged: (v) => setState(() => o.selected = v ?? false),
                ),
          ],
        ),
      ),
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
              onChanged: streaming ? null : (v) => setState(() => profile = v!),
            ),
          ],
        ),
      ),
      const SizedBox(height: 24),
      FilledButton.icon(
        onPressed: hostBusy
            ? null
            : defaultTargetPlatform == TargetPlatform.android
            ? (receiverActive
                  ? stopReceiver
                  : discoveredHosts.isNotEmpty
                  ? () => connectInvitation(discoveredHosts.first.invitation)
                  : () => discovery?.scan())
            : (streaming ? stopHost : startHost),
        icon: Icon(
          streaming || receiverState == 'playing'
              ? Icons.stop_circle_outlined
              : Icons.play_arrow_rounded,
        ),
        label: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Text(
            defaultTargetPlatform == TargetPlatform.android
                ? (receiverActive
                      ? 'Stop receiver'
                      : discoveredHosts.isNotEmpty
                      ? 'Connect to ${discoveredHosts.first.name}'
                      : 'Scanning for hosts…')
                : (streaming ? 'Stop session' : 'Start session'),
          ),
        ),
      ),
      if (streaming)
        Padding(
          padding: const EdgeInsets.only(top: 14),
          child: Center(
            child: Text(
              defaultTargetPlatform == TargetPlatform.windows
                  ? 'Running in the background · closing the window minimizes Sonara to the tray'
                  : 'Preparing output · timing quality remains visible until measured',
            ),
          ),
        ),
      if (hostError != null)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(
            hostError!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
    ],
  );

  Widget devices() => ListView(
    children: [
      const Heading('Devices', 'Trusted peers and available output routes.'),
      const SizedBox(height: 22),
      if (defaultTargetPlatform == TargetPlatform.android) ...[
        Card(
          child: ListTile(
            leading: const Icon(Icons.speaker_phone_outlined),
            title: Text('Receiver · $receiverState'),
            subtitle: Text(
              receiverStatus['error'] as String? ??
                  '${receiverStatus['packets_received'] ?? 0} packets · '
                      '${receiverStatus['output_underruns'] ?? 0} underruns · '
                      '${receiverStatus['output_silence_frames'] ?? 0} silence frames · '
                      '${receiverStatus['rebuffer_events'] ?? 0} recoveries · '
                      '${receiverStatus['output_dropped_frames'] ?? 0} stale frames skipped',
            ),
            trailing: receiverState == 'idle' || receiverState == 'stopped'
                ? null
                : TextButton(
                    onPressed: stopReceiver,
                    child: const Text('Stop'),
                  ),
          ),
        ),
        const SizedBox(height: 14),
        nearbyHostsPanel(),
        const SizedBox(height: 14),
      ] else if (defaultTargetPlatform == TargetPlatform.windows) ...[
        Card(
          child: ListTile(
            leading: Icon(streaming ? Icons.wifi_tethering : Icons.wifi_off),
            title: Text(
              streaming ? 'Windows host active' : 'Windows host idle',
            ),
            subtitle: Text(
              streaming
                  ? '${hostStatus['address']}:49812 · process ${hostStatus['source_pid']}'
                  : '${sources.length} capturable windowed applications found',
            ),
            trailing: streaming
                ? TextButton(onPressed: stopHost, child: const Text('Stop'))
                : null,
          ),
        ),
        const SizedBox(height: 14),
      ],
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
      const SizedBox(height: 18),
      OutlinedButton.icon(
        onPressed: defaultTargetPlatform == TargetPlatform.android
            ? importInvitation
            : streaming
            ? copyInvitation
            : null,
        icon: Icon(
          defaultTargetPlatform == TargetPlatform.windows
              ? Icons.copy
              : Icons.qr_code_scanner,
        ),
        label: Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            defaultTargetPlatform == TargetPlatform.windows
                ? 'Copy receiver invitation'
                : 'Scan or paste invitation',
          ),
        ),
      ),
    ],
  );

  Widget diagnostics() => ListView(
    children: [
      const Heading(
        'Diagnostics',
        'Measured status — unknown values stay unknown.',
      ),
      const SizedBox(height: 22),
      Wrap(
        spacing: 14,
        runSpacing: 14,
        children: [
          Metric(
            'Session',
            defaultTargetPlatform == TargetPlatform.windows
                ? (streaming ? 'active' : 'idle')
                : receiverState,
            defaultTargetPlatform == TargetPlatform.windows
                ? 'Native WASAPI host state'
                : 'Native receiver state',
          ),
          Metric(
            'Network',
            defaultTargetPlatform == TargetPlatform.windows
                ? (hostStatus['address'] as String? ?? '—')
                : '${receiverStatus['packets_received'] ?? '—'} packets',
            defaultTargetPlatform == TargetPlatform.windows
                ? (streaming ? 'UDP/QUIC port 49812' : 'Not listening')
                : '${receiverStatus['packets_lost'] ?? '—'} lost',
          ),
          Metric(
            'Clock uncertainty',
            receiverStatus['clock_uncertainty_ms'] == null
                ? '—'
                : '${receiverStatus['clock_uncertainty_ms']} ms',
            'Correction ${receiverStatus['rate_correction_ppm'] ?? '—'} ppm',
          ),
          Metric(
            'Output',
            '${receiverStatus['frames_rendered'] ?? '—'} frames',
            '${receiverStatus['buffered_frames'] ?? '—'} buffered · '
                '${receiverStatus['output_underruns'] ?? '—'} underruns · '
                '${receiverStatus['output_silence_frames'] ?? '—'} silence frames · '
                '${receiverStatus['rebuffer_events'] ?? '—'} recoveries · '
                '${receiverStatus['output_dropped_frames'] ?? '—'} stale frames skipped',
          ),
          Metric(
            'Target buffer',
            receiverStatus['target_buffer_ms'] == null
                ? '—'
                : '${receiverStatus['adaptive_buffer_ms'] ?? receiverStatus['target_buffer_ms']} ms adaptive',
            receiverStatus['packet_duration_ms'] == null
                ? 'Negotiated when a receiver connects'
                : '${receiverStatus['packet_duration_ms']} ms packets · ${receiverStatus['profile'] ?? 'dynamic'}',
          ),
          Metric(
            'Interface',
            defaultTargetPlatform == TargetPlatform.windows
                ? 'Automatic'
                : 'Android',
            'Selected dynamically from active platform interfaces',
          ),
        ],
      ),
      const SizedBox(height: 20),
      const Panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Label('TIMING CONFIDENCE'),
            SizedBox(height: 12),
            Text(
              'Unknown',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
            ),
            SizedBox(height: 6),
            Text(
              '“Synced” is only shown after clock and output timestamps qualify. Bluetooth routes are best effort.',
            ),
          ],
        ),
      ),
      const SizedBox(height: 18),
      OutlinedButton.icon(
        onPressed: () {},
        icon: const Icon(Icons.file_download_outlined),
        label: const Padding(
          padding: EdgeInsets.all(12),
          child: Text('Export privacy-scrubbed report'),
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
            SwitchListTile(
              value: true,
              onChanged: (_) {},
              title: const Text('Explicit approval for each session'),
              subtitle: const Text('Recommended for trusted paired devices'),
            ),
            const Divider(height: 1),
            SwitchListTile(
              value: startWithWindows,
              onChanged: defaultTargetPlatform == TargetPlatform.windows
                  ? setStartup
                  : null,
              title: const Text('Start with Windows'),
              subtitle: const Text(
                'Open Sonara in the notification area after sign-in',
              ),
            ),
            const Divider(height: 1),
            const ListTile(
              title: Text('Maximum manual delay'),
              subtitle: Text('1,000 ms'),
              trailing: Icon(Icons.chevron_right),
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
    ],
  );
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
  const Wordmark({super.key});
  @override
  Widget build(BuildContext context) => const Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(Icons.waves_rounded, color: indigo),
      SizedBox(width: 9),
      Text(
        'sonara',
        style: TextStyle(
          fontSize: 22,
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
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        title,
        style: Theme.of(context).textTheme.headlineMedium?.copyWith(
          fontWeight: FontWeight.w700,
          color: Theme.of(context).brightness == Brightness.light ? ink : null,
        ),
      ),
      const SizedBox(height: 5),
      Text(subtitle, style: Theme.of(context).textTheme.bodyLarge),
    ],
  );
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

class Metric extends StatelessWidget {
  const Metric(this.label, this.value, this.note, {super.key});
  final String label, value, note;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 285,
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label),
            const SizedBox(height: 7),
            Text(
              value,
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 5),
            Text(note, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    ),
  );
}
