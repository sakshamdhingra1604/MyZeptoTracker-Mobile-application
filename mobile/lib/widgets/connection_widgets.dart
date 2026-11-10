import 'package:flutter/material.dart';

const _kPrimary = Color(0xFF5B4BDB);

// ── Mode Toggle ─────────────────────────────────────────────────────────────

class ModeToggleCard extends StatelessWidget {
  final bool directMode;
  final ValueChanged<bool> onChanged;

  const ModeToggleCard({
    super.key,
    required this.directMode,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      color: _kPrimary.withValues(alpha: 0.05),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(children: [
          Icon(directMode ? Icons.phone_android : Icons.computer,
              color: _kPrimary, size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    directMode ? 'Phone-Direct Mode' : 'Laptop Backend Mode',
                    style: const TextStyle(
                        fontWeight: FontWeight.w800, fontSize: 15),
                  ),
                  Text(
                    directMode
                        ? 'Phone checks Zepto directly. No laptop needed.'
                        : 'Laptop runs Python backend. Phone shows alerts.',
                    style:
                        const TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                ]),
          ),
          Switch(
              value: directMode,
              activeThumbColor: _kPrimary,
              onChanged: onChanged),
        ]),
      ),
    );
  }
}

// ── Status Banner (backend mode) ────────────────────────────────────────────

class StatusBanner extends StatelessWidget {
  final String mode;
  final String phase;
  final bool blocked;
  final bool running;
  final String? pauseReason;
  final VoidCallback onRefresh;

  const StatusBanner({
    super.key,
    required this.mode,
    required this.phase,
    required this.blocked,
    required this.running,
    this.pauseReason,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    final Color tone = blocked
        ? Colors.red
        : (mode == 'demo'
            ? Colors.amber.shade800
            : (running ? Colors.green.shade700 : Colors.blueGrey));
    final String title = blocked
        ? 'Checks paused by safety circuit breaker'
        : (mode == 'demo'
            ? 'DEMO MODE — no live Zepto requests'
            : (running ? 'Monitoring active' : 'Ready to monitor'));
    final String detail = blocked
        ? (pauseReason ?? 'The endpoint denied/rate-limited checks.')
        : 'Backend phase: $phase • Source mode: $mode';

    return Card(
      color: tone.withValues(alpha: 0.08),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(
            blocked
                ? Icons.pause_circle_filled
                : (mode == 'demo' ? Icons.science_outlined : Icons.radar),
            color: tone,
            size: 28,
          ),
          const SizedBox(width: 12),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title,
                  style: TextStyle(fontWeight: FontWeight.w800, color: tone)),
              const SizedBox(height: 4),
              Text(detail, style: const TextStyle(fontSize: 12)),
            ]),
          ),
          IconButton(
              onPressed: onRefresh,
              icon: const Icon(Icons.refresh),
              tooltip: 'Refresh status'),
        ]),
      ),
    );
  }
}

// ── Settings Card (backend connection) ──────────────────────────────────────

class SettingsCard extends StatelessWidget {
  final TextEditingController apiController;
  final TextEditingController keyController;
  final bool busy;
  final VoidCallback onConnect;
  final VoidCallback onImportExcel;

  const SettingsCard({
    super.key,
    required this.apiController,
    required this.keyController,
    required this.busy,
    required this.onConnect,
    required this.onImportExcel,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Backend connection',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
          const SizedBox(height: 10),
          TextField(
            controller: apiController,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'Laptop backend URL',
              hintText: 'http://192.168.1.10:8765',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: keyController,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'API key',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: busy ? null : onConnect,
                icon: const Icon(Icons.link),
                label: const Text('Connect'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: busy ? null : onImportExcel,
                icon: const Icon(Icons.upload_file),
                label: const Text('Import Excel'),
              ),
            ),
          ]),
          const SizedBox(height: 4),
          const Text(
            'Phone and laptop must be on the same Wi-Fi. Use the laptop LAN IP.',
            style: TextStyle(fontSize: 12, color: Colors.black54),
          ),
        ]),
      ),
    );
  }
}
