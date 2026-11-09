import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/link/usb_transport.dart';
import '../../data/settings.dart';
import '../../services/app_services.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.services});

  final AppServices services;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _host;
  late final TextEditingController _port;
  Future<List<UsbDeviceInfo>>? _devices;

  AppServices get services => widget.services;
  AppSettings get settings => services.settings;

  @override
  void initState() {
    super.initState();
    _host = TextEditingController(text: settings.tcpHost);
    _port = TextEditingController(text: settings.tcpPort.toString());
    _devices = NativeUsb.listDevices();
  }

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListenableBuilder(
        listenable: services,
        builder: (context, _) {
          final role = settings.role;
          return ListView(
            padding: const EdgeInsets.only(bottom: 32),
            children: [
              _section('This device'),
              _deviceInfo(),
              _section('Role'),
              ListTile(
                leading: Icon(role == AppRole.terminal ? Icons.contactless_outlined : Icons.point_of_sale),
                title: Text(role == AppRole.terminal ? 'Payment terminal' : 'Cashier'),
                subtitle: Text(role == AppRole.terminal
                    ? 'Takes cards. USB accessory side.'
                    : 'Sends amounts. USB host side.'),
                trailing: TextButton(onPressed: _changeRole, child: const Text('Change')),
              ),
              _section('Connection'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: SegmentedButton<LinkType>(
                  segments: const [
                    ButtonSegment(value: LinkType.usb, icon: Icon(Icons.usb), label: Text('USB cable')),
                    ButtonSegment(value: LinkType.tcp, icon: Icon(Icons.wifi), label: Text('Wi-Fi / LAN')),
                  ],
                  selected: {settings.linkType},
                  onSelectionChanged: (s) async {
                    await settings.setLinkType(s.first);
                    await services.reconfigure();
                  },
                ),
              ),
              if (settings.linkType == LinkType.tcp) ..._tcpSettings(role),
              if (settings.linkType == LinkType.usb && role == AppRole.cashier) ..._usbDevices(),
              _section('Diagnostics'),
              ..._diagnostics(),
              _section('Data'),
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('Clear transaction history'),
                subtitle: const Text('Also removes duplicate-payment protection for old sales'),
                onTap: _clearHistory,
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 4),
        child: Text(title, style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary)),
      );

  Widget _deviceInfo() {
    final info = services.deviceInfo;
    String yesNo(Object? v) => v == true ? 'yes' : (v == false ? 'no' : '?');
    return ListTile(
      leading: const Icon(Icons.phone_android),
      title: Text(services.deviceLabel),
      subtitle: Text(
        'Android ${info['release'] ?? '?'} (API ${info['sdkInt'] ?? '?'})\n'
        'USB host: ${yesNo(info['usbHost'])} · USB accessory: ${yesNo(info['usbAccessory'])} · App $appVersion',
      ),
      isThreeLine: true,
    );
  }

  List<Widget> _tcpSettings(AppRole? role) {
    final isCashier = role == AppRole.cashier;
    return [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            if (isCashier) ...[
              Expanded(
                flex: 3,
                child: TextField(
                  controller: _host,
                  decoration: const InputDecoration(labelText: 'Terminal IP address', border: OutlineInputBorder()),
                  keyboardType: TextInputType.url,
                ),
              ),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: TextField(
                controller: _port,
                decoration: const InputDecoration(labelText: 'Port', border: OutlineInputBorder()),
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              ),
            ),
            const SizedBox(width: 12),
            FilledButton(onPressed: _applyTcp, child: const Text('Apply')),
          ],
        ),
      ),
      if (!isCashier)
        FutureBuilder<List<NetworkInterface>>(
          future: NetworkInterface.list(type: InternetAddressType.IPv4),
          builder: (context, snap) {
            final ips = [
              for (final i in snap.data ?? const <NetworkInterface>[])
                for (final a in i.addresses) a.address,
            ];
            return ListTile(
              leading: const Icon(Icons.lan_outlined),
              title: const Text('Enter this address on the cashier'),
              subtitle: Text(ips.isEmpty ? 'No network address' : ips.join(', ')),
            );
          },
        ),
    ];
  }

  List<Widget> _usbDevices() {
    return [
      ListTile(
        title: const Text('USB devices'),
        subtitle: const Text('Pick the terminal once; it is then reconnected automatically.'),
        trailing: IconButton(
          tooltip: 'Refresh',
          icon: const Icon(Icons.refresh),
          onPressed: () => setState(() => _devices = NativeUsb.listDevices()),
        ),
      ),
      FutureBuilder<List<UsbDeviceInfo>>(
        future: _devices,
        builder: (context, snap) {
          final list = snap.data ?? const [];
          if (snap.connectionState != ConnectionState.done) {
            return const Padding(padding: EdgeInsets.all(16), child: LinearProgressIndicator());
          }
          if (list.isEmpty) {
            return const ListTile(dense: true, title: Text('No USB devices attached'));
          }
          return Column(
            children: [
              for (final d in list)
                ListTile(
                  leading: Icon(d.accessoryMode ? Icons.link : Icons.usb),
                  title: Text(d.title),
                  subtitle: Text([
                    d.ids,
                    if (d.accessoryMode) 'in accessory mode',
                    if (d.hasPermission) 'permission granted',
                  ].join(' · ')),
                  trailing: d.accessoryMode
                      ? null
                      : TextButton(
                          onPressed: () async {
                            final ok = await NativeUsb.connectDevice(d.deviceName);
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                              content: Text(ok ? 'Connecting to ${d.title}…' : 'Switch to USB first'),
                            ));
                          },
                          child: const Text('Use as terminal'),
                        ),
                ),
            ],
          );
        },
      ),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: TextButton(
            onPressed: () async {
              await NativeUsb.forgetDevices();
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Remembered terminal cleared')));
            },
            child: const Text('Forget remembered terminal'),
          ),
        ),
      ),
    ];
  }

  List<Widget> _diagnostics() {
    final session = services.session;
    if (session == null) return const [ListTile(title: Text('Link not running'))];
    return [
      ListenableBuilder(
        listenable: session,
        builder: (context, _) {
          final s = session.stats;
          return ListTile(
            leading: const Icon(Icons.monitor_heart_outlined),
            title: Text('${session.transport.name}: ${session.status.name}'),
            subtitle: Text(
              [
                if (session.problem != null) session.problem!,
                'Transport: ${session.transportState}',
                if (session.peer != null) 'Peer: ${session.peer!.description} (${session.peer!.role}, app ${session.peer!.appVersion})',
                'Frames sent ${s.framesSent} · received ${s.framesReceived}',
                'Retries ${s.retries} · failed ${s.failedSends} · duplicates ${s.duplicates} · '
                'held heartbeats ${s.heldHeartbeats} · CRC errors ${session.crcErrors}',
              ].join('\n'),
            ),
            isThreeLine: true,
          );
        },
      ),
      ListTile(
        leading: const Icon(Icons.article_outlined),
        title: const Text('Link log'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => LogScreen(services: services))),
      ),
      ListTile(
        leading: const Icon(Icons.restart_alt),
        title: const Text('Restart link'),
        onTap: services.reconfigure,
      ),
    ];
  }

  Future<void> _changeRole() async {
    final selected = await showDialog<AppRole>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Use this device as'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, AppRole.cashier),
            child: const ListTile(leading: Icon(Icons.point_of_sale), title: Text('Cashier'), subtitle: Text('e.g. Flex 3')),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, AppRole.terminal),
            child: const ListTile(
              leading: Icon(Icons.contactless_outlined),
              title: Text('Payment terminal'),
              subtitle: Text('e.g. P3'),
            ),
          ),
        ],
      ),
    );
    if (selected == null || selected == settings.role) return;
    await settings.setRole(selected);
    await services.reconfigure();
    if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
  }

  Future<void> _applyTcp() async {
    final port = int.tryParse(_port.text);
    if (port == null || port < 1 || port > 65535) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Port must be 1–65535')));
      return;
    }
    await settings.setTcp(host: _host.text.trim(), port: port);
    await services.reconfigure();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Connection settings applied')));
    }
  }

  Future<void> _clearHistory() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear history?'),
        content: const Text('All stored transactions on this device will be deleted.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Clear')),
        ],
      ),
    );
    if (ok == true) await services.store?.clear();
  }
}

class LogScreen extends StatelessWidget {
  const LogScreen({super.key, required this.services});

  final AppServices services;

  @override
  Widget build(BuildContext context) {
    final log = services.log;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Link log'),
        actions: [
          IconButton(
            tooltip: 'Copy',
            icon: const Icon(Icons.copy),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: log.entries.join('\n')));
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Log copied')));
            },
          ),
          IconButton(tooltip: 'Clear', icon: const Icon(Icons.delete_sweep_outlined), onPressed: log.clear),
        ],
      ),
      body: ListenableBuilder(
        listenable: log,
        builder: (context, _) {
          final entries = log.entries.reversed.toList();
          return ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: entries.length,
            itemBuilder: (context, i) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: SelectableText(
                entries[i].toString(),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
          );
        },
      ),
    );
  }
}
