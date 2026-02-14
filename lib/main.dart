import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'services/device_info_service.dart';
import 'services/discovery_service.dart';
import 'services/websocket_service.dart';
import 'services/command_executor.dart';
import 'services/event_emitter.dart';
import 'services/logging_service.dart';
import 'services/browser_launcher_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  final loggingService = LoggingService();
  final deviceInfoService = DeviceInfoService();
  await deviceInfoService.init();
  
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: loggingService),
        Provider.value(value: deviceInfoService),
        Provider(create: (_) => WebSocketService()),
        Provider(create: (_) => CommandExecutor()),
        ChangeNotifierProvider(create: (_) => BrowserLauncherService()),
        ProxyProvider<WebSocketService, EventEmitter>(
          update: (_, ws, __) => EventEmitter(ws),
        ),
        ProxyProvider<DeviceInfoService, DiscoveryService>(
          update: (_, info, __) => DiscoveryService(info),
        ),
      ],
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Autonion Agent',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueAccent, brightness: Brightness.dark),
        useMaterial3: true,
      ),
      home: const AgentHomePage(),
    );
  }
}

class AgentHomePage extends StatefulWidget {
  const AgentHomePage({super.key});

  @override
  State<AgentHomePage> createState() => _AgentHomePageState();
}

class _AgentHomePageState extends State<AgentHomePage> {
  bool _isAdvertising = false;
  int? _port;
  StreamSubscription? _commandSubscription;
  StreamSubscription<String>? _clipboardSyncSubscription;

  @override
  void initState() {
    super.initState();
    // Auto-start on load
    WidgetsBinding.instance.addPostFrameCallback((_) => _startServices());
  }

