import 'package:flutter/material.dart';
import '../services/notification_service.dart';

// ── Events Card (backend mode alerts) ───────────────────────────────────────

class EventsCard extends StatelessWidget {
  final List<Map<String, dynamic>> events;
  const EventsCard({super.key, required this.events});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Expanded(
              child: Text('Availability alerts',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
            ),
            Text('${events.length}',
                style: const TextStyle(color: Colors.black54)),
          ]),
          const SizedBox(height: 10),
          if (events.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 18),
              child: Center(
                child: Text(
                  'No alerts yet. Use Test notification to test the flow.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.black54),
                ),
              ),
            )
          else
            ...events.take(30).map(_eventTile),
        ]),
      ),
    );
  }

  Widget _eventTile(Map<String, dynamic> event) {
    final demo = event['is_demo'] == true;
    final name = (event['product_name'] ?? 'Product').toString();
    final loc = [event['location_name'], event['city'], event['pin_code']]
        .where((v) => v != null && v.toString().trim().isNotEmpty)
        .map((v) => v.toString())
        .join(' • ');
    final price = event['price'] == null
        ? 'Price not supplied'
        : '₹${event['price']}';
    final variant = (event['variant'] ?? 'Variant not supplied').toString();

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.black12),
        borderRadius: BorderRadius.circular(14),
        color: Colors.white,
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
              child: Text(name,
                  style: const TextStyle(fontWeight: FontWeight.w800))),
          if (demo)
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.amber.shade100,
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Text('TEST',
                  style:
                      TextStyle(fontSize: 10, fontWeight: FontWeight.w800)),
            ),
        ]),
        const SizedBox(height: 5),
        Text('$price • $variant', style: const TextStyle(fontSize: 13)),
        const SizedBox(height: 3),
        Text(loc,
            style: const TextStyle(fontSize: 12, color: Colors.black54)),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.tonalIcon(
            onPressed: () => openProductUrl(event['product_url']?.toString()),
            icon: const Icon(Icons.shopping_bag_outlined, size: 16),
            label: const Text('Open in Zepto'),
          ),
        ),
      ]),
    );
  }
}

// ── Direct Results Card (phone-direct mode) ─────────────────────────────────

class DirectResultsCard extends StatelessWidget {
  final List<Map<String, dynamic>> results;
  const DirectResultsCard({super.key, required this.results});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Expanded(
              child: Text('Found Items 🎉',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
            ),
            Text('${results.length}',
                style: const TextStyle(color: Colors.black54)),
          ]),
          const SizedBox(height: 8),
          ...results.take(20).map(_resultTile),
        ]),
      ),
    );
  }

  Widget _resultTile(Map<String, dynamic> r) {
    final name = r['product_name']?.toString() ?? 'Product';
    final pin = r['pincode']?.toString() ?? '';
    final price = r['price'] == null ? 'N/A' : '₹${r['price']}';
    final variant = r['variant']?.toString() ?? 'In stock';
    final url =
        r['product_url']?.toString() ?? 'https://www.zeptonow.com/';

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.green.shade50,
        border: Border.all(color: Colors.green.shade200),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(children: [
        const Icon(Icons.check_circle, color: Colors.green, size: 20),
        const SizedBox(width: 8),
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name,
                style: const TextStyle(
                    fontWeight: FontWeight.w700, fontSize: 13)),
            Text('$price • $variant',
                style:
                    const TextStyle(fontSize: 12, color: Colors.black87)),
            Text('PIN: $pin',
                style:
                    const TextStyle(fontSize: 11, color: Colors.black54)),
          ]),
        ),
        IconButton(
          icon: const Icon(Icons.open_in_new, size: 18),
          tooltip: 'Open in Zepto',
          onPressed: () => openProductUrl(url),
        ),
      ]),
    );
  }
}
