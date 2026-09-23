import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tiptoe/domain/rules.dart';
import 'package:tiptoe/protocol/messages.dart';
import 'package:tiptoe/protocol/stream_parser.dart';
import 'package:tiptoe/protocol/uuids.dart';
import 'package:tiptoe/services/handheld_service.dart';

void main() {
  test('frames split across notifications reassemble', () {
    final parser = StreamParser();
    final payload = utf8.encode('{"t":"pending","node":3,"count":1}');
    final frame = encodeFrame(frameTypeJson, payload);
    final seen = <String>[];
    parser.push(Uint8List.sublistView(frame, 0, 3), (_, _) {});
    parser.push(Uint8List.sublistView(frame, 3, 8), (_, _) {});
    parser.push(Uint8List.sublistView(frame, 8), (type, body) {
      expect(type, frameTypeJson);
      seen.add(utf8.decode(body));
    });
    expect(seen, ['{"t":"pending","node":3,"count":1}']);
    expect(parser.buffered, 0);
  });

  test('one notification can hold two frames', () {
    final parser = StreamParser();
    final a = encodeFrame(frameTypeJson, utf8.encode('{"t":"resp","ok":true}'));
    final image = encodeImagePayload(57, false, Uint8List.fromList([0xff, 0xd8, 0xff, 0xd9]));
    final b = encodeFrame(frameTypeImage, image);
    final both = Uint8List(a.length + b.length)..setRange(0, a.length, a)..setRange(a.length, a.length + b.length, b);
    final types = <int>[];
    parser.push(both, (type, payload) {
      types.add(type);
      if (type == frameTypeImage) {
        final parsed = ImagePayload.parse(payload)!;
        expect(parsed.seq, 57);
        expect(parsed.full, isFalse);
        expect(parsed.jpeg, [0xff, 0xd8, 0xff, 0xd9]);
      }
    });
    expect(types, [frameTypeJson, frameTypeImage]);
  });

  test('a ridiculous length resets the buffer', () {
    final parser = StreamParser();
    parser.push(Uint8List.fromList([1, 0xff, 0xff, 0xff, 0x7f]), (_, _) {});
    expect(parser.buffered, 0);
  });

  test('presence follows heartbeat windows', () {
    expect(presenceOf(ageSeconds: 60, heartbeatMin: 30), Presence.online);
    expect(presenceOf(ageSeconds: 5000, heartbeatMin: 30), Presence.late);
    expect(presenceOf(ageSeconds: 8000, heartbeatMin: 30), Presence.offline);
    expect(presenceOf(ageSeconds: null, heartbeatMin: 30), Presence.unknown);
  });

  test('health bits and battery warnings', () {
    final notes = healthNotes(soc: 4, charge: 'fast charging', hwOk: 127 & ~hwCamera, fsFreeKb: 800, rssi: -120, snr: -12, ntc: 'cold', qiMv: 0);
    expect(notes.map((note) => note.message), contains('Battery critical — node has stopped watching'));
    expect(notes.map((note) => note.message), contains('Camera problem'));
    expect(notes.map((note) => note.message), isNot(contains('Too cold to charge — charging paused')));
    expect(notes.map((note) => note.message), isNot(contains('On the Qi pad')));
    final onPad = healthNotes(soc: 40, charge: 'fast charging', ntc: 'cold', qiMv: 5100);
    expect(onPad.map((note) => note.message), contains('Too cold to charge — charging paused'));
    expect(onPad.map((note) => note.message), contains('On the Qi pad'));
    expect(isCharging('fast charging', qiMv: 2800), isFalse);
    expect(isCharging('charged', qiMv: 5100), isFalse);
    expect(isCharging('fast charging', qiMv: 5100), isTrue);
    expect(healthNotes(soc: 80, charge: 'fast charging', hwOk: 127).map((note) => note.message), isEmpty);
  });

  test('commands are queued copy and quiet hours wrap midnight', () {
    final eta = pendingEta(
      lastSeen: DateTime(2026, 1, 1, 12),
      heartbeatMin: 30,
      motionLikely: false,
      now: DateTime(2026, 1, 1, 12, 10),
    );
    expect(eta, contains('20 min'));
    expect(inQuietHours(DateTime(2026, 1, 1, 23), 22, 7), isTrue);
    expect(inQuietHours(DateTime(2026, 1, 1, 12), 22, 7), isFalse);
    expect(shouldNotify(pref: NotifyPref.motion, trigger: 'snapshot', quiet: false), isFalse);
  });

  test('simulated handheld speaks the framed greeting', () async {
    final service = HandheldService();
    final messages = <AppMessage>[];
    service.onMessage = (message, _) => messages.add(message);
    await service.start(mock: true);
    expect(messages.whereType<HandheldState>(), isNotEmpty);
    expect(messages.whereType<NodesMessage>().single.nodes.map((node) => node.node), [1, 2, 3]);
    expect(messages.whereType<WifiState>().single.on, isFalse);
    final page = await service.command({'cmd': 'events', 'limit': 10});
    expect(page, isA<EventsMessage>());
    expect((page as EventsMessage).events, isNotEmpty);
    await service.stop();
  });

  test('a review scenario emits a camera-failure alert', () async {
    final service = HandheldService();
    final alerts = <LiveEvent>[];
    service.onMessage = (message, _) {
      if (message is LiveEvent) alerts.add(message);
    };
    await service.start(mock: true);
    service.runScenario('camera_fail');
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(alerts.where((alert) => alert.cameraFailed), isNotEmpty);
    await service.stop();
  });

  test('event json keeps the handheld seq', () {
    final message = AppMessage.parse(
      '{"t":"image","seq":57,"node":3,"event_id":41,"trigger":"pir","time":0,"received":1758630131,"via":"lora","rssi":-97.5,"image":true,"full":false,"bytes":6123}',
    );
    expect(message, isA<ArchiveEvent>());
    final event = message as ArchiveEvent;
    expect(event.seq, 57);
    expect(event.rssi, -97.5);
    expect(eventWhen(event.time, event.received).$2, isTrue);
  });
}
