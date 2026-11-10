import 'dart:async';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:url_launcher/url_launcher.dart';

import '../constants.dart';

final FlutterLocalNotificationsPlugin notifications =
    FlutterLocalNotificationsPlugin();

Future<void> openProductUrl(String? rawUrl) async {
  if (rawUrl == null || rawUrl.isEmpty) return;
  final uri = Uri.tryParse(rawUrl);
  if (uri == null) return;

  // Try opening external app/browser with auto fallback
  try {
    final launched = await launchUrl(
      uri,
      mode: LaunchMode.externalApplication,
    );
    if (!launched) {
      await launchUrl(uri, mode: LaunchMode.platformDefault);
    }
  } catch (_) {
    try {
      await launchUrl(uri, mode: LaunchMode.inAppBrowserView);
    } catch (_) {}
  }
}

Future<void> initialiseNotifications() async {
  const android = AndroidInitializationSettings('@mipmap/ic_launcher');
  const settings = InitializationSettings(android: android);

  await notifications.initialize(
    settings,
    onDidReceiveNotificationResponse: (NotificationResponse response) async {
      final payload = response.payload;
      if (payload != null && payload.startsWith('http')) {
        await openProductUrl(payload);
      }
    },
  );

  final launchDetails = await notifications.getNotificationAppLaunchDetails();
  final launchPayload = launchDetails?.notificationResponse?.payload;
  if (launchDetails?.didNotificationLaunchApp == true &&
      launchPayload != null &&
      launchPayload.startsWith('http')) {
    unawaited(openProductUrl(launchPayload));
  }

  final androidPlugin = notifications
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
  await androidPlugin?.requestNotificationsPermission();
  await androidPlugin?.createNotificationChannel(
    const AndroidNotificationChannel(
      stockChannelId,
      'Product availability alerts',
      description:
          'High-priority alerts when a monitored product is reported in stock.',
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
    ),
  );
}

Future<void> showStockNotification(Map<String, dynamic> event) async {
  final bool demo = event['is_demo'] == true;
  final String name =
      (event['product_name'] ?? 'Product available').toString();
  final String location =
      [event['location_name'], event['city'], event['pin_code']]
          .where((v) => v != null && v.toString().trim().isNotEmpty)
          .map((v) => v.toString())
          .join(', ');
  final String variant =
      (event['variant'] ?? 'Variant details not supplied').toString();
  final dynamic rawPrice = event['price'];
  final String price =
      rawPrice == null ? 'Price not supplied' : '₹${rawPrice.toString()}';

  final title = demo ? 'TEST ALERT • $name' : '🔥 IN STOCK: $name';
  final body = '$price • $variant\n$location\nTap to open directly';

  final details = NotificationDetails(
    android: AndroidNotificationDetails(
      stockChannelId,
      'Product availability alerts',
      channelDescription: 'High-priority product availability notifications.',
      importance: Importance.max,
      priority: Priority.high,
      category: AndroidNotificationCategory.recommendation,
      ticker: title,
      playSound: true,
      enableVibration: true,
      styleInformation: BigTextStyleInformation(body),
    ),
  );

  final id = ((event['id'] is num)
              ? (event['id'] as num).toInt()
              : DateTime.now().millisecondsSinceEpoch) %
      2000000000;
  final url =
      (event['product_url'] ?? 'https://www.zepto.com/').toString();
  await notifications.show(id, title, body, details, payload: url);
}
