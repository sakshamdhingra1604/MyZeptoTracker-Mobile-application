import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_service.dart';

class LocationsPage extends StatefulWidget {
  final ApiService api;
  final bool isConnected;
  final VoidCallback onLocationsUpdated;

  const LocationsPage({
    super.key,
    required this.api,
    required this.isConnected,
    required this.onLocationsUpdated,
  });

  @override
  State<LocationsPage> createState() => _LocationsPageState();
}

class _LocationsPageState extends State<LocationsPage> {
  List<Map<String, dynamic>> _locations = [];
  bool _loading = false;
  String _searchQuery = '';

  final _pinController = TextEditingController();
  final _nameController = TextEditingController();
  final _cityController = TextEditingController(text: 'Delhi');

  @override
  void initState() {
    super.initState();
    _loadAllLocations();
  }

  Future<void> _loadAllLocations() async {
    setState(() => _loading = true);
    final prefs = await SharedPreferences.getInstance();

    // 1. First load bundled 229 locations from assets
    List<Map<String, dynamic>> baseList = [];
    try {
      final jsonStr = await rootBundle.loadString('assets/default_locations.json');
      final list = jsonDecode(jsonStr) as List;
      baseList = list.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList();
    } catch (_) {}

    // 2. Load custom user-added locations from local storage
    final customJson = prefs.getString('custom_user_locations') ?? '[]';
    try {
      final customList = (jsonDecode(customJson) as List)
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();
      // Insert user custom locations at top
      baseList.insertAll(0, customList);
    } catch (_) {}

    // 3. If connected to backend, sync latest locations from backend
    if (widget.isConnected) {
      try {
        final backendLocs = await widget.api.fetchLocations(limit: 1000);
        if (backendLocs.isNotEmpty) {
          baseList = backendLocs;
        }
      } catch (_) {}
    }

    if (mounted) {
      setState(() {
        _locations = baseList;
        _loading = false;
      });
    }
  }

  void _showAddLocationDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add Location / PIN', style: TextStyle(fontWeight: FontWeight.bold)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _pinController,
                keyboardType: TextInputType.number,
                maxLength: 6,
                decoration: const InputDecoration(
                  labelText: '6-digit PIN Code *',
                  hintText: 'e.g. 110037',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'Location / Store Name *',
                  hintText: 'e.g. Metropolis Logistics',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _cityController,
                decoration: const InputDecoration(
                  labelText: 'City / Region',
                  hintText: 'e.g. Delhi, Gurugram, Noida',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF5B4BDB)),
            icon: const Icon(Icons.add_location_alt, size: 18),
            label: const Text('Add Location'),
            onPressed: () async {
              final pin = _pinController.text.trim();
              final name = _nameController.text.trim();
              final city = _cityController.text.trim();

              if (pin.length != 6 || int.tryParse(pin) == null) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Please enter a valid 6-digit PIN code')),
                );
                return;
              }
              if (name.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Please enter store/location name')),
                );
                return;
              }

              Navigator.pop(ctx);
              setState(() => _loading = true);

              final newLoc = {
                'id': 'loc-custom-${DateTime.now().millisecondsSinceEpoch}',
                'name': name,
                'city': city.isEmpty ? 'Delhi' : city,
                'locality': name,
                'pin_code': pin,
                'address': '$name, $pin',
                'valid_pin': true,
              };

              // 1. Save to local storage immediately
              final prefs = await SharedPreferences.getInstance();
              final customJson = prefs.getString('custom_user_locations') ?? '[]';
              final List<dynamic> customList = jsonDecode(customJson);
              customList.insert(0, newLoc);
              await prefs.setString('custom_user_locations', jsonEncode(customList));

              // Also update direct pincodes list if present
              final pinsJson = prefs.getString('directPincodes') ?? '[]';
              final List<dynamic> pins = jsonDecode(pinsJson);
              if (!pins.contains(pin)) {
                pins.insert(0, pin);
                await prefs.setString('directPincodes', jsonEncode(pins));
              }

              // 2. If connected to backend, sync with backend too
              if (widget.isConnected) {
                try {
                  await widget.api.addLocation(
                    pinCode: pin,
                    name: name,
                    city: city.isEmpty ? 'Delhi' : city,
                  );
                } catch (_) {}
              }

              _pinController.clear();
              _nameController.clear();
              await _loadAllLocations();
              widget.onLocationsUpdated();

              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    backgroundColor: Colors.green.shade700,
                    content: Text('Added $name ($pin) to watchlist!'),
                  ),
                );
              }
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _locations.where((l) {
      final q = _searchQuery.toLowerCase();
      final name = (l['name'] ?? '').toString().toLowerCase();
      final pin = (l['pin_code'] ?? '').toString().toLowerCase();
      final locality = (l['locality'] ?? '').toString().toLowerCase();
      final city = (l['city'] ?? '').toString().toLowerCase();
      return name.contains(q) || pin.contains(q) || locality.contains(q) || city.contains(q);
    }).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('All Locations & PINs', style: TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadAllLocations,
            tooltip: 'Refresh',
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: const Color(0xFF5B4BDB),
        foregroundColor: Colors.white,
        onPressed: _showAddLocationDialog,
        icon: const Icon(Icons.add_location_alt),
        label: const Text('Add Location'),
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            color: const Color(0xFF5B4BDB).withValues(alpha: 0.08),
            child: Row(
              children: [
                const Icon(Icons.storefront, color: Color(0xFF5B4BDB), size: 30),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${_locations.length} Total Stores in Watchlist',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                      Text(
                        widget.isConnected ? 'Connected to laptop backend' : 'Local + Offline Watchlist',
                        style: TextStyle(
                          fontSize: 12,
                          color: widget.isConnected ? Colors.green.shade700 : Colors.black54,
                          fontWeight: widget.isConnected ? FontWeight.w600 : FontWeight.normal,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: TextField(
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search, size: 20),
                hintText: 'Search by PIN code or locality...',
                isDense: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              ),
              onChanged: (val) => setState(() => _searchQuery = val.trim()),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : filtered.isEmpty
                    ? const Center(
                        child: Text(
                          'No matching locations found',
                          style: TextStyle(color: Colors.black54),
                        ),
                      )
                    : ListView.separated(
                        itemCount: filtered.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (ctx, i) {
                          final loc = filtered[i];
                          final name = loc['name'] ?? 'Store';
                          final pin = loc['pin_code'] ?? '';
                          final city = loc['city'] ?? '';
                          final locality = loc['locality'] ?? '';
                          final isCustom = loc['id']?.toString().contains('custom') == true;

                          return ListTile(
                            leading: CircleAvatar(
                              backgroundColor: isCustom
                                  ? Colors.green.shade100
                                  : const Color(0xFF5B4BDB).withValues(alpha: 0.1),
                              child: Text(
                                '${i + 1}',
                                style: TextStyle(
                                  color: isCustom ? Colors.green.shade800 : const Color(0xFF5B4BDB),
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                            title: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    '$name ($pin)',
                                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                                  ),
                                ),
                                if (isCustom)
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: Colors.green.shade100,
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: const Text(
                                      'USER ADDED',
                                      style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Colors.green),
                                    ),
                                  ),
                              ],
                            ),
                            subtitle: Text(
                              '$locality, $city',
                              style: const TextStyle(fontSize: 11, color: Colors.black54),
                            ),
                            trailing: Chip(
                              label: Text(pin, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              padding: EdgeInsets.zero,
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
