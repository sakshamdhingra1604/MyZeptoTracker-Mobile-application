import 'dart:convert';
import 'package:http/http.dart' as http;
import '../constants.dart';

class ApiService {
  final String baseUrl;
  final String apiKey;

  ApiService({required this.baseUrl, required this.apiKey});

  String get base => normaliseBase(baseUrl);

  Map<String, String> get headers => {
        'X-API-Key': apiKey.trim(),
        'Content-Type': 'application/json',
      };

  Future<dynamic> request(
    String path, {
    String method = 'GET',
    Object? body,
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final uri = Uri.parse('$base$path');
    late http.Response response;
    if (method == 'POST') {
      response = await http
          .post(uri, headers: headers, body: body == null ? null : jsonEncode(body))
          .timeout(timeout);
    } else if (method == 'PUT') {
      response = await http
          .put(uri, headers: headers, body: body == null ? null : jsonEncode(body))
          .timeout(timeout);
    } else {
      response = await http
          .get(uri, headers: {'X-API-Key': apiKey.trim()})
          .timeout(timeout);
    }
    dynamic decoded;
    try {
      decoded = jsonDecode(response.body);
    } catch (_) {
      decoded = {'detail': response.body};
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final detail = decoded is Map ? decoded['detail']?.toString() : null;
      throw Exception(detail ?? 'Backend returned HTTP ${response.statusCode}');
    }
    return decoded;
  }

  Future<List<Map<String, dynamic>>> fetchLocations({int limit = 500}) async {
    final res = await request('/api/locations?limit=$limit');
    if (res is Map && res['locations'] is List) {
      return (res['locations'] as List)
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();
    }
    return [];
  }

  Future<Map<String, dynamic>> addLocation({
    required String pinCode,
    required String name,
    String city = 'Delhi',
    String? locality,
    String? address,
  }) async {
    final res = await request(
      '/api/locations',
      method: 'POST',
      body: {
        'city': city,
        'name': name,
        'locality': locality ?? name,
        'pin_code': pinCode,
        'address': address ?? '$name, $pinCode',
      },
    );
    return Map<String, dynamic>.from(res as Map);
  }
}