  Future<void> _startServices() async {
    final wsService = context.read<WebSocketService>();
    final discoveryService = context.read<DiscoveryService>();
    final loggingService = context.read<LoggingService>();
    final commandExecutor = context.read<CommandExecutor>();
    final browserLauncher = context.read<BrowserLauncherService>();

    loggingService.log('Starting services...');

    try {
      // Wire logging and dependencies
      wsService.setLoggingService(loggingService);
      discoveryService.setLoggingService(loggingService);
      commandExecutor.setLoggingService(loggingService);
      commandExecutor.setWebSocketService(wsService);
      commandExecutor.setBrowserLauncherService(browserLauncher);
      browserLauncher.setLoggingService(loggingService);

      // Detect installed browsers
      await browserLauncher.detectBrowsers();

      // 1. Start WebSocket Server
      _port = await wsService.startServer();
      loggingService.log('WebSocket Server started on port $_port');

      // 2. Start Advertising
      await discoveryService.startAdvertising(_port!);
      loggingService.log('mDNS Advertising started: _myautomation._tcp.local');

      setState(() {
        _isAdvertising = true;
      });

      // 3. Listen for commands
      _commandSubscription = wsService.commandStream.listen((command) {
        loggingService.log('Received command: $command');
        commandExecutor.execute(command);
      });

      // 4. Listen for clipboard sync events to show snackbar
      _clipboardSyncSubscription = commandExecutor.clipboardSyncStream.listen((text) {
        if (mounted) {
          final preview = text.length > 60 ? '${text.substring(0, 60)}...' : text;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Row(
                children: [
                  const Icon(Icons.content_paste, color: Colors.white, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Clipboard synced: "$preview"',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              backgroundColor: Colors.green.shade700,
              duration: const Duration(seconds: 3),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      });

    } catch (e) {
      loggingService.log('Error starting services: $e');
    }
  }

  Future<void> _stopServices() async {
    final wsService = context.read<WebSocketService>();
    final discoveryService = context.read<DiscoveryService>();
    final loggingService = context.read<LoggingService>();

    loggingService.log('Stopping services...');
    await discoveryService.stopAdvertising();
    await wsService.stopServer();
    await _commandSubscription?.cancel();
    await _clipboardSyncSubscription?.cancel();

    setState(() {
      _isAdvertising = false;
      _port = null;
    });
    loggingService.log('Services stopped');
  }

  @override
  void dispose() {
    _stopServices();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final deviceInfo = context.watch<DeviceInfoService>();
    final logs = context.watch<LoggingService>().logs;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Autonion Agent'),
        actions: [
          IconButton(
            icon: Icon(_isAdvertising ? Icons.stop_circle_outlined : Icons.play_circle_outline),
            onPressed: _isAdvertising ? _stopServices : _startServices,
            tooltip: _isAdvertising ? 'Stop Services' : 'Start Services',
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () => context.read<LoggingService>().clearLogs(),
            tooltip: 'Clear Logs',
          )
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Status Card
            Card(
              elevation: 4,
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.circle,
                          color: _isAdvertising ? Colors.green : Colors.red,
                          size: 16,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _isAdvertising ? 'Online & Advertising' : 'Offline',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ],
                    ),
                    const Divider(),
                    _InfoRow(label: 'Device Name', value: deviceInfo.deviceName),
                    _InfoRow(label: 'Device ID', value: deviceInfo.deviceId.substring(0, 8) + '...'), // Shorten UUID
                    _InfoRow(label: 'Platform', value: deviceInfo.platform),
                    FutureBuilder<List<NetworkInterface>>(
                      future: NetworkInterface.list(type: InternetAddressType.IPv4),
                      builder: (context, snapshot) {
                        if (snapshot.hasData && snapshot.data!.isNotEmpty) {
                          final ips = <String>[];
                          for (var interface in snapshot.data!) {
                             for (var addr in interface.addresses) {
                               if (!addr.isLoopback) {
                                 ips.add('${interface.name}: ${addr.address}');
                               }
                             }
                          }
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Padding(
                                padding: EdgeInsets.symmetric(vertical: 4.0),
                                child: Text('Possible IPs:', style: TextStyle(fontWeight: FontWeight.bold)),
                              ),
                              ...ips.map((ip) => Padding(
                                padding: const EdgeInsets.only(left: 8.0, bottom: 2.0),
                                child: Text(ip, style: const TextStyle(fontSize: 12)),
                              )),
                            ],
                          );
                        }
                        return const _InfoRow(label: 'IP Address', value: 'Fetching...');
                      },
                    ),
                    if (_port != null) _InfoRow(label: 'Port', value: _port.toString()),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            // Browser Selector Card
            Consumer<BrowserLauncherService>(
              builder: (context, browserService, _) {
                final browsers = browserService.detectedBrowsers;
                final selected = browserService.selectedBrowser;

                return Card(
                  elevation: 4,
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Row(
                      children: [
                        const Icon(Icons.public, size: 20),
                        const SizedBox(width: 8),
                        const Text('Browser:', style: TextStyle(fontWeight: FontWeight.bold)),
                        const SizedBox(width: 12),
                        Expanded(
                          child: browsers.isEmpty
                              ? const Text('No browsers detected', style: TextStyle(color: Colors.red))
                              : DropdownButton<String>(
                                  value: selected?.name,
                                  isExpanded: true,
                                  underline: const SizedBox(),
                                  items: browsers.map((b) => DropdownMenuItem(
                                    value: b.name,
                                    child: Text(b.name),
                                  )).toList(),
                                  onChanged: (name) {
                                    if (name != null) browserService.selectBrowser(name);
                                  },
                                ),
                        ),
                        const SizedBox(width: 8),
                        // Extension connection indicator
                        Consumer<WebSocketService>(
                          builder: (_, ws, __) => Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.extension,
                                size: 16,
                                color: ws.hasExtensionClient ? Colors.green : Colors.orange,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                ws.hasExtensionClient ? 'Connected' : 'Waiting',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: ws.hasExtensionClient ? Colors.green : Colors.orange,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 12),
            Text('Logs', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            // Logs Console
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black12,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.grey.withOpacity(0.3)),
                ),
                padding: const EdgeInsets.all(8),
                child: ListView.builder(
                  itemCount: logs.length,
                  reverse: true, // Show newest at bottom (or top if we want to stick to bottom) -> actually reverse:true means index 0 is at bottom.
                  // Let's just standard list but scroll to bottom? Or reverse the list?
                  // Providing logs in order (oldest first).
                  // If I use reverse: true, index 0 is bottom. So I need logs.reversed.toList()[index] OR add logs to end and view from bottom.
                  // Easiest is to show newest at TOP for a simple log console if not auto-scrolling. 
                  // Or use Reverse:true and logs.reversed.toList() [idx]. 
                  // Let's just populate newest first in the service?
                  // Checking Logging Service: _logs.add(logEntry). Newest is last.
                  // So user wants to see newest. 
                  // Let's render: reversed logs.
                  itemBuilder: (context, index) {
                    final log = logs[logs.length - 1 - index];
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2.0),
                      child: Text(
                        log,
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;

  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
          Text(value),
        ],
      ),
    );
  }
}
