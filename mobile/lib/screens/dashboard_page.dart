import 'dart:async';
import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../constants.dart';
import '../services/api_service.dart';
import '../services/background_service.dart';
import '../services/notification_service.dart';
import '../widgets/connection_widgets.dart';
import '../widgets/event_widgets.dart';
import '../widgets/monitor_widgets.dart';
import 'locations_page.dart';

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  // ── Backend mode ──────────────────────────────────────────────────────────
  final _apiController = TextEditingController(text: defaultApiBase);
  final _keyController = TextEditingController(text: defaultApiKey);
  final Map<String, bool> _enabled = {};
  List<Map<String, dynamic>> _products = [];
  List<Map<String, dynamic>> _events = [];
  Map<String, dynamic> _status = {};
  bool _connected = false;
  bool _showSettings = true;
  int _lastEventId = 0;

  // ── Direct mode ───────────────────────────────────────────────────────────
  bool _directMode = false;
  List<String> _pincodes = [];
  int _directScansCompleted = 0;
  int _directBlockCount = 0;
  bool _directGloballyPaused = false;
  int _directPauseRemainingSec = 0;
  List<Map<String, dynamic>> _directResults = [];
  String _directLastError = '';

  // ── Shared ────────────────────────────────────────────────────────────────
  Timer? _timer;
  bool _busy = false;
  String _message = 'Switch to Phone-Direct mode (no laptop needed) or connect to a backend.';

  ApiService get _api => ApiService(
        baseUrl: _apiController.text,
        apiKey: _keyController.text,
      );

  @override
  void initState() {
    super.initState();
    unawaited(_loadAllSettings());
    unawaited(initialiseNotifications());
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'myzeptotracker_monitor_service',
        channelName: 'myzeptotracker monitoring',
        channelDescription: 'Persistent notification while inventory monitoring is active.',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(showNotification: false, playSound: false),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(10000), // every 10 s
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
    FlutterForegroundTask.addTaskDataCallback(_onTaskData);
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _refresh(quiet: true));
  }

  Future<void> _loadAllSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final savedUrl = prefs.getString('apiBase');
    final savedKey = prefs.getString('apiKey');
    final savedMode = prefs.getString('mode') ?? 'backend';
    final savedPinsJson = prefs.getString('directPincodes') ?? '[]';
    if (!mounted) return;
    setState(() {
      if (savedUrl != null && savedUrl.isNotEmpty) _apiController.text = savedUrl;
      if (savedKey != null && savedKey.isNotEmpty) _keyController.text = savedKey;
      _directMode = savedMode == 'direct';
      try {
        _pincodes = (jsonDecode(savedPinsJson) as List).map((e) => e.toString()).toList();
      } catch (_) {
        _pincodes = [];
      }
      if (_products.isEmpty) {
        _products = List<Map<String, dynamic>>.from(kDefaultProducts);
        for (final p in _products) {
          _enabled[p['id'].toString()] = p['enabled'] != false;
        }
      }
    });
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('apiBase', _api.base);
    await prefs.setString('apiKey', _keyController.text.trim());
    await prefs.setString('mode', _directMode ? 'direct' : 'backend');
    await prefs.setString('directPincodes', jsonEncode(_pincodes));
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.saveData(key: 'apiBase', value: _api.base);
      await FlutterForegroundTask.saveData(key: 'apiKey', value: _keyController.text.trim());
      await FlutterForegroundTask.saveData(key: 'mode', value: _directMode ? 'direct' : 'backend');
    }
  }

  void _onTaskData(Object data) {
    if (data is! Map) return;
    final type = data['type']?.toString() ?? '';
    if (type == 'poll_ok') {
      final received = int.tryParse(data['latestEventId']?.toString() ?? '0') ?? 0;
      if (received > _lastEventId && mounted) {
        setState(() => _lastEventId = received);
      }
    } else if (type == 'direct_scan_done') {
      final results = (data['results'] as List? ?? []).whereType<Map<String, dynamic>>().toList();
      if (mounted) {
        setState(() {
          _directScansCompleted = data['scansCompleted'] as int? ?? _directScansCompleted;
          _directBlockCount = data['blockCount'] as int? ?? _directBlockCount;
          _directGloballyPaused = data['globallyPaused'] as bool? ?? false;
          _directPauseRemainingSec = data['pauseRemainingSec'] as int? ?? 0;
          _directLastError = data['lastError']?.toString() ?? '';
          if (results.isNotEmpty) _directResults = results;
          final found = data['found'] as int? ?? 0;
          _message = found > 0
              ? '🎉 $found item(s) found! See below and check notifications.'
              : 'Scan complete — no stock at this time. Next scan in ~3 min.';
        });
      }
    } else if (type == 'direct_error') {
      if (mounted) {
        setState(() => _message = 'Direct: ${data['error']?.toString() ?? "Unknown error"}');
      }
    }
  }

  Future<void> _connect() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = 'Connecting…';
    });
    try {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Connecting to backend...'),
          duration: Duration(seconds: 1),
        ),
      );
      await _saveSettings();
      await _refresh(quiet: true, throwErrors: true);
      if (!mounted) return;
      setState(() {
        _connected = true;
        _message = 'Connected to backend.';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.green.shade700,
          content: const Text('Successfully connected to laptop backend!'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _connected = false;
        _message = 'Connection failed: ${_friendlyError(e)}';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.red.shade700,
          content: Text('Connection failed: ${_friendlyError(e)}'),
          duration: const Duration(seconds: 4),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refresh({bool quiet = false, bool throwErrors = false}) async {
    if (_busy && !quiet) return;
    try {
      final results = await Future.wait([
        _api.request('/api/status'),
        _api.request('/api/products'),
        _api.request('/api/events?after_id=0&limit=100'),
      ]);
      final status = Map<String, dynamic>.from(results[0] as Map);
      final products = ((results[1] as Map)['products'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      final eventResponse = Map<String, dynamic>.from(results[2] as Map);
      final events = ((eventResponse['events'] as List<dynamic>? ?? const [])
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList())
        ..sort((a, b) =>
            (int.tryParse(b['id'].toString()) ?? 0).compareTo(int.tryParse(a['id'].toString()) ?? 0));
      final maxId = int.tryParse(eventResponse['latest_event_id']?.toString() ?? '0') ?? 0;
      final previousServerId = _status['server_id']?.toString();
      final nextServerId = status['server_id']?.toString();
      if (!mounted) return;
      setState(() {
        _status = status;
        if (products.isNotEmpty) {
          _products = products;
          for (final p in products) {
            _enabled[p['id'].toString()] = p['enabled'] == true;
          }
        }
        _events = events;
        if (previousServerId != null && nextServerId != previousServerId) {
          _lastEventId = maxId;
        } else {
          _lastEventId = maxId > _lastEventId ? maxId : _lastEventId;
        }
        _connected = true;
      });
    } catch (e) {
      if (throwErrors) rethrow;
      if (!quiet && mounted) {
        setState(() => _message = 'Refresh failed: ${_friendlyError(e)}');
      }
    }
  }

  Future<void> _toggleProduct(String id, bool enabled) async {
    setState(() => _enabled[id] = enabled);
    if (_directMode) {
      final idx = _products.indexWhere((p) => p['id'].toString() == id);
      if (idx >= 0) {
        _products[idx] = {..._products[idx], 'enabled': enabled};
      }
      if (await FlutterForegroundTask.isRunningService) {
        final enabledProds =
            _products.where((p) => _enabled[p['id'].toString()] == true).toList();
        await FlutterForegroundTask.saveData(
            key: 'directProducts', value: jsonEncode(enabledProds));
      }
      return;
    }
    try {
      await _api.request('/api/products', method: 'PUT', body: {
        'products': _products
            .map((p) => {
                  'id': p['id'],
                  'enabled': _enabled[p['id'].toString()] ?? false,
                })
            .toList(),
      });
      if (mounted) setState(() => _message = 'Product selection saved.');
      await _refresh(quiet: true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _enabled[id] = !enabled;
          _message = 'Could not save products: ${_friendlyError(e)}';
        });
      }
    }
  }

  Future<void> _startMonitoring() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = 'Starting monitor…';
    });
    try {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Starting monitoring...')),
      );
      if (_directMode) {
        if (_pincodes.isEmpty) {
          setState(() => _message = 'Load PIN codes first — use "Load from file" or "From backend".');
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Please load or add PIN codes first.')),
          );
          return;
        }
        final enabledProds =
            _products.where((p) => _enabled[p['id'].toString()] != false).toList();
        if (enabledProds.isEmpty) {
          setState(() => _message = 'Enable at least one product.');
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Enable at least one product to watch.')),
          );
          return;
        }
      } else {
        if (!_connected) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              backgroundColor: Colors.orange,
              content: Text('Not connected! Please tap Connect in Settings first.'),
            ),
          );
        }
        await _saveSettings();
        final response = await _api.request('/api/start', method: 'POST', body: const {});
        final modeLabel = (response is Map ? response['mode'] : null)?.toString() ?? 'unknown';
        await FlutterForegroundTask.saveData(key: 'apiBase', value: _api.base);
        await FlutterForegroundTask.saveData(key: 'apiKey', value: _keyController.text.trim());
        await FlutterForegroundTask.saveData(key: 'lastEventId', value: _lastEventId);
        await FlutterForegroundTask.saveData(
            key: 'serverInstance', value: (_status['server_id'] ?? '').toString());
        await FlutterForegroundTask.saveData(key: 'mode', value: 'backend');
        final permission = await FlutterForegroundTask.checkNotificationPermission();
        if (permission != NotificationPermission.granted) {
          await FlutterForegroundTask.requestNotificationPermission();
        }
        await FlutterForegroundTask.startService(
          serviceId: 927,
          notificationTitle: 'myzeptotracker is running',
          notificationText: 'Backend mode • Watching mapped locations • Mode: $modeLabel',
          notificationIcon: null,
          notificationInitialRoute: '/',
          callback: startCallback,
        );
        if (mounted) {
          setState(() => _message =
              'Monitoring started (backend: $modeLabel). Notifications will arrive on finds.');
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              backgroundColor: Colors.green.shade700,
              content: Text('Monitoring active! (Mode: $modeLabel)'),
            ),
          );
          await _refresh(quiet: true);
        }
        return;
      }

      final permission = await FlutterForegroundTask.checkNotificationPermission();
      if (permission != NotificationPermission.granted) {
        await FlutterForegroundTask.requestNotificationPermission();
      }
      await FlutterForegroundTask.saveData(key: 'mode', value: 'direct');
      final enabledProds =
          _products.where((p) => _enabled[p['id'].toString()] != false).toList();
      await FlutterForegroundTask.saveData(key: 'directPincodes', value: jsonEncode(_pincodes));
      await FlutterForegroundTask.saveData(key: 'directProducts', value: jsonEncode(enabledProds));
      await FlutterForegroundTask.saveData(key: 'directScanInterval', value: '180');
      await FlutterForegroundTask.saveData(key: 'directLastScanMs', value: '0');
      await FlutterForegroundTask.saveData(key: 'directShownKeys', value: '');

      await FlutterForegroundTask.startService(
        serviceId: 927,
        notificationTitle: 'myzeptotracker is running',
        notificationText:
            'Phone-Direct mode • ${_pincodes.length} PIN codes • ${enabledProds.length} product(s)',
        notificationIcon: null,
        notificationInitialRoute: '/',
        callback: startCallback,
      );

      if (mounted) {
        setState(() => _message =
            'Phone-Direct monitoring started. First scan begins shortly — keep app running.');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _message = 'Could not start: ${_friendlyError(e)}');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.red.shade700,
            content: Text('Could not start: ${_friendlyError(e)}'),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _stopMonitoring() async {
    try {
      if (!_directMode) {
        await _api.request('/api/stop', method: 'POST', body: const {});
      }
    } catch (_) {}
    await FlutterForegroundTask.stopService();
    if (mounted) setState(() => _message = 'Monitoring stopped.');
    if (!_directMode) await _refresh(quiet: true);
  }

  Future<void> _sendTestNotification() async {
    if (_directMode) {
      final product = _products.firstWhere(
        (p) => _enabled[p['id'].toString()] != false,
        orElse: () => kDefaultProducts.first,
      );
      await notifications.show(
        99999,
        'TEST ALERT • ${product['name']}',
        '₹99,999 • TEST ONLY — 256 GB / any colour\nPIN: 110001 (Demo)',
        const NotificationDetails(
          android: AndroidNotificationDetails(
            stockChannelId,
            'Product availability alerts',
            importance: Importance.max,
            priority: Priority.high,
            playSound: true,
            enableVibration: true,
          ),
        ),
        payload: product['search_url']?.toString() ?? 'https://www.zeptonow.com/',
      );
      setState(() => _message = 'Test notification sent (direct mode demo). Not real stock.');
      return;
    }
    try {
      final decoded = await _api.request('/api/test-event', method: 'POST', body: const {});
      final event = Map<String, dynamic>.from((decoded as Map)['event'] as Map);
      final id = int.tryParse(event['id']?.toString() ?? '0') ?? 0;
      _lastEventId = id > _lastEventId ? id : _lastEventId;
      await FlutterForegroundTask.saveData(key: 'lastEventId', value: _lastEventId);
      await showStockNotification(event);
      if (mounted) {
        setState(() => _message = 'Test notification sent. This is simulated, not real stock.');
      }
      await _refresh(quiet: true);
    } catch (e) {
      if (mounted) {
        setState(() => _message = 'Test failed: ${_friendlyError(e)}');
      }
    }
  }

  Future<void> _importExcel() async {
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['xlsx', 'xlsm'],
        withData: false,
      );
      if (picked == null || picked.files.isEmpty) return;
      final path = picked.files.single.path;
      if (path == null) throw Exception('Could not access the selected workbook path.');
      setState(() {
        _busy = true;
        _message = 'Uploading location workbook…';
      });
      await _saveSettings();
      final request = http.MultipartRequest('POST', Uri.parse('${_api.base}/api/locations/import'));
      request.headers['X-API-Key'] = _keyController.text.trim();
      request.files.add(await http.MultipartFile.fromPath('file', path));
      final streamed = await request.send().timeout(const Duration(seconds: 45));
      final body = await streamed.stream.bytesToString();
      final decoded = jsonDecode(body);
      if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
        final detail = decoded is Map ? decoded['detail']?.toString() : null;
        throw Exception(detail ?? 'Import returned HTTP ${streamed.statusCode}');
      }
      await _refresh(quiet: true);
      if (mounted) {
        setState(() =>
            _message = 'Imported ${decoded['total']} records / ${decoded['unique_pins']} unique PIN codes.');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _message = 'Import failed: ${_friendlyError(e)}');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _loadPincodesFromTextFile() async {
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['txt', 'csv'],
        withData: true,
      );
      if (picked == null || picked.files.isEmpty) return;
      final bytes = picked.files.single.bytes;
      if (bytes == null) throw Exception('Could not read file contents.');
      final text = String.fromCharCodes(bytes);
      final pins = text
          .split(RegExp(r'[\n,;\r\t ]+'))
          .map((e) => e.trim().replaceAll(RegExp(r'[^\d]'), ''))
          .where((e) => e.length == 6 && RegExp(r'^\d{6}$').hasMatch(e))
          .toSet()
          .toList()
        ..sort();
      if (pins.isEmpty) {
        setState(() => _message = 'No valid 6-digit PIN codes found.');
        return;
      }
      setState(() {
        _pincodes = pins;
        _message = '${pins.length} PIN codes loaded from file.';
      });
      await _saveSettings();
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.saveData(key: 'directPincodes', value: jsonEncode(_pincodes));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _message = 'Load failed: ${_friendlyError(e)}');
      }
    }
  }

  Future<void> _loadPincodesFromBackend() async {
    try {
      setState(() => _message = 'Fetching pincodes from backend…');
      final result = await _api.request('/api/locations?limit=2000');
      final locs = (result['locations'] as List? ?? []).whereType<Map>().toList();
      final pins = locs
          .map((l) => l['pin_code']?.toString() ?? '')
          .where((p) => p.length == 6 && RegExp(r'^\d{6}$').hasMatch(p))
          .toSet()
          .toList()
        ..sort();
      setState(() {
        _pincodes = pins;
        _message = '${pins.length} pincodes loaded from backend.';
      });
      await _saveSettings();
    } catch (e) {
      if (mounted) {
        setState(() => _message = 'Could not fetch from backend: ${_friendlyError(e)}');
      }
    }
  }

  String _friendlyError(Object e) => e.toString().replaceFirst('Exception: ', '');

  @override
  void dispose() {
    _timer?.cancel();
    FlutterForegroundTask.removeTaskDataCallback(_onTaskData);
    _apiController.dispose();
    _keyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mode = (_status['mode'] ?? 'unknown').toString();
    final phase = (_status['phase'] ?? 'not connected').toString();
    final blocked = _status['blocked_or_rate_limited'] == true;
    final running = _status['running'] == true;

    return Scaffold(
      appBar: AppBar(
        title: const Text('myzeptotracker', style: TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          IconButton(
            tooltip: 'All Locations & PINs',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => LocationsPage(
                  api: _api,
                  isConnected: _connected,
                  onLocationsUpdated: () => _refresh(quiet: true),
                ),
              ),
            ),
            icon: const Icon(Icons.location_on),
          ),
          IconButton(
            tooltip: 'Settings',
            onPressed: () => setState(() => _showSettings = !_showSettings),
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => _refresh(quiet: false),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
          children: [
            ModeToggleCard(
              directMode: _directMode,
              onChanged: (v) async {
                setState(() {
                  _directMode = v;
                  if (_products.isEmpty) {
                    _products = List<Map<String, dynamic>>.from(kDefaultProducts);
                    for (final p in _products) {
                      _enabled[p['id'].toString()] = p['enabled'] != false;
                    }
                  }
                });
                await _saveSettings();
              },
            ),
            const SizedBox(height: 10),
            if (_directMode) ...[
              if (_directGloballyPaused)
                GlobalPauseBanner(
                  pauseRemainingSec: _directPauseRemainingSec,
                  blockCount: _directBlockCount,
                ),
              if (_directLastError.isNotEmpty && !_directGloballyPaused)
                ErrorBanner(message: _directLastError),
              DirectPinCard(
                pincodes: _pincodes,
                connected: _connected,
                scansCompleted: _directScansCompleted,
                blockCount: _directBlockCount,
                onLoadFromFile: _loadPincodesFromTextFile,
                onLoadFromBackend: _connected ? _loadPincodesFromBackend : null,
              ),
            ] else ...[
              StatusBanner(
                mode: mode,
                phase: phase,
                blocked: blocked,
                running: running,
                pauseReason: _status['pause_reason']?.toString(),
                onRefresh: () => _refresh(quiet: false),
              ),
              const SizedBox(height: 14),
              if (_showSettings)
                SettingsCard(
                  apiController: _apiController,
                  keyController: _keyController,
                  busy: _busy,
                  onConnect: _connect,
                  onImportExcel: _importExcel,
                ),
              MetricGrid(status: _status),
            ],
            const SizedBox(height: 14),
            ActionsCard(
              busy: _busy,
              running: running,
              directMode: _directMode,
              pinCount: _pincodes.length,
              scansCompleted: _directScansCompleted,
              status: _status,
              onStart: _startMonitoring,
              onStop: _stopMonitoring,
              onTestNotification: _sendTestNotification,
            ),
            const SizedBox(height: 14),
            ProductsCard(
              products: _products,
              defaultProducts: kDefaultProducts,
              enabled: _enabled,
              directMode: _directMode,
              connected: _connected,
              onToggle: _toggleProduct,
            ),
            const SizedBox(height: 14),
            if (_directMode && _directResults.isNotEmpty)
              DirectResultsCard(results: _directResults),
            if (!_directMode) EventsCard(events: _events),
            const SizedBox(height: 12),
            Text(
              _message,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.black54),
            ),
            const SizedBox(height: 18),
            const Text(
              'Important: Direct mode uses Zepto\'s public API with Akamai-aware backoff. '
              'IP blocking is mitigated but not guaranteed.',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
          ],
        ),
      ),
    );
  }
}
