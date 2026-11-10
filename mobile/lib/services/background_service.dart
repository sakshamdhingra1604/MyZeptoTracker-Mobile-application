import 'dart:async';
import 'dart:convert';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;

import '../constants.dart';
import '../zepto_checker.dart';

/// Entry-point for the foreground-task isolate.
@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(StockNotificationHandler());
}

// ── Background task handler ─────────────────────────────────────────────────

class StockNotificationHandler extends TaskHandler {
  bool _busy = false;
  late FlutterLocalNotificationsPlugin _localNotifications;

  static const _channel = AndroidNotificationChannel(
    stockChannelId,
    'Product availability alerts',
    description: 'High-priority product availability alerts.',
    importance: Importance.max,
    playSound: true,
    enableVibration: true,
  );

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    _localNotifications = FlutterLocalNotificationsPlugin();
    await _localNotifications.initialize(
      const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher')),
    );
    final local = _localNotifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    await local?.createNotificationChannel(_channel);
  }

  @override
  void onRepeatEvent(DateTime timestamp) => unawaited(_tick());

  Future<void> _tick() async {
    final dynamic rawMode =
        await FlutterForegroundTask.getData(key: 'mode');
    if ((rawMode?.toString() ?? 'backend') == 'direct') {
      await _directScanIfDue();
    } else {
      await _pollBackendEvents();
    }
  }

  // ── Direct mode ───────────────────────────────────────────────────────

  Future<void> _directScanIfDue() async {
    if (_busy) return;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final lastMs = int.tryParse(
            (await FlutterForegroundTask.getData(key: 'directLastScanMs'))
                    ?.toString() ??
                '0') ??
        0;
    final intervalMs = (int.tryParse(
                (await FlutterForegroundTask.getData(
                            key: 'directScanInterval'))
                        ?.toString() ??
                    '180') ??
            180) *
        1000;
    if (nowMs - lastMs < intervalMs) return;

    _busy = true;
    try {
      final rawPins =
          await FlutterForegroundTask.getData(key: 'directPincodes');
      final rawProds =
          await FlutterForegroundTask.getData(key: 'directProducts');
      if (rawPins == null || rawProds == null) {
        FlutterForegroundTask.sendDataToMain({
          'type': 'direct_error',
          'error': 'No pincodes or products configured for direct mode.',
        });
        return;
      }

      final pincodes = (jsonDecode(rawPins.toString()) as List)
          .map((e) => e.toString())
          .where((e) => e.length == 6)
          .toList();
      final products = (jsonDecode(rawProds.toString()) as List)
          .whereType<Map<String, dynamic>>()
          .where((p) => p['enabled'] != false)
          .toList();
      if (pincodes.isEmpty || products.isEmpty) return;

      FlutterForegroundTask.updateService(
        notificationText:
            'Scanning ${pincodes.length} PINs for ${products.length} product(s)…',
      );

      final results = await ZeptoChecker.scanAll(
          pincodes: pincodes, products: products);

      await FlutterForegroundTask.saveData(
          key: 'directLastScanMs', value: nowMs.toString());

      // Deduplicate within session
      final rawShown =
          await FlutterForegroundTask.getData(key: 'directShownKeys');
      final shownKeys =
          Set<String>.from((rawShown?.toString() ?? '').split(','));

      for (final result in results) {
        final key = '${result.productId}::${result.pincode}';
        if (!shownKeys.contains(key)) {
          await _showDirectNotification(result);
          shownKeys.add(key);
        }
      }
      await FlutterForegroundTask.saveData(
          key: 'directShownKeys', value: shownKeys.join(','));

      FlutterForegroundTask.updateService(
        notificationText: results.isEmpty
            ? 'No stock found • ${DateTime.now().toString().substring(11, 16)}'
            : '🎉 ${results.length} item(s) found!',
      );
      FlutterForegroundTask.sendDataToMain({
        'type': 'direct_scan_done',
        'found': results.length,
        'scansCompleted': ZeptoChecker.scansCompleted,
        'blockCount': ZeptoChecker.blockCount,
        'lastError': ZeptoChecker.lastError,
        'globallyPaused': ZeptoChecker.isGloballyPaused,
        'pauseRemainingSec': ZeptoChecker.globalPauseRemainingSec,
        'results': results.map((r) => r.toMap()).toList(),
      });
    } catch (e) {
      FlutterForegroundTask.sendDataToMain(
          {'type': 'direct_error', 'error': e.toString()});
    } finally {
      _busy = false;
    }
  }

  Future<void> _showDirectNotification(ZeptoStockResult result) async {
    final price =
        result.price == null ? 'Price unavailable' : '₹${result.price}';
    final body =
        '$price • ${result.variant ?? "In stock"}\nPIN: ${result.pincode}';
    final url = result.productUrl ?? 'https://www.zeptonow.com/';
    await _localNotifications.show(
      (result.productId.hashCode ^ result.pincode.hashCode).abs() % 2000000000,
      result.productName,
      body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          stockChannelId,
          'Product availability alerts',
          channelDescription: 'Zepto stock alerts.',
          importance: Importance.max,
          priority: Priority.high,
          category: AndroidNotificationCategory.recommendation,
          playSound: true,
          enableVibration: true,
          styleInformation: BigTextStyleInformation(body),
        ),
      ),
      payload: url,
    );
  }

  // ── Backend mode ──────────────────────────────────────────────────────

  Future<void> _pollBackendEvents() async {
    if (_busy) return;
    _busy = true;
    try {
      final apiBase =
          (await FlutterForegroundTask.getData(key: 'apiBase'))?.toString();
      final apiKey =
          (await FlutterForegroundTask.getData(key: 'apiKey'))?.toString();
      if (apiBase == null ||
          apiBase.trim().isEmpty ||
          apiKey == null ||
          apiKey.isEmpty) {
        return;
      }

      final savedInstance =
          (await FlutterForegroundTask.getData(key: 'serverInstance'))
                  ?.toString() ??
              '';
      int lastId = int.tryParse(
              (await FlutterForegroundTask.getData(key: 'lastEventId'))
                      ?.toString() ??
                  '0') ??
          0;

      final uri = Uri.parse('${normaliseBase(apiBase)}/api/events')
          .replace(queryParameters: {'after_id': '$lastId', 'limit': '100'});
      final response = await http
          .get(uri, headers: {'X-API-Key': apiKey})
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) {
        return;
      }

      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      final currentInstance = (decoded['server_id'] ?? '').toString();
      if (currentInstance.isNotEmpty && currentInstance != savedInstance) {
        lastId = 0;
        await FlutterForegroundTask.saveData(
            key: 'serverInstance', value: currentInstance);
        await FlutterForegroundTask.saveData(key: 'lastEventId', value: 0);
      }

      for (final raw in (decoded['events'] as List<dynamic>? ?? const [])) {
        if (raw is! Map<String, dynamic>) continue;
        final eventId = int.tryParse(raw['id']?.toString() ?? '') ?? 0;
        if (eventId <= lastId) continue;
        if (raw['available'] == true) {
          await _showBackendNotification(raw, eventId);
        }
        lastId = eventId;
        await FlutterForegroundTask.saveData(
            key: 'lastEventId', value: lastId);
      }
      FlutterForegroundTask.sendDataToMain(
          {'type': 'poll_ok', 'latestEventId': lastId});
    } catch (_) {
      // Network outages must not crash the service.
    } finally {
      _busy = false;
    }
  }

  Future<void> _showBackendNotification(
      Map<String, dynamic> event, int eventId) async {
    final demo = event['is_demo'] == true;
    final name = (event['product_name'] ?? 'Product available').toString();
    final location =
        [event['location_name'], event['city'], event['pin_code']]
            .where((v) => v != null && v.toString().trim().isNotEmpty)
            .map((v) => v.toString())
            .join(', ');
    final price = event['price'] == null
        ? 'Price not supplied'
        : '₹${event['price']}';
    final variant =
        (event['variant'] ?? 'Variant details not supplied').toString();
    final title = demo ? 'TEST ALERT • $name' : name;
    final body = '$price • $variant\n$location';
    final url =
        (event['product_url'] ?? 'https://www.zeptonow.com/').toString();
    await _localNotifications.show(
      eventId % 2000000000,
      title,
      body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          stockChannelId,
          'Product availability alerts',
          channelDescription: 'High-priority product availability alerts.',
          importance: Importance.max,
          priority: Priority.high,
          category: AndroidNotificationCategory.recommendation,
          ticker: title,
          playSound: true,
          enableVibration: true,
          styleInformation: BigTextStyleInformation(body),
        ),
      ),
      payload: url,
    );
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {}

  @override
  void onReceiveData(Object data) {}

  @override
  void onNotificationButtonPressed(String id) {}

  @override
  void onNotificationPressed() {}
}
