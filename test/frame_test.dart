import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sunmi_usb/core/protocol/frame.dart';
import 'package:sunmi_usb/core/util.dart';

Frame _frame(int seq, String json) =>
    Frame(type: 0x20, seq: seq, payload: Uint8List.fromList(utf8.encode(json)));

void main() {
  group('frame codec', () {
    test('round trip', () {
      final bytes = encodeFrame(_frame(7, '{"amount":12500}'));
      final frames = FrameDecoder().add(bytes);
      expect(frames, hasLength(1));
      expect(frames.single.type, 0x20);
      expect(frames.single.seq, 7);
      expect(utf8.decode(frames.single.payload), '{"amount":12500}');
    });

    test('CRC-16/CCITT-FALSE check value', () {
      expect(crc16(ascii.encode('123456789')), 0x29B1);
    });

    test('bytes match the Python reference in tools/aoa_probe.py', () {
      final bytes = encodeFrame(_frame(7, '{"amount":12500}'));
      final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      expect(hex, '020120000700107b22616d6f756e74223a31323530307dbe65');
    });

    test('reassembles frames delivered one byte at a time', () {
      final bytes = [...encodeFrame(_frame(1, '{"a":1}')), ...encodeFrame(_frame(2, '{"b":2}'))];
      final decoder = FrameDecoder();
      final frames = <Frame>[];
      for (final b in bytes) {
        frames.addAll(decoder.add([b]));
      }
      expect(frames.map((f) => f.seq), [1, 2]);
    });

    test('skips garbage and resynchronises after a corrupted frame', () {
      final good1 = encodeFrame(_frame(1, '{"ok":1}'));
      final bad = encodeFrame(_frame(2, '{"ok":2}'))..[9] ^= 0xFF;
      final good2 = encodeFrame(_frame(3, '{"ok":3}'));
      final decoder = FrameDecoder();
      final frames = decoder.add([0x55, 0xAA, ...good1, 0x13, ...bad, ...good2]);
      expect(frames.map((f) => f.seq), [1, 3]);
      expect(decoder.crcErrors, 1);
    });

    test('never emits a frame whose length is a multiple of 64 (USB ZLP rule)', () {
      // 7 header + 55 payload + 2 CRC = 64 bytes → one pad byte is added.
      final payload = '"${'x' * 53}"';
      expect(payload.length, 55);
      final bytes = encodeFrame(_frame(9, payload));
      expect(bytes.length, 65);
      expect(bytes.last, 0);
      final decoder = FrameDecoder();
      final frames = decoder.add([...bytes, ...encodeFrame(_frame(10, '{}'))]);
      expect(frames.map((f) => f.seq), [9, 10]);
      expect(decoder.discardedBytes, 0);
    });

    test('rejects oversized payloads', () {
      expect(
        () => encodeFrame(Frame(type: 1, seq: 1, payload: Uint8List(kMaxPayload + 1))),
        throwsArgumentError,
      );
    });
  });

  group('money', () {
    test('LYD has three decimals', () {
      expect(formatMoney(12500, 'LYD'), '12.500 LYD');
      expect(formatMoney(5, 'LYD'), '0.005 LYD');
      expect(formatMoney(123456789, 'LYD'), '123,456.789 LYD');
    });

    test('USD has two decimals', () {
      expect(formatMoney(1999, 'USD'), '19.99 USD');
    });
  });

  test('uuidV4 format', () {
    expect(
      uuidV4(),
      matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')),
    );
  });
}
