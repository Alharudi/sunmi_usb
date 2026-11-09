import 'dart:async';

import 'package:flutter/services.dart';

import 'transport.dart';

const _method = MethodChannel('sunmi_usb/link');
const _events = EventChannel('sunmi_usb/link/events');

/// USB link through the native AOA code (android/.../usb).
/// [host] = true on the cashier (USB host), false on the terminal (USB accessory).
class UsbTransport extends TransportBase {
  UsbTransport({required this.host});

  final bool host;
  StreamSubscription<dynamic>? _sub;

  @override
  String get name => host ? 'USB (host)' : 'USB (accessory)';

  @override
  Future<void> start() async {
    _sub ??= _events.receiveBroadcastStream().listen(_onEvent, onError: (Object e) {
      log('USB event error: $e');
    });
    try {
      await _method.invokeMethod<void>('start', {'role': host ? 'host' : 'accessory'});
    } on PlatformException catch (e) {
      setState(TransportStatus.error, e.message);
    } on MissingPluginException {
      setState(TransportStatus.error, 'USB is only available on Android');
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _method.invokeMethod<void>('stop');
    } on MissingPluginException {
      // Not on Android.
    }
    await _sub?.cancel();
    _sub = null;
    setState(TransportStatus.stopped);
  }

  @override
  Future<bool> send(Uint8List data) async {
    try {
      return await _method.invokeMethod<bool>('send', {'data': data}) ?? false;
    } on PlatformException catch (e) {
      log('USB send failed: ${e.message}');
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<void> reset() async {
    try {
      await _method.invokeMethod<void>('reset');
    } on MissingPluginException {
      // Not on Android.
    }
  }

  void _onEvent(dynamic event) {
    if (event is! Map) return;
    switch (event['type']) {
      case 'state':
        setState(_parseStatus(event['state'] as String?), event['detail'] as String?);
      case 'data':
        final data = event['data'];
        if (data is Uint8List) emitData(data);
      case 'log':
        log(event['message'] as String? ?? '');
    }
  }

  static TransportStatus _parseStatus(String? s) => switch (s) {
        'waiting' => TransportStatus.waiting,
        'permission' => TransportStatus.permission,
        'connecting' => TransportStatus.connecting,
        'connected' => TransportStatus.connected,
        'error' => TransportStatus.error,
        _ => TransportStatus.stopped,
      };
}

class UsbDeviceInfo {
  UsbDeviceInfo(Map<dynamic, dynamic> m)
      : deviceName = m['deviceName'] as String? ?? '',
        vendorId = m['vendorId'] as int? ?? 0,
        productId = m['productId'] as int? ?? 0,
        manufacturer = m['manufacturer'] as String?,
        product = m['product'] as String?,
        interfaceCount = m['interfaceCount'] as int? ?? 0,
        accessoryMode = m['accessoryMode'] as bool? ?? false,
        hasPermission = m['hasPermission'] as bool? ?? false;

  final String deviceName;
  final int vendorId;
  final int productId;
  final String? manufacturer;
  final String? product;
  final int interfaceCount;
  final bool accessoryMode;
  final bool hasPermission;

  String get ids =>
      '${vendorId.toRadixString(16).padLeft(4, '0').toUpperCase()}:'
      '${productId.toRadixString(16).padLeft(4, '0').toUpperCase()}';

  String get title {
    final parts = [manufacturer, product].whereType<String>().where((s) => s.isNotEmpty);
    return parts.isEmpty ? 'USB device' : parts.join(' ');
  }
}

/// Device-level helpers exposed by the native side.
abstract final class NativeUsb {
  static Future<Map<String, dynamic>> deviceInfo() async {
    try {
      final m = await _method.invokeMapMethod<String, dynamic>('deviceInfo');
      return m ?? const {};
    } on MissingPluginException {
      return const {};
    }
  }

  static Future<List<UsbDeviceInfo>> listDevices() async {
    try {
      final list = await _method.invokeListMethod<dynamic>('listDevices') ?? const [];
      return list.whereType<Map<dynamic, dynamic>>().map(UsbDeviceInfo.new).toList();
    } on MissingPluginException {
      return const [];
    }
  }

  static Future<bool> connectDevice(String deviceName) async {
    try {
      return await _method.invokeMethod<bool>('connectDevice', {'deviceName': deviceName}) ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<void> forgetDevices() async {
    try {
      await _method.invokeMethod<void>('forgetDevices');
    } on MissingPluginException {
      // Not on Android.
    }
  }
}
