import 'dart:typed_data';

import 'uuids.dart';

typedef FrameHandler = void Function(int type, Uint8List payload);
typedef ProgressHandler = void Function(int received, int total);

/// Reassembles `[type u8][len u32 LE][payload]` from a BLE notification stream.
///
/// A frame can span many notifications, and one notification can end one frame
/// and start the next. Call [reset] on every disconnect.
class StreamParser {
  final List<Uint8List> _chunks = [];
  int _offset = 0;
  int _size = 0;

  int get buffered => _size;

  void reset() {
    _chunks.clear();
    _offset = 0;
    _size = 0;
  }

  void push(Uint8List chunk, FrameHandler onFrame, {ProgressHandler? onProgress}) {
    if (chunk.isEmpty) return;
    _chunks.add(chunk);
    _size += chunk.length;
    while (_size >= 5) {
      final header = _peek(5);
      if (header == null) return;
      final type = header[0];
      final len = header[1] | (header[2] << 8) | (header[3] << 16) | (header[4] << 24);
      if (len > maxFrameBytes) {
        reset();
        return;
      }
      final total = 5 + len;
      if (_size < total) {
        if (type == frameTypeImage) onProgress?.call(_size, total);
        return;
      }
      _consume(5);
      final payload = _peek(len) ?? Uint8List(0);
      _consume(len);
      onFrame(type, payload);
    }
  }

  Uint8List? _peek(int n) {
    if (_size < n) return null;
    final out = Uint8List(n);
    var filled = 0;
    var index = 0;
    var offset = _offset;
    while (filled < n) {
      final chunk = _chunks[index];
      final take = (chunk.length - offset).clamp(0, n - filled);
      out.setRange(filled, filled + take, chunk, offset);
      filled += take;
      index++;
      offset = 0;
    }
    return out;
  }

  void _consume(int n) {
    _size -= n;
    while (n > 0 && _chunks.isNotEmpty) {
      final chunk = _chunks.first;
      final available = chunk.length - _offset;
      if (n >= available) {
        n -= available;
        _chunks.removeAt(0);
        _offset = 0;
      } else {
        _offset += n;
        n = 0;
      }
    }
  }
}

Uint8List encodeFrame(int type, List<int> payload) {
  final body = payload is Uint8List ? payload : Uint8List.fromList(payload);
  final out = Uint8List(5 + body.length);
  final len = body.length;
  out[0] = type & 0xff;
  out[1] = len & 0xff;
  out[2] = (len >> 8) & 0xff;
  out[3] = (len >> 16) & 0xff;
  out[4] = (len >> 24) & 0xff;
  out.setRange(5, out.length, body);
  return out;
}

int _u32(Uint8List bytes, int offset) {
  return (bytes[offset] |
          (bytes[offset + 1] << 8) |
          (bytes[offset + 2] << 16) |
          (bytes[offset + 3] << 24)) &
      0xffffffff;
}

class ImagePayload {
  const ImagePayload({required this.seq, required this.full, required this.jpeg});

  final int seq;
  final bool full;
  final Uint8List jpeg;

  static ImagePayload? parse(Uint8List payload) {
    if (payload.length < 5) return null;
    return ImagePayload(
      seq: _u32(payload, 0),
      full: payload[4] == 1,
      jpeg: Uint8List.sublistView(payload, 5),
    );
  }
}

Uint8List encodeImagePayload(int seq, bool full, Uint8List jpeg) {
  final out = Uint8List(5 + jpeg.length);
  out[0] = seq & 0xff;
  out[1] = (seq >> 8) & 0xff;
  out[2] = (seq >> 16) & 0xff;
  out[3] = (seq >> 24) & 0xff;
  out[4] = full ? 1 : 0;
  out.setRange(5, out.length, jpeg);
  return out;
}
