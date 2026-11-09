import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AppRole {
  /// Enters the amount and asks for payment (e.g. Flex 3). USB host.
  cashier,

  /// Takes the card (e.g. P3). USB accessory.
  terminal,
}

enum LinkType { usb, tcp }

class AppSettings extends ChangeNotifier {
  AppSettings(this._prefs);

  static Future<AppSettings> load() async => AppSettings(await SharedPreferences.getInstance());

  final SharedPreferences _prefs;

  AppRole? get role => switch (_prefs.getString('role')) {
        'cashier' => AppRole.cashier,
        'terminal' => AppRole.terminal,
        _ => null,
      };

  LinkType get linkType => _prefs.getString('linkType') == 'tcp' ? LinkType.tcp : LinkType.usb;

  /// Terminal address, used by the cashier when [linkType] is TCP.
  String get tcpHost => _prefs.getString('tcpHost') ?? '192.168.1.50';
  int get tcpPort => _prefs.getInt('tcpPort') ?? 8765;
  String get currency => _prefs.getString('currency') ?? 'LYD';

  Future<void> setRole(AppRole role) => _set(() => _prefs.setString('role', role.name));
  Future<void> setLinkType(LinkType type) => _set(() => _prefs.setString('linkType', type.name));
  Future<void> setTcp({required String host, required int port}) => _set(() async {
        await _prefs.setString('tcpHost', host);
        await _prefs.setInt('tcpPort', port);
      });
  Future<void> setCurrency(String currency) => _set(() => _prefs.setString('currency', currency));

  Future<void> _set(Future<void> Function() write) async {
    await write();
    notifyListeners();
  }
}
