import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const sonaraDiscoveryPort = 49813;
const sonaraDiscoveryProtocol = 'sonara-discovery/1';
const sonaraDiscoveryProbe = 'SONARA_DISCOVER/1';

class DiscoveredHost {
  const DiscoveredHost({
    required this.name,
    required this.address,
    required this.invitation,
    required this.lastSeen,
  });

  final String name;
  final String address;
  final String invitation;
  final DateTime lastSeen;

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
      return DiscoveredHost(
        name: name,
        address: sender.address,
        invitation: invitation,
        lastSeen: DateTime.now(),
      );
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }
}

class SonaraDiscovery {
  final _updates = StreamController<List<DiscoveredHost>>.broadcast();
  final Map<String, DiscoveredHost> _hosts = {};
  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _subscription;
  Timer? _timer;

  Stream<List<DiscoveredHost>> get updates => _updates.stream;

  Future<void> start() async {
    if (_socket != null) return;
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
      final cutoff = DateTime.now().subtract(const Duration(seconds: 6));
      _hosts.removeWhere((_, host) => host.lastSeen.isBefore(cutoff));
      _emit();
      scan();
    });
  }

  void scan() {
    final socket = _socket;
    if (socket == null) return;
    socket.send(
      utf8.encode(sonaraDiscoveryProbe),
      InternetAddress('255.255.255.255'),
      sonaraDiscoveryPort,
    );
  }

  void _emit() {
    final hosts = _hosts.values.toList()
      ..sort((left, right) => left.name.compareTo(right.name));
    if (!_updates.isClosed) _updates.add(List.unmodifiable(hosts));
  }

  Future<void> stop() async {
    _timer?.cancel();
    await _subscription?.cancel();
    _socket?.close();
    _socket = null;
    await _updates.close();
  }
}
