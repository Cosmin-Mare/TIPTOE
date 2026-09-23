import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../domain/rules.dart';

class NotificationService {
  final _plugin = FlutterLocalNotificationsPlugin();
  final _lastSound = <int, DateTime>{};
  void Function(String? payload)? onTap;

  Future<void> init() async {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const apple = DarwinInitializationSettings();
    await _plugin.initialize(
      const InitializationSettings(android: android, iOS: apple),
      onDidReceiveNotificationResponse: (response) => onTap?.call(response.payload),
    );
  }

  Future<void> showAlert({
    required int nodeId,
    required int eventId,
    required String nodeName,
    required String trigger,
    required bool cameraFailed,
    required bool noBudget,
    required bool ir,
    int? soundPeakDb,
    String? imagePath,
    bool quiet = false,
    String? payload,
  }) async {
    final copy = alertCopy(
      nodeName: nodeName,
      trigger: trigger,
      cameraFailed: cameraFailed,
      noBudget: noBudget,
      ir: ir,
      soundPeakDb: soundPeakDb,
    );
    final now = DateTime.now();
    final previous = _lastSound[nodeId];
    final playSound = !quiet && (previous == null || now.difference(previous) >= const Duration(minutes: 1));
    if (playSound) _lastSound[nodeId] = now;
    final id = (nodeId * 100000 + (eventId.abs() % 100000)) & 0x7fffffff;
    final android = AndroidNotificationDetails(
      'tiptoe_alerts',
      'Motion alerts',
      channelDescription: 'Motion, snapshots, and handheld warnings',
      importance: Importance.high,
      priority: Priority.high,
      groupKey: 'node_$nodeId',
      playSound: playSound,
      enableVibration: playSound,
      styleInformation: imagePath == null ? null : BigPictureStyleInformation(FilePathAndroidBitmap(imagePath)),
    );
    const apple = DarwinNotificationDetails(presentSound: true);
    await _plugin.show(
      id,
      copy.title,
      copy.body,
      NotificationDetails(android: android, iOS: playSound ? apple : const DarwinNotificationDetails(presentSound: false)),
      payload: payload,
    );
  }

  Future<void> showWarning(String message, {String title = 'TIPTOE handheld', int id = 900001}) async {
    const android = AndroidNotificationDetails(
      'tiptoe_warnings',
      'Handheld warnings',
      channelDescription: 'Critical handheld alerts',
      importance: Importance.max,
      priority: Priority.high,
    );
    const apple = DarwinNotificationDetails(presentSound: true, interruptionLevel: InterruptionLevel.timeSensitive);
    await _plugin.show(id, title, message, const NotificationDetails(android: android, iOS: apple));
  }

  Future<void> startLinkService() async {
    if (kIsWeb || !Platform.isAndroid) return;
    final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (android == null) return;
    const details = AndroidNotificationDetails(
      'tiptoe_link',
      'Handheld link',
      channelDescription: 'Keeps the connection to the TIPTOE handheld',
      importance: Importance.low,
      priority: Priority.low,
      ongoing: true,
      onlyAlertOnce: true,
    );
    try {
      await android.startForegroundService(
        42,
        'TIPTOE',
        'Connected to the handheld',
        notificationDetails: details,
        foregroundServiceTypes: {AndroidServiceForegroundType.foregroundServiceTypeConnectedDevice},
      );
    } catch (_) {}
  }

  Future<void> stopLinkService() async {
    if (kIsWeb || !Platform.isAndroid) return;
    final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    try {
      await android?.stopForegroundService();
    } catch (_) {}
  }
}
