import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../protocol/json_read.dart';
import '../protocol/messages.dart';
import '../protocol/stream_parser.dart';
import '../protocol/uuids.dart';
import '../link/ble_handheld.dart';
import '../link/frame_source.dart';
import '../link/mock_handheld.dart';

/// Owns the link, the stream parser, and command/response matching.
/// Screens never touch BLE themselves.
class HandheldService {
  FrameSource? _source;
  StreamSubscription<List<int>>? _bytes;
  final _parser = StreamParser();
  final _wait = <int, Completer<AppMessage>>{};
  var _rid = 0;
  var _generation = 0;
  var _userStop = false;
  var _backoffStep = 0;
  var _mock = false;
  String? _deviceId;
  Timer? _retry;
  Timer? _clock;

  void Function(LinkPhase phase, String? detail)? onPhase;
  void Function(AppMessage message, String raw)? onMessage;
  void Function(ImagePayload image)? onImage;
  void Function(int received, int total)? onProgress;
  Future<void> Function()? onLive;

  bool get isMock => _mock;

  Future<void> start({required bool mock, String? deviceId}) async {
    final generation = ++_generation;
    _userStop = false;
    _mock = mock;
    _deviceId = deviceId;
    _backoffStep = 0;
    await _teardown();
    if (generation != _generation) return;
    await _connect(generation);
  }

  Future<void> stop() async {
    _generation++;
    _userStop = true;
    _retry?.cancel();
    await _teardown();
    onPhase?.call(LinkPhase.idle, null);
  }

  void simulateMotion() => _source?.simulateMotion();

  void runScenario(String name) => _source?.runScenario(name);

  Future<AppMessage> command(Map<String, Object?> body, {Duration? timeout}) {
    final rid = ++_rid;
    body['rid'] = rid;
    final bytes = utf8.encode(jsonEncode(body));
    if (bytes.length > maxCommandBytes) {
      return Future.error(CommandException('That command does not fit in one BLE write.'));
    }
    final completer = Completer<AppMessage>();
    _wait[rid] = completer;
    final limit = timeout ?? (body['cmd'] == 'get_image' ? const Duration(seconds: 30) : const Duration(seconds: 5));
    final source = _source;
    if (source == null) {
      _wait.remove(rid);
      return Future.error(CommandException('Not connected to the handheld.'));
    }
    source.write(bytes).catchError((Object error) {
      if (!completer.isCompleted) {
        _wait.remove(rid);
        completer.completeError(CommandException('Could not send the command.'));
      }
    });
    return completer.future.timeout(limit, onTimeout: () {
      _wait.remove(rid);
      throw CommandException('No response. It may still be queued — check the node after the next check-in.');
    });
  }

  Future<void> _connect(int generation) async {
    if (_userStop || generation != _generation) return;
    onPhase?.call(
      _backoffStep == 0 ? LinkPhase.connecting : LinkPhase.reconnecting,
      _mock
          ? 'Starting a simulated handheld'
          : 'Connecting. If asked for a PIN, use the one printed for this handheld. It is not in the app.',
    );
    final FrameSource source = _mock ? MockHandheld() : BleHandheld(_deviceId ?? '');
    _source = source;
    _parser.reset();
    _bytes = source.incoming.listen(_onChunk);
    try {
      if (!_mock && (_deviceId == null || _deviceId!.isEmpty)) {
        throw CommandException('Pair the handheld first.');
      }
      await source.start();
    } catch (error) {
      await _lost(generation, '$error');
      return;
    }
    if (generation != _generation || _userStop) return;
    _backoffStep = 0;
    source.watchDisconnect((reason) {
      unawaited(_lost(generation, reason));
    });
    onPhase?.call(LinkPhase.syncing, 'Syncing the archive');
    _clock?.cancel();
    _clock = Timer.periodic(const Duration(hours: 1), (_) {
      unawaited(command({
        'cmd': 'time',
        'unix': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      }).catchError((_) => const UnknownMessage(raw: '')));
    });
    try {
      await onLive?.call();
    } catch (_) {}
    if (generation != _generation || _userStop) return;
    onPhase?.call(LinkPhase.live, _mock ? 'Simulated handheld' : 'Connected');
  }

  Future<void> _lost(int generation, String reason) async {
    if (_userStop || generation != _generation) return;
    _generation++;
    final next = _generation;
    await _teardown();
    _parser.reset();
    _failPending();
    const waits = [1, 2, 5, 10, 30];
    final seconds = waits[_backoffStep.clamp(0, waits.length - 1)];
    if (_backoffStep < waits.length - 1) _backoffStep++;
    onPhase?.call(LinkPhase.reconnecting, '$reason Retrying in ${seconds}s.');
    _retry?.cancel();
    _retry = Timer(Duration(seconds: seconds), () {
      if (!_userStop && next == _generation) unawaited(_connect(next));
    });
  }

  void _onChunk(List<int> chunk) {
    _parser.push(
      Uint8List.fromList(chunk),
      (type, payload) {
        if (type == frameTypeJson) {
          final raw = utf8.decode(payload, allowMalformed: true);
          AppMessage message;
          try {
            message = AppMessage.parse(raw);
          } catch (_) {
            message = UnknownMessage(raw: raw);
          }
          final rid = message.rid;
          final waiting = rid == null ? null : _wait.remove(rid);
          onMessage?.call(message, redactSecrets(raw));
          if (waiting != null && !waiting.isCompleted) waiting.complete(message);
        } else if (type == frameTypeImage) {
          final image = ImagePayload.parse(payload);
          if (image != null) onImage?.call(image);
        }
      },
      onProgress: onProgress,
    );
  }

  Future<void> _teardown() async {
    _clock?.cancel();
    _retry?.cancel();
    _failPending();
    await _bytes?.cancel();
    _bytes = null;
    final source = _source;
    _source = null;
    await source?.stop();
  }

  void _failPending() {
    for (final waiting in _wait.values) {
      if (!waiting.isCompleted) {
        waiting.completeError(CommandException('The handheld disconnected.'));
      }
    }
    _wait.clear();
  }
}
