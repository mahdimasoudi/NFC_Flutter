import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nfc_manager/nfc_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const NfcApp());
}

class AppPalette {
  const AppPalette._();

  static const Color blue = Color(0xFFBEE6FF);
  static const Color lavender = Color(0xFFD3C6F3);
  static const Color pink = Color(0xFFFFD6E5);
  static const Color cream = Color(0xFFF1F3D6);
  static const Color slate = Color(0xFF1B1D26);
}

class NfcApp extends StatelessWidget {
  const NfcApp({super.key});

  @override
  Widget build(BuildContext context) {
    final baseScheme = ColorScheme.fromSeed(seedColor: AppPalette.lavender, brightness: Brightness.light);

    return MaterialApp(
      title: 'NFC Reader',
      theme: ThemeData(
        colorScheme: baseScheme.copyWith(
          primary: AppPalette.lavender,
          secondary: AppPalette.blue,
          surface: Colors.white,
        ),
        scaffoldBackgroundColor: const Color(0xFFF7F8FF),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          foregroundColor: AppPalette.slate,
          elevation: 0,
          centerTitle: false,
        ),
        textTheme: const TextTheme(
          titleLarge: TextStyle(color: AppPalette.slate, fontWeight: FontWeight.w600),
        ),
        useMaterial3: true,
      ),
      home: const NfcHomePage(),
    );
  }
}

class NfcHomePage extends StatefulWidget {
  const NfcHomePage({super.key});

  @override
  State<NfcHomePage> createState() => _NfcHomePageState();
}

class _NfcHomePageState extends State<NfcHomePage> {
  static const _storageKey = 'nfc_logs';

