import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

class AppPermissions {
  static Future<bool> bluetooth() async {
    if (kIsWeb) return false;
    if (Platform.isAndroid) {
      final scan = await Permission.bluetoothScan.request();
      final connect = await Permission.bluetoothConnect.request();
      if (scan.isGranted && connect.isGranted) return true;
      final location = await Permission.locationWhenInUse.request();
      return location.isGranted && connect.isGranted;
    }
    return true;
  }

  static Future<void> notifications() async {
    if (kIsWeb) return;
    await Permission.notification.request();
  }

  static Future<void> nearbyWifi() async {
    if (kIsWeb || !Platform.isAndroid) return;
    await Permission.locationWhenInUse.request();
  }
}
