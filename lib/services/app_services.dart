import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:path_provider/path_provider.dart';

import '../core/link/link_session.dart';
import '../core/link/tcp_transport.dart';
import '../core/link/transport.dart';
import '../core/link/usb_transport.dart';
import '../core/util.dart';
import '../data/settings.dart';
import '../data/transaction_store.dart';
import '../features/cashier/cashier_controller.dart';
import '../features/terminal/terminal_controller.dart';
import '../payment/mock_payment_adapter.dart';
import '../payment/payment_adapter.dart';

const appVersion = '1.0.0';

/// Owns the link, the journal and the role controller, and rebuilds them when the role or
/// connection settings change.
class AppServices extends ChangeNotifier {
  AppServices._(this.settings, this.log, this.deviceInfo);

  static Future<AppServices> create() async {
    final services = AppServices._(await AppSettings.load(), AppLog(), await NativeUsb.deviceInfo());
    await services.reconfigure();
    return services;
  }

  final AppSettings settings;
  final AppLog log;
  final Map<String, dynamic> deviceInfo;

  LinkSession? session;
  TransactionStore? store;
  CashierController? cashier;
  TerminalController? terminal;
  PaymentAdapter? payment;
  Future<void> _queue = Future.value();

  bool get ready => session != null && store != null;

  String get deviceLabel {
    final s = '${deviceInfo['manufacturer'] ?? ''} ${deviceInfo['model'] ?? ''}'.trim();
    return s.isEmpty ? 'This device' : s;
  }

  /// P-series (P2, P3…) are Sunmi's payment terminals; anything else is assumed to be the cashier.
  AppRole get suggestedRole {
    final model = (deviceInfo['model'] as String? ?? '').toUpperCase();
    return RegExp(r'^P\d').hasMatch(model) || model.contains(' P3') || model.contains(' P2')
        ? AppRole.terminal
        : AppRole.cashier;
  }

  Future<void> reconfigure() => _queue = _queue.then((_) => _reconfigure());

  Future<void> _reconfigure() async {
    await _teardown();
    final role = settings.role;
    if (role == null) {
      notifyListeners();
      return;
    }

    final dir = await getApplicationSupportDirectory();
    final store = TransactionStore(file: File('${dir.path}/transactions_${role.name}.json'));
    await store.load();

    final Transport transport = switch (settings.linkType) {
      LinkType.usb => UsbTransport(host: role == AppRole.cashier),
      LinkType.tcp => role == AppRole.cashier
          ? TcpTransport.client(host: settings.tcpHost, port: settings.tcpPort)
          : TcpTransport.server(port: settings.tcpPort),
    };
    final session = LinkSession(
      transport: transport,
      localInfo: {
        'role': role.name,
        'manufacturer': deviceInfo['manufacturer'],
        'model': deviceInfo['model'],
        'appVersion': appVersion,
      },
      log: log,
    );

    if (role == AppRole.cashier) {
      cashier = CashierController(session: session, store: store, currency: settings.currency, log: log);
      await cashier!.start();
    } else {
      payment = MockPaymentAdapter();
      terminal = TerminalController(session: session, store: store, payment: payment!, log: log);
      await terminal!.start();
    }
    this.session = session;
    this.store = store;
    notifyListeners();
    await session.start();
  }

  Future<void> _teardown() async {
    final oldSession = session;
    final oldCashier = cashier;
    final oldTerminal = terminal;
    final oldStore = store;
    session = null;
    store = null;
    cashier = null;
    terminal = null;
    payment = null;
    if (oldSession == null) return;
    notifyListeners();
    // Let the UI drop its listeners before the old objects are disposed.
    await SchedulerBinding.instance.endOfFrame;
    await oldSession.stop();
    oldCashier?.dispose();
    oldTerminal?.dispose();
    oldSession.dispose();
    oldStore?.dispose();
  }
}
