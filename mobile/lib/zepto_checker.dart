// zepto_checker.dart
// Direct Zepto stock checker — runs entirely on the Android device.
// No laptop or external backend required.
//
// • Per-pincode semaphore: max 5 concurrent requests.
// • Per-pincode circuit breaker: 403/429 → PIN blocked 15 min.
// • Global pause after 3 blocks → all PINs pause 30 min.
// • Store ID resolved once per pincode and cached.
//
// NOTE: Zepto uses Akamai Bot Manage/*/r. Realistic headers + exponential
// backoff are applied. Full bypass is not possible; the circuit
// breaker protects your device IP from aggressive blocking.

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

// ─── Semaphore ─────────────────────────────────────────────────────────────────

class Semaphore {
  final int _max;
  int _count = 0;
  final Queue<Completer<void>> _q = Queue();

  Semaphore(this._max);

  Future<void> acquire() async {
    if (_count < _max) {
      _count++;
      return;
    }
    final c = Completer<void>();
    _q.add(c);
    await c.future;
  }

  void release() {
    if (_q.isNotEmpty) {
      _q.removeFirst().complete();
    } else {
      _count = max(0, _count - 1);
    }
  }
}

// ─── Models ────────────────────────────────────────────────────────────────────

class ZeptoStockResult {
  final String pincode;
  final String productId;
  final String productName;
  final String? variant;
  final int? price;
  final String? productUrl;

  const ZeptoStockResult({
    required this.pincode,
    required this.productId,
    required this.productName,
    this.variant,
    this.price,
    this.productUrl,
  });

  Map<String, dynamic> toMap() => {
        'pincode': pincode,
        'product_id': productId,
        'product_name': productName,
        'variant': variant,
        'price': price,
        'product_url': productUrl,
        'available': true,
        'is_demo': false,
      };
}

class _BlockError implements Exception {
  final int code;
  _BlockError(this.code);
}

// ─── Checker ───────────────────────────────────────────────────────────────────

class ZeptoChecker {
  ZeptoChecker._();

  static const _base = 'https://api.zeptonow.com';
  static const _maxConcurrent = 5;
  static const _maxRetries = 2;
  static const _perPinBlockMs = 15 * 60 * 1000; // 15 min
  static const _globalPauseMs = 30 * 60 * 1000; // 30 min
  static const _globalPauseThreshold = 3; // blocks before global pause

  // ── Public state ─────────────────────────────────────────────────────────
  static int scansCompleted = 0;
  static int blockCount = 0;
  static String lastError = '';
  static String phase = 'idle'; // idle | scanning | paused | error
  static int locationsDone = 0;
  static int locationsTotal = 0;

  // ── Internal state ────────────────────────────────────────────────────────
  // Store ID cache: pincode → store_id (null = unresolvable)
  static final Map<String, String?> _storeCache = {};
  // Per-pincode circuit breaker: pincode → blocked-until (epoch ms)
  static final Map<String, int> _pinBlocked = {};
  // Global pause until epoch ms
  static int _globalPauseUntil = 0;

  static final _rng = Random();
  static final _uas = [
    'Mozilla/5.0 (Linux; Android 14; Pixel 8 Pro) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.6099.144 Mobile Safari/537.36',
    'Mozilla/5.0 (Linux; Android 13; SM-S918B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.6045.193 Mobile Safari/537.36',
    'Mozilla/5.0 (Linux; Android 14; OnePlus 12) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.6167.144 Mobile Safari/537.36',
    'Mozilla/5.0 (Linux; Android 12; Redmi Note 11 Pro) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/118.0.5993.111 Mobile Safari/537.36',
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.6099.144 Safari/537.36',
  ];

  static Map<String, String> _mkHeaders({String? storeId}) {
    final h = <String, String>{
      'User-Agent': _uas[_rng.nextInt(_uas.length)],
      'Accept': 'application/json, text/plain, */*',
      'Accept-Language': 'en-IN,en-US;q=0.9,hi;q=0.8',
      'Accept-Encoding': 'gzip, deflate, br',
      'x-app-version': '1.0.26',
      'x-platform': 'android',
      'Connection': 'keep-alive',
      'Origin': 'https://www.zeptonow.com',
      'Referer': 'https://www.zeptonow.com/',
    };
    if (storeId != null) h['store_id'] = storeId;
    return h;
  }

  // ─── Store resolution ──────────────────────────────────────────────────────

