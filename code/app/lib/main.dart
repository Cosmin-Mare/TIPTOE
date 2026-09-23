import 'package:flutter/material.dart';

import 'app.dart';
import 'data/database.dart';
import 'data/photo_store.dart';
import 'services/notification_service.dart';
import 'state/tiptoe_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final database = await AppDatabase.open();
  final photos = await PhotoStore.open();
  final notifications = NotificationService();
  await notifications.init();
  final store = TiptoeStore(db: database, photos: photos, notifications: notifications);
  await store.bootstrap();
  runApp(TiptoeApp(store: store));
}