  final List<NfcLogEntry> _logs = <NfcLogEntry>[];
  bool _nfcAvailable = true;
  bool _isScanning = false;
  String? _status = 'Checking NFC availability...';

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await _loadStoredLogs();
    await _refreshAvailability();
  }

  Future<void> _loadStoredLogs() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getStringList(_storageKey) ?? <String>[];
    final decoded = stored.map((value) => jsonDecode(value) as Map<String, dynamic>).map(NfcLogEntry.fromJson).toList();

    if (!mounted) return;
    setState(() {
      _logs
        ..clear()
        ..addAll(decoded);
    });
  }

  Future<void> _refreshAvailability() async {
    try {
      final available = await NfcManager.instance.isAvailable();
      if (!mounted) return;
      setState(() {
        _nfcAvailable = available;
        _status = available ? 'Tap the circle to start scanning' : 'NFC is unavailable. Enable it in system settings.';
      });
    } on PlatformException catch (err) {
      if (!mounted) return;
      setState(() {
        _nfcAvailable = false;
        _status = err.message ?? 'Unable to determine NFC availability.';
      });
    }
  }

  Future<void> _toggleScan() async {
    if (!_nfcAvailable) {
      await _refreshAvailability();
      if (!_nfcAvailable) {
        _showAvailabilityDialog();
        return;
      }
    }

    if (_isScanning) {
      await _stopSession();
    } else {
      await _startSession();
    }
  }

  Future<void> _startSession() async {
    bool tagCaptured = false;

    if (mounted) {
      setState(() {
        _isScanning = true;
        _status = 'Hold your device near an NFC tag';
      });
    }

    try {
      await NfcManager.instance.startSession(
        pollingOptions: const <NfcPollingOption>{NfcPollingOption.iso14443, NfcPollingOption.iso15693},
        onDiscovered: (NfcTag tag) async {
          tagCaptured = true;
          final log = _buildLogEntry(tag);
          await _persistLog(log);

          if (!mounted) return;
          setState(() {
            _isScanning = false;
            _status = 'Tag captured at ${_formatTimestamp(log.timestamp)}';
          });

          try {
            await NfcManager.instance.stopSession();
          } catch (_) {
            // Ignore stop errors when session already closed.
          }
        },
      );
    } on PlatformException catch (err) {
      if (!mounted) return;
      setState(() {
        _isScanning = false;
        _status = err.message ?? 'Failed to start NFC session.';
      });
    } finally {
      if (!mounted || tagCaptured) {
        return;
      }
      setState(() {
        _isScanning = false;
        _status = 'Tap the circle to start scanning';
      });
    }
  }

  Future<void> _stopSession() async {
    try {
      await NfcManager.instance.stopSession();
    } catch (_) {
      // Session might already be closed; ignore.
    }

    if (!mounted) return;
    setState(() {
      _isScanning = false;
      _status = 'Scanning paused. Tap the circle to resume';
    });
  }

  NfcLogEntry _buildLogEntry(NfcTag tag) {
    final data = tag.data;
    final encoded = jsonEncode(data);
    final summary = _extractSummary(data);

    return NfcLogEntry(timestamp: DateTime.now(), summary: summary, rawPayload: encoded);
  }

  String _extractSummary(Map<String, dynamic> data) {
    final ndef = data['ndef'] as Map<String, dynamic>?;
    final cachedMessage = ndef?['cachedMessage'] as Map<String, dynamic>?;
    final records = cachedMessage?['records'] as List<dynamic>?;

    if (records != null && records.isNotEmpty) {
      final record = records.first as Map<String, dynamic>;
      final payload = record['payload'] as List<dynamic>?;
      if (payload != null && payload.isNotEmpty) {
        final bytes = payload.cast<int>();
        final hasLanguagePrefix = bytes.isNotEmpty;
        final textBytes = hasLanguagePrefix && bytes.length > 1 ? bytes.sublist(1) : bytes;
        final text = utf8.decode(textBytes, allowMalformed: true).trim();
        if (text.isNotEmpty) {
          return 'NDEF text: $text';
        }
      }
    }

    final technologies = data.keys.join(', ');
    return technologies.isEmpty ? 'Tag detected' : 'Tag technologies: $technologies';
  }

  Future<void> _persistLog(NfcLogEntry log) async {
    final prefs = await SharedPreferences.getInstance();
    final updated = <NfcLogEntry>[log, ..._logs];
    final trimmed = updated.take(20).toList();
    final serialized = trimmed.map((entry) => jsonEncode(entry.toJson())).toList(growable: false);

    await prefs.setStringList(_storageKey, serialized);

    if (!mounted) return;
    setState(() {
      _logs
        ..clear()
        ..addAll(trimmed);
    });
  }

  void _showLogs() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (context) {
        if (_logs.isEmpty) {
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: const <Widget>[
                Icon(Icons.inbox_outlined, size: 48, color: AppPalette.lavender),
                SizedBox(height: 12),
                Text(
                  'No scans yet',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: AppPalette.slate),
                ),
                SizedBox(height: 8),
                Text('Your NFC scans will appear here once you read your first tag.', textAlign: TextAlign.center),
              ],
            ),
          );
        }

        return SafeArea(
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
            itemBuilder: (context, index) {
              final log = _logs[index];
              return ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                tileColor: AppPalette.cream.withOpacity(0.4),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                title: Text(
                  log.summary,
                  style: const TextStyle(fontWeight: FontWeight.w600, color: AppPalette.slate),
                ),
                subtitle: Text(_formatTimestamp(log.timestamp), style: const TextStyle(color: Colors.black54)),
                onTap: () => _showRawPayload(context, log.rawPayload),
              );
            },
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemCount: _logs.length,
          ),
        );
      },
    );
  }

  void _showRawPayload(BuildContext context, String payload) {
    showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Raw Tag Data'),
          content: SingleChildScrollView(child: SelectableText(payload)),
          actions: <Widget>[TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close'))],
        );
      },
    );
  }

  void _showAvailabilityDialog() {
    showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Enable NFC'),
          content: const Text(
            'NFC appears to be disabled or unsupported on this device. '
            'Check your system settings and try again.',
          ),
          actions: <Widget>[TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('OK'))],
        );
      },
    );
  }

  String _formatTimestamp(DateTime time) {
    final hour = time.hour % 12 == 0 ? 12 : time.hour % 12;
    final minute = time.minute.toString().padLeft(2, '0');
    final period = time.hour >= 12 ? 'PM' : 'AM';
    return '${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')} · $hour:$minute $period';
  }

  @override
  void dispose() {
    if (_isScanning) {
      NfcManager.instance.stopSession();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('NFC Reader'),
        actions: <Widget>[
          TextButton.icon(
            onPressed: _showLogs,
            icon: const Icon(Icons.receipt_long, size: 20),
            label: const Text('Logs'),
            style: TextButton.styleFrom(foregroundColor: AppPalette.slate),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            const SizedBox(height: 48),
            Text('Ready to read NFC', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            Text(
              _status ?? '',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.black54),
            ),
            const Spacer(),
            GestureDetector(
              onTap: _toggleScan,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 280),
                width: 200,
                height: 200,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: _isScanning
                      ? const LinearGradient(
                          colors: <Color>[AppPalette.blue, AppPalette.lavender, AppPalette.pink, AppPalette.cream],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        )
                      : null,
                  color: _isScanning ? null : AppPalette.blue.withOpacity(0.35),
                  border: Border.all(
                    color: _isScanning ? Colors.transparent : AppPalette.lavender.withOpacity(0.7),
                    width: 6,
                  ),
                  boxShadow: _isScanning
                      ? const <BoxShadow>[BoxShadow(color: AppPalette.pink, blurRadius: 28, spreadRadius: 2)]
                      : const <BoxShadow>[],
                ),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Icon(
                        _isScanning ? Icons.nfc_rounded : Icons.power_settings_new,
                        size: 48,
                        color: AppPalette.slate,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _isScanning ? 'Scanning...' : 'Tap to scan',
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: AppPalette.slate),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const Spacer(flex: 2),
          ],
        ),
      ),
    );
  }
}

class NfcLogEntry {
  const NfcLogEntry({required this.timestamp, required this.summary, required this.rawPayload});

  final DateTime timestamp;
  final String summary;
  final String rawPayload;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'timestamp': timestamp.toIso8601String(),
    'summary': summary,
    'rawPayload': rawPayload,
  };

  factory NfcLogEntry.fromJson(Map<String, dynamic> json) {
    return NfcLogEntry(
      timestamp: DateTime.parse(json['timestamp'] as String),
      summary: json['summary'] as String,
      rawPayload: json['rawPayload'] as String,
    );
  }
}