  /// Resolve Zepto store ID for a pincode. Cached after first call.
  static Future<String?> resolveStoreId(String pincode) async {
    if (_storeCache.containsKey(pincode)) return _storeCache[pincode];
    try {
      final uri = Uri.parse('$_base/api/v3/store')
          .replace(queryParameters: {'pincode': pincode});
      final resp = await http
          .get(uri, headers: _mkHeaders())
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) {
        final body = jsonDecode(resp.body) as Map<String, dynamic>;
        final stores = body['stores'] as List?;
        final storeMap = (stores?.isNotEmpty == true
            ? stores!.first
            : body['store']) as Map<String, dynamic>?;
        final id = (storeMap?['id'] ?? storeMap?['store_id'])?.toString();
        _storeCache[pincode] = (id?.isNotEmpty == true) ? id : null;
        return _storeCache[pincode];
      }
    } catch (_) {}
    _storeCache[pincode] = null;
    return null;
  }

  // ─── Search ────────────────────────────────────────────────────────────────

  static Future<List<Map<String, dynamic>>> _searchZepto(
      String query, String? storeId) async {
    for (int attempt = 0; attempt <= _maxRetries; attempt++) {
      if (attempt > 0) {
        final waitSec =
            min(60, pow(2, attempt).toInt() * 5 + _rng.nextInt(10));
        await Future.delayed(Duration(seconds: waitSec));
      }
      try {
        final uri = Uri.parse('$_base/api/v3/search/').replace(
          queryParameters: {
            'query': query,
            'page_number': '1',
            'mode': 'PAGE_TYPE_SEARCH',
          },
        );
        final resp = await http
            .get(uri, headers: _mkHeaders(storeId: storeId))
            .timeout(const Duration(seconds: 15));

        if (resp.statusCode == 403 || resp.statusCode == 429) {
          if (attempt >= _maxRetries) throw _BlockError(resp.statusCode);
          final backoff = 30 + _rng.nextInt(60);
          await Future.delayed(Duration(seconds: backoff));
          continue;
        }
        if (resp.statusCode != 200) return [];
        return _parseResponse(jsonDecode(resp.body) as Map<String, dynamic>);
      } on _BlockError {
        rethrow;
      } on TimeoutException {
        if (attempt >= _maxRetries) return [];
      } catch (_) {
        if (attempt >= _maxRetries) return [];
      }
    }
    return [];
  }

  // ─── Response parser ───────────────────────────────────────────────────────

  static List<Map<String, dynamic>> _parseResponse(
      Map<String, dynamic> body) {
    final items = <Map<String, dynamic>>[];

    // Format 1: body.data.*.sections[].widgetList[].data.sku
    final data = body['data'];
    if (data is Map) {
      for (final val in data.values) {
        final sections = val is List
            ? val
            : (val is Map ? [val] : <dynamic>[]);
        for (final s in sections) {
          if (s is! Map) continue;
          for (final key in ['widgetList', 'items', 'products']) {
            for (final w in (s[key] as List? ?? [])) {
              if (w is! Map) continue;
              final d = w['data'] as Map<String, dynamic>?;
              if (d == null) continue;
              final sku = d['sku'] as Map<String, dynamic>?;
              if (sku != null) {
                items.add(sku);
              } else if (d.containsKey('name')) {
                items.add(d);
              }
            }
          }
        }
      }
    }

    // Format 2: body.sections[].products[]
    for (final s in (body['sections'] as List? ?? [])) {
      if (s is! Map) continue;
      for (final key in ['products', 'items', 'widgetList']) {
        for (final p in (s[key] as List? ?? [])) {
          if (p is Map<String, dynamic>) items.add(p);
        }
      }
    }

    // Format 3: flat arrays
    for (final key in ['products', 'items', 'results']) {
      for (final p in (body[key] as List? ?? [])) {
        if (p is Map<String, dynamic>) items.add(p);
      }
    }

    return items;
  }

  // ─── Match helpers ─────────────────────────────────────────────────────────

  static bool _isAvailable(Map<String, dynamic> sku) {
    final avail =
        sku['available'] ?? sku['in_stock'] ?? sku['inventory_available'];
    if (avail == null) return true;
    if (avail is bool) return avail;
    if (avail is int) return avail > 0;
    final s = avail.toString().toLowerCase();
    return s != '0' && s != 'false' && s.isNotEmpty;
  }

  static bool _matchesProduct(
      Map<String, dynamic> sku, Map<String, dynamic> product) {
    if (!_isAvailable(sku)) return false;
    final match = product['match'] as Map<String, dynamic>? ?? {};
    if (match.isEmpty) return true;
    final name =
        (sku['name'] ?? sku['product_name'] ?? '').toString().toLowerCase();
    final desc = (sku['description'] ?? '').toString().toLowerCase();
    final combined = '$name $desc';
    return match.entries.every((e) {
      final v = e.value.toString().toLowerCase();
      return v == 'any' || combined.contains(v);
    });
  }

  static String? _extractVariant(Map<String, dynamic> sku) {
    for (final key in ['unit_quantity', 'variant', 'size', 'description']) {
      final v = sku[key]?.toString();
      if (v != null && v.isNotEmpty) return v;
    }
    return null;
  }

  static int? _extractPrice(Map<String, dynamic> sku) {
    for (final key in [
      'discounted_selling_price',
      'selling_price',
      'price',
      'mrp'
    ]) {
      final v = sku[key];
      if (v == null) continue;
      if (v is int) return v;
      if (v is double) return v.round();
      final s = v.toString().replaceAll(RegExp(r'[^\d]'), '');
      if (s.isNotEmpty) return int.tryParse(s);
    }
    return null;
  }

  // ─── Public API ────────────────────────────────────────────────────────────

  /// Check all enabled products for a single [pincode].
  static Future<List<ZeptoStockResult>> checkPincode(
    String pincode,
    List<Map<String, dynamic>> products,
  ) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now < _globalPauseUntil) return [];
    if (now < (_pinBlocked[pincode] ?? 0)) return [];

    final storeId = await resolveStoreId(pincode);
    final results = <ZeptoStockResult>[];

    for (final product in products) {
      if (DateTime.now().millisecondsSinceEpoch < _globalPauseUntil) break;
      final query =
          (product['query'] ?? product['name'] ?? '').toString().trim();
      if (query.isEmpty) continue;

      try {
        final skus = await _searchZepto(query, storeId);
        for (final sku in skus) {
          if (_matchesProduct(sku, product)) {
            results.add(ZeptoStockResult(
              pincode: pincode,
              productId: product['id']?.toString() ?? '',
              productName: product['name']?.toString() ?? query,
              variant: _extractVariant(sku),
              price: _extractPrice(sku),
              productUrl: product['search_url']?.toString(),
            ));
            break; // one match per product per pincode is enough
          }
        }
      } on _BlockError catch (e) {
        blockCount++;
        _pinBlocked[pincode] =
            DateTime.now().millisecondsSinceEpoch + _perPinBlockMs;
        lastError =
            'HTTP ${e.code} for PIN $pincode — paused ${_perPinBlockMs ~/ 60000} min.';
        if (blockCount >= _globalPauseThreshold) {
          _globalPauseUntil =
              DateTime.now().millisecondsSinceEpoch + _globalPauseMs;
          phase = 'paused';
          lastError +=
              ' Global pause active (${_globalPauseMs ~/ 60000} min).';
        }
        break;
      }
    }
    return results;
  }

  /// Scan all [pincodes] concurrently for all [products].
  static Future<List<ZeptoStockResult>> scanAll({
    required List<String> pincodes,
    required List<Map<String, dynamic>> products,
    void Function(int done, int total)? onProgress,
    bool Function()? shouldStop,
  }) async {
    phase = 'scanning';
    locationsDone = 0;
    locationsTotal = pincodes.length;
    final sem = Semaphore(_maxConcurrent);
    final all = <ZeptoStockResult>[];

    final futures = pincodes.map((pin) async {
      if (shouldStop?.call() == true) return;
      await sem.acquire();
      try {
        if (shouldStop?.call() == true) return;
        final r = await checkPincode(pin, products);
        all.addAll(r);
        locationsDone++;
        onProgress?.call(locationsDone, pincodes.length);
      } catch (_) {
        locationsDone++;
      } finally {
        sem.release();
      }
    }).toList();

    await Future.wait(futures, eagerError: false);
    scansCompleted++;
    if (phase == 'scanning') phase = 'idle';
    return all;
  }

  static bool get isGloballyPaused =>
      DateTime.now().millisecondsSinceEpoch < _globalPauseUntil;

  static int get globalPauseRemainingSec => max(
      0,
      (_globalPauseUntil - DateTime.now().millisecondsSinceEpoch) ~/ 1000);

  static void resetCircuitBreaker() {
    _pinBlocked.clear();
    _globalPauseUntil = 0;
    blockCount = 0;
    lastError = '';
    phase = 'idle';
  }
}
