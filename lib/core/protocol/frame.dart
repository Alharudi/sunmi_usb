import 'dart:typed_data';

/// Wire format of one frame:
///
/// | STX 0x02 | version | type | seq (u16 BE) | length (u16 BE) | payload | CRC16 (u16 BE) |
///
/// CRC-16/CCITT-FALSE (poly 0x1021, init 0xFFFF) over version..payload.
/// The payload is UTF-8 JSON (may be empty).
const int kStx = 0x02;
const int kProtocolVersion = 1;
const int kHeaderLength = 7;
const int kCrcLength = 2;
const int kMaxPayload = 8192;

/// USB bulk pipes treat a transfer that is an exact multiple of the max packet size as
/// unfinished unless a zero-length packet follows, so the reader can stall. Rather than rely on
/// ZLP handling on both sides we never emit such a frame: we append one 0x00 pad byte, which the
/// decoder skips while looking for the next STX. 64 covers full-speed (64) and high-speed (512).
const int kPacketAlign = 64;

class Frame {
  const Frame({
    required this.type,
    required this.seq,
    required this.payload,
    this.version = kProtocolVersion,
  });

  final int version;
  final int type;
  final int seq;
  final Uint8List payload;
}

int crc16(List<int> data, [int start = 0, int? end]) {
  var crc = 0xFFFF;
  final stop = end ?? data.length;
  for (var i = start; i < stop; i++) {
    crc ^= (data[i] & 0xFF) << 8;
    for (var b = 0; b < 8; b++) {
      crc = (crc & 0x8000) != 0 ? ((crc << 1) ^ 0x1021) & 0xFFFF : (crc << 1) & 0xFFFF;
    }
  }
  return crc;
}

Uint8List encodeFrame(Frame frame) {
  final payloadLength = frame.payload.length;
  if (payloadLength > kMaxPayload) {
    throw ArgumentError('Payload of $payloadLength bytes exceeds $kMaxPayload');
  }
  final length = kHeaderLength + payloadLength + kCrcLength;
  final pad = length % kPacketAlign == 0 ? 1 : 0;
  final out = Uint8List(length + pad);
  final view = ByteData.sublistView(out);
  out[0] = kStx;
  out[1] = frame.version;
  out[2] = frame.type;
  view.setUint16(3, frame.seq & 0xFFFF);
  view.setUint16(5, payloadLength);
  out.setRange(kHeaderLength, kHeaderLength + payloadLength, frame.payload);
  view.setUint16(kHeaderLength + payloadLength, crc16(out, 1, kHeaderLength + payloadLength));
  return out;
}

/// Reassembles frames from an arbitrary byte stream (chunks may split or merge frames).
/// Resynchronises on the next STX after garbage or a CRC failure.
class FrameDecoder {
  Uint8List _buffer = Uint8List(0);
  int crcErrors = 0;
  int discardedBytes = 0;

  List<Frame> add(List<int> chunk) {
    final data = Uint8List(_buffer.length + chunk.length)
      ..setAll(0, _buffer)
      ..setAll(_buffer.length, chunk);
    final frames = <Frame>[];
    var i = 0;
    while (true) {
      while (i < data.length && data[i] != kStx) {
        if (data[i] != 0) discardedBytes++;
        i++;
      }
      if (data.length - i < kHeaderLength) break;
      final payloadLength = (data[i + 5] << 8) | data[i + 6];
      if (payloadLength > kMaxPayload) {
        discardedBytes++;
        i++;
        continue;
      }
      final total = kHeaderLength + payloadLength + kCrcLength;
      if (data.length - i < total) break;
      final crcEnd = i + kHeaderLength + payloadLength;
      final expected = (data[crcEnd] << 8) | data[crcEnd + 1];
      if (crc16(data, i + 1, crcEnd) != expected) {
        crcErrors++;
        i++;
        continue;
      }
      frames.add(Frame(
        version: data[i + 1],
        type: data[i + 2],
        seq: (data[i + 3] << 8) | data[i + 4],
        payload: Uint8List.fromList(data.sublist(i + kHeaderLength, crcEnd)),
      ));
      i += total;
    }
    _buffer = Uint8List.fromList(data.sublist(i));
    return frames;
  }

  void reset() => _buffer = Uint8List(0);
}
