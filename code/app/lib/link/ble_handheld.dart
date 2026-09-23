import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../protocol/uuids.dart';
import 'frame_source.dart';
import 'permissions.dart';

class BleHit {
  const BleHit({required this.id, required this.name, required this.rssi});
  final String id;
  final String name;
  final int rssi;
}

class BleHandheld implements FrameSource {
  BleHandheld(this.deviceId);

  @override
  void simulateMotion() {}

  @override
  void runScenario(String name) {}

  final String deviceId;
  final _incoming = StreamController<List<int>>.broadcast();
  BluetoothDevice? _device;
  StreamSubscription<BluetoothConnectionState>? _connection;
  bool _stopped = false;

  @override
  Stream<List<int>> get incoming => _incoming.stream;

  static Future<List<BleHit>> scan({Duration timeout = const Duration(seconds: 8)}) async {
    if (!await AppPermissions.bluetooth()) {
      throw CommandException('Bluetooth permission is required to find the handheld.');
    }
    final adapter = await FlutterBluePlus.adapterState.first;
    if (adapter != BluetoothAdapterState.on) {
      throw CommandException('Turn Bluetooth on, then scan again.');
    }
    final hits = <String, BleHit>{};
    final sub = FlutterBluePlus.scanResults.listen((results) {
      for (final result in results) {
        final name = result.device.platformName;
        if (name.isNotEmpty && name != handheldName) continue;
        hits[result.device.remoteId.str] = BleHit(
          id: result.device.remoteId.str,
          name: name.isEmpty ? handheldName : name,
          rssi: result.rssi,
        );
      }
    });
    try {
      await FlutterBluePlus.startScan(
        withServices: [Guid(serviceUuid)],
        timeout: timeout,
      );
      await FlutterBluePlus.isScanning.where((scanning) => !scanning).first;
    } finally {
      await FlutterBluePlus.stopScan();
      await sub.cancel();
    }
    return hits.values.toList();
  }

  @override
  Future<void> start() async {
    _stopped = false;
    if (!await AppPermissions.bluetooth()) {
      throw CommandException('Bluetooth permission is required.');
    }
    final device = BluetoothDevice.fromId(deviceId);
    _device = device;
    await device.connect(mtu: requestMtu, timeout: const Duration(seconds: 25));
    if (_stopped) return;
    try {
      await device.requestMtu(requestMtu);
    } catch (_) {
      // iOS negotiates the MTU itself.
    }
    final services = await device.discoverServices();
    final service = services.cast<BluetoothService?>().firstWhere(
      (item) => item?.uuid == Guid(serviceUuid),
      orElse: () => null,
    );
    if (service == null) {
      throw CommandException('This device is not a TIPTOE handheld.');
    }
    BluetoothCharacteristic? rx;
    BluetoothCharacteristic? tx;
    for (final characteristic in service.characteristics) {
      if (characteristic.uuid == Guid(rxUuid)) rx = characteristic;
      if (characteristic.uuid == Guid(txUuid)) tx = characteristic;
    }
    if (rx == null || tx == null) {
      throw CommandException('The handheld is missing its command channel.');
    }
    _rx = rx;
    final subscription = tx.onValueReceived.listen(_incoming.add);
    device.cancelWhenDisconnected(subscription);
    await tx.setNotifyValue(true);
  }

  BluetoothCharacteristic? _rx;

  @override
  Future<void> write(List<int> bytes) async {
    final rx = _rx;
    if (rx == null) throw CommandException('Not connected to the handheld.');
    if (bytes.length > maxCommandBytes) {
      throw CommandException('Command is too long for one BLE write.');
    }
    await rx.write(bytes, withoutResponse: false);
  }

  @override
  void watchDisconnect(void Function(String reason) onLost) {
    _connection?.cancel();
    final device = _device;
    if (device == null) return;
    _connection = device.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected && device.isDisconnected && !_stopped) {
        onLost('The handheld disconnected. If pairing failed, forget TIPTOE-HH in Bluetooth settings and try again.');
      }
    });
  }

  @override
  Future<void> stop() async {
    _stopped = true;
    await _connection?.cancel();
    _connection = null;
    try {
      await _device?.disconnect();
    } catch (_) {}
    _rx = null;
  }
}
