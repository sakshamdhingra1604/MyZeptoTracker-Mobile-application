import 'package:flutter/material.dart';

const _kPrimary = Color(0xFF5B4BDB);

// ── Global Pause Banner (direct mode) ───────────────────────────────────────

class GlobalPauseBanner extends StatelessWidget {
  final int pauseRemainingSec;
  final int blockCount;

  const GlobalPauseBanner({
    super.key,
    required this.pauseRemainingSec,
    required this.blockCount,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Colors.red.shade50,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(children: [
          Icon(Icons.pause_circle_filled, color: Colors.red.shade700),
          const SizedBox(width: 8),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Global circuit breaker active',
                  style: TextStyle(fontWeight: FontWeight.w700)),
              Text(
                'Paused ${pauseRemainingSec}s more • $blockCount block(s). Auto-resumes.',
                style: const TextStyle(fontSize: 12),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

// ── Error Banner ────────────────────────────────────────────────────────────

class ErrorBanner extends StatelessWidget {
  final String message;
  const ErrorBanner({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Colors.amber.shade50,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Text(message,
            style: TextStyle(fontSize: 12, color: Colors.amber.shade900)),
      ),
    );
  }
}

// ── Direct PIN Card ─────────────────────────────────────────────────────────

class DirectPinCard extends StatelessWidget {
  final List<String> pincodes;
  final bool connected;
  final int scansCompleted;
  final int blockCount;
  final VoidCallback onLoadFromFile;
  final VoidCallback? onLoadFromBackend;

  const DirectPinCard({
    super.key,
    required this.pincodes,
    required this.connected,
    required this.scansCompleted,
    required this.blockCount,
    required this.onLoadFromFile,
    this.onLoadFromBackend,
  });

  @override
  Widget build(BuildContext context) {
    final pinCount = pincodes.length;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Expanded(
              child: Text('PIN Codes',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
            ),
            if (pinCount > 0)
              Chip(
                label: Text('$pinCount PINs'),
                backgroundColor: _kPrimary.withValues(alpha: 0.1),
                labelStyle:
                    const TextStyle(color: _kPrimary, fontSize: 12),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
          ]),
          const SizedBox(height: 4),
          const Text(
            'Load a .txt file with 6-digit PINs (one per line or comma-separated). '
            'Or fetch from a connected laptop backend.',
            style: TextStyle(fontSize: 12, color: Colors.black54),
          ),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: onLoadFromFile,
                icon: const Icon(Icons.upload_file, size: 16),
                label: const Text('Load from file'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: connected ? onLoadFromBackend : null,
                icon: const Icon(Icons.cloud_download, size: 16),
                label: const Text('From backend'),
              ),
            ),
          ]),
          if (pinCount > 0) ...[
            const SizedBox(height: 8),
            Text(
              '$pinCount PINs ready  •  $scansCompleted scan(s)  •  $blockCount block(s)',
              style: const TextStyle(fontSize: 12, color: Colors.black54),
            ),
          ],
        ]),
      ),
    );
  }
}

// ── Metric Grid (backend mode) ──────────────────────────────────────────────

class MetricGrid extends StatelessWidget {
  final Map<String, dynamic> status;
  const MetricGrid({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      childAspectRatio: 1.75,
      children: [
        _tile('Mapped records', '${status['locations_total'] ?? 0}',
            Icons.store_mall_directory_outlined),
        _tile('Unique PIN codes', '${status['unique_pins'] ?? 0}',
            Icons.pin_drop_outlined),
        _tile('Rows traversed',
            '${status['locations_checked_last_scan'] ?? 0}', Icons.sync_alt),
        _tile('Scan interval',
            '${status['scan_interval_seconds'] ?? "—"} sec', Icons.timer_outlined),
      ],
    );
  }

  Widget _tile(String title, String value, IconData icon) => Card(
        child: Padding(
          padding: const EdgeInsets.all(13),
          child: Row(children: [
            Icon(icon, size: 24, color: _kPrimary),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(value,
                      style: const TextStyle(
                          fontSize: 20, fontWeight: FontWeight.w800)),
                  Text(title,
                      style: const TextStyle(
                          fontSize: 11, color: Colors.black54)),
                ],
              ),
            ),
          ]),
        ),
      );
}

// ── Actions Card (start / stop / test) ──────────────────────────────────────

class ActionsCard extends StatelessWidget {
  final bool busy;
  final bool running;
  final bool directMode;
  final int pinCount;
  final int scansCompleted;
  final Map<String, dynamic> status;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final VoidCallback onTestNotification;

  const ActionsCard({
    super.key,
    required this.busy,
    required this.running,
    required this.directMode,
    required this.pinCount,
    required this.scansCompleted,
    required this.status,
    required this.onStart,
    required this.onStop,
    required this.onTestNotification,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Monitor controls',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: busy ? null : (running ? onStop : onStart),
              icon: Icon(running
                  ? Icons.stop_circle_outlined
                  : Icons.play_circle_outline),
              label: Text(running ? 'Stop monitoring' : 'Start monitoring'),
              style: FilledButton.styleFrom(
                backgroundColor:
                    running ? Colors.red.shade700 : _kPrimary,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: busy ? null : onTestNotification,
              icon: const Icon(Icons.notifications_active_outlined),
              label: const Text('Test notification'),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            directMode
                ? 'Direct mode • $pinCount PINs • $scansCompleted scan(s) done'
                : 'Last scan: ${status['last_scan_at'] ?? 'Not yet'} • Completed: ${status['scans_completed'] ?? 0}',
            style: const TextStyle(fontSize: 11, color: Colors.black54),
          ),
        ]),
      ),
    );
  }
}

// ── Products Card ───────────────────────────────────────────────────────────

class ProductsCard extends StatelessWidget {
  final List<Map<String, dynamic>> products;
  final List<Map<String, dynamic>> defaultProducts;
  final Map<String, bool> enabled;
  final bool directMode;
  final bool connected;
  final Function(String id, bool value) onToggle;

  const ProductsCard({
    super.key,
    required this.products,
    required this.defaultProducts,
    required this.enabled,
    required this.directMode,
    required this.connected,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final list = products.isEmpty ? defaultProducts : products;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Products to watch',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          const Text(
            'Toggle which products to monitor.',
            style: TextStyle(fontSize: 12, color: Colors.black54),
          ),
          const SizedBox(height: 8),
          ...list.map((p) {
            final id = p['id'].toString();
            return CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: enabled[id] ?? p['enabled'] != false,
              onChanged: (directMode || connected)
                  ? (v) => onToggle(id, v ?? false)
                  : null,
              title: Text((p['name'] ?? id).toString(),
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 14)),
              subtitle: Text((p['query'] ?? '').toString(),
                  style: const TextStyle(fontSize: 11)),
              controlAffinity: ListTileControlAffinity.leading,
              dense: true,
            );
          }),
        ]),
      ),
    );
  }
}
