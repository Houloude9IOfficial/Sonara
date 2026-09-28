import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const sonaraDiscoveryPort = 49813;
const sonaraDiscoveryProtocol = 'sonara-discovery/1';
const sonaraDiscoveryProbe = 'SONARA_DISCOVER/1';

class NativeDiscoveryDatagram {
  const NativeDiscoveryDatagram({required this.data, required this.address});

  final Uint8List data;
  final InternetAddress address;
}

typedef NativeDiscoveryScan = Future<List<NativeDiscoveryDatagram>> Function();

class DiscoveredHost {
  const DiscoveredHost({
    required this.name,
    required this.address,
    required this.invitation,
    required this.lastSeen,
    required this.hostFingerprint,
    required this.invitationId,
  });

  final String name;
  final String address;
  final String invitation;
  final DateTime lastSeen;
  final String hostFingerprint;
  final String invitationId;

  static DiscoveredHost? tryParse(Uint8List bytes, InternetAddress sender) {
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map) return null;
      final protocol = decoded['protocol'];
      final rawInvitation = decoded['invitation'];
      final rawName = decoded['name'];
      if (protocol != sonaraDiscoveryProtocol || rawInvitation is! String) {
        return null;
      }
      final invitation = rawInvitation.trim();
      if (invitation.isEmpty || !invitation.startsWith('sonara1:')) {
        return null;
      }
      final name = rawName is String && rawName.trim().isNotEmpty
          ? rawName.trim()
          : 'Sonara host';
      final invitationJson = jsonDecode(
        utf8.decode(
          base64Url.decode(base64Url.normalize(invitation.substring(8))),
        ),
      );
      if (invitationJson is! Map ||
          invitationJson['host_fingerprint'] is! String ||
          invitationJson['id'] is! String) {
        return null;
      }
      return DiscoveredHost(
        name: name,
        address: sender.address,
        invitation: invitation,
        lastSeen: DateTime.now(),
        hostFingerprint: invitationJson['host_fingerprint'] as String,
        invitationId: invitationJson['id'] as String,
      );
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }
}

class SonaraDiscovery {
  SonaraDiscovery({Iterable<InternetAddress>? probeAddresses, this.nativeScan})
    : _probeAddresses = List.unmodifiable(
        probeAddresses ?? [InternetAddress('255.255.255.255')],
      );

  final _updates = StreamController<List<DiscoveredHost>>.broadcast();
  final Map<String, DiscoveredHost> _hosts = {};
  final List<InternetAddress> _probeAddresses;
  final NativeDiscoveryScan? nativeScan;
  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _subscription;
  Timer? _timer;
  int _probeCursor = 0;
  bool _started = false;
  bool _nativeScanInFlight = false;

  Stream<List<DiscoveredHost>> get updates => _updates.stream;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    if (nativeScan != null) {
      scan();
      _timer = Timer.periodic(const Duration(seconds: 2), (_) {
        _expireHosts();
        scan();
      });
      return;
    }
    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      sonaraDiscoveryPort,
      reuseAddress: true,
    );
    socket.broadcastEnabled = true;
    _socket = socket;
    _subscription = socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      while (true) {
        final datagram = socket.receive();
        if (datagram == null) break;
        final host = DiscoveredHost.tryParse(datagram.data, datagram.address);
        if (host == null) continue;
        _hosts[host.invitation] = host;
        _emit();
      }
    }, onError: _updates.addError);
    scan();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) {
      _expireHosts();
      scan();
    });
  }

  void scan() {
    if (nativeScan != null) {
      unawaited(_scanNative());
      return;
    }
    final socket = _socket;
    if (socket == null) return;
    final probe = utf8.encode(sonaraDiscoveryProbe);
    const batchSize = 128;
    final count = _probeAddresses.length < batchSize
        ? _probeAddresses.length
        : batchSize;
    for (var offset = 0; offset < count; offset++) {
      final address =
          _probeAddresses[(_probeCursor + offset) % _probeAddresses.length];
      socket.send(probe, address, sonaraDiscoveryPort);
    }
    if (_probeAddresses.isNotEmpty) {
      _probeCursor = (_probeCursor + count) % _probeAddresses.length;
    }
  }

  Future<void> _scanNative() async {
    if (_nativeScanInFlight || !_started) return;
    final scanProvider = nativeScan;
    if (scanProvider == null) return;
    _nativeScanInFlight = true;
    try {
      final datagrams = await scanProvider();
      for (final datagram in datagrams) {
        final host = DiscoveredHost.tryParse(datagram.data, datagram.address);
        if (host != null) _hosts[host.invitation] = host;
      }
      _emit();
    } catch (error) {
      if (!_updates.isClosed) _updates.addError(error);
    } finally {
      _nativeScanInFlight = false;
    }
  }

  void _expireHosts() {
    final cutoff = DateTime.now().subtract(const Duration(seconds: 6));
    _hosts.removeWhere((_, host) => host.lastSeen.isBefore(cutoff));
    _emit();
  }

  void _emit() {
    final hosts = _hosts.values.toList()
      ..sort((left, right) => left.name.compareTo(right.name));
    if (!_updates.isClosed) _updates.add(List.unmodifiable(hosts));
  }

  Future<void> stop() async {
    _started = false;
    _timer?.cancel();
    await _subscription?.cancel();
    _socket?.close();
    _socket = null;
    await _updates.close();
  }
}
