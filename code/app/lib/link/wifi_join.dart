import 'package:flutter/services.dart';

import 'permissions.dart';

/// Joins the handheld or node access point and binds this process to it on Android.
class WifiJoin {
  static const _channel = MethodChannel('com.tiptoe/wifi');

  static Future<bool> join({required String ssid, required String password}) async {
    await AppPermissions.nearbyWifi();
    try {
      final ok = await _channel.invokeMethod<bool>('join', {'ssid': ssid, 'pass': password});
      return ok ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  static Future<void> leave({String? ssid}) async {
    try {
      await _channel.invokeMethod<void>('leave', {'ssid': ssid});
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }
}
