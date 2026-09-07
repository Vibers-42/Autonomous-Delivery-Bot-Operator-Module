// screens/delivery_management_screen.dart
// Operator Delivery Management — Create, track, and update all resident deliveries.
// Integrates with resident_routes.py backend endpoints.

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:http/http.dart' as http;
import 'package:navix_app/providers/robot_state_provider.dart';
import 'package:navix_app/utils/hud_colors.dart';

// ── Delivery status list ─────────────────────────────────────────────────────
const _statuses = [
  'ORDER_CREATED',
  'PARCEL_RECEIVED',
  'PARCEL_VERIFIED',
  'MISSION_CREATED',
  'ROBOT_ASSIGNED',
  'ROBOT_STARTED',
  'EN_ROUTE',
  'ARRIVED_AT_BUILDING',
  'ELEVATOR_TRANSIT',
  'ARRIVED_AT_FLOOR',
  'APPROACHING_APARTMENT',
  'ARRIVED',
  'RESIDENT_NOTIFIED',
  'RESIDENT_READY',
  'OTP_VERIFIED',
  'DELIVERED',
  'RETURNING',
  'COMPLETED',
  'FAILED',
  'CANCELLED',
];

const _statusLabels = {
  'ORDER_CREATED': 'Order Created',
  'PARCEL_RECEIVED': 'Parcel Received',
  'PARCEL_VERIFIED': 'Parcel Verified',
  'MISSION_CREATED': 'Mission Created',
  'ROBOT_ASSIGNED': 'Robot Assigned',
  'ROBOT_STARTED': 'Robot Started',
  'EN_ROUTE': 'On the Way',
  'ARRIVED_AT_BUILDING': 'At Building',
  'ELEVATOR_TRANSIT': 'In Elevator',
  'ARRIVED_AT_FLOOR': 'At Your Floor',
  'APPROACHING_APARTMENT': 'Approaching Apt',
  'ARRIVED': 'Robot Arrived',
  'RESIDENT_NOTIFIED': 'Resident Notified',
  'RESIDENT_READY': 'Resident Ready',
  'OTP_VERIFIED': 'OTP Verified',
  'DELIVERED': 'Delivered',
  'RETURNING': 'Returning',
  'COMPLETED': 'Completed',
  'FAILED': 'Failed',
  'CANCELLED': 'Cancelled',
};

Color _statusColor(String status) {
  if (['DELIVERED', 'COMPLETED'].contains(status)) return HudColors.teal;
  if (['FAILED', 'CANCELLED'].contains(status)) return HudColors.magenta;
  if (['ARRIVED', 'RESIDENT_READY', 'OTP_VERIFIED'].contains(status))
    return const Color(0xFFFFC107);
  if (['ROBOT_STARTED', 'EN_ROUTE', 'APPROACHING_APARTMENT'].contains(status))
    return const Color(0xFF4FC3F7);
  return const Color(0xFF78909C);
}

// ── Operator API helpers ─────────────────────────────────────────────────────
class _OperatorApi {
  final String baseUrl;
  final String token;
  const _OperatorApi({required this.baseUrl, required this.token});

  Map<String, String> get _headers => {
    'Content-Type': 'application/json',
    'Authorization': 'Bearer $token',
  };

  Future<Map<String, dynamic>> _get(String path) async {
    final r = await http
        .get(Uri.parse('$baseUrl$path'), headers: _headers)
        .timeout(const Duration(seconds: 10));
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body,
  ) async {
    final r = await http
        .post(
          Uri.parse('$baseUrl$path'),
          headers: _headers,
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 10));
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> _put(
    String path,
    Map<String, dynamic> body,
  ) async {
    final r = await http
        .put(
          Uri.parse('$baseUrl$path'),
          headers: _headers,
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 10));
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> login(String email, String password) async {
    final r = await http
        .post(
          Uri.parse('$baseUrl/auth/login'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'email': email, 'password': password}),
        )
        .timeout(const Duration(seconds: 10));
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  Future<List<dynamic>> getUsers() async {
    final r = await _get('/operator/users');
    return r['users'] as List? ?? [];
  }

  Future<List<dynamic>> getDeliveries() async {
    final r = await _get('/operator/deliveries');
    return r['deliveries'] as List? ?? [];
  }

  Future<List<dynamic>> getCommunities() async {
    final r = await _get('/operator/communities');
    return r['communities'] as List? ?? [];
  }

  Future<Map<String, dynamic>> createDelivery(
    String residentId,
    String communityId,
    String apartmentId,
    String? notes,
  ) async {
    return _post('/operator/deliveries', {
      'resident_id': residentId,
      'community_id': communityId,
      'apartment_id': apartmentId,
      if (notes != null && notes.isNotEmpty) 'notes': notes,
    });
  }

  Future<Map<String, dynamic>> updateStatus(
    String deliveryId,
    String status, {
    int? etaSeconds,
  }) async {
    return _put('/operator/deliveries/$deliveryId/status', {
      'status': status,
      if (etaSeconds != null) 'estimated_eta_seconds': etaSeconds,
    });
  }
}

// ── Main Screen ──────────────────────────────────────────────────────────────
class DeliveryManagementScreen extends StatefulWidget {
  const DeliveryManagementScreen({super.key});

  @override
  State<DeliveryManagementScreen> createState() =>
      _DeliveryManagementScreenState();
}

class _DeliveryManagementScreenState extends State<DeliveryManagementScreen> {
  _OperatorApi? _api;
  bool _loggedIn = false;
  bool _authLoading = false;
  String? _authError;
  final _emailCtrl = TextEditingController(text: 'admin@navix.local');
  final _passCtrl = TextEditingController(text: 'navix2024');

  List<dynamic> _deliveries = [];
  List<dynamic> _users = [];
  bool _loading = false;
  String? _dataError;
  Timer? _refreshTimer;

  String? _selectedResidentId;
  String? _selectedCommunityId;
  String? _selectedApartmentId;
  final _notesCtrl = TextEditingController();

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _emailCtrl.dispose();
    _passCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    final provider = context.read<RobotStateProvider>();
    final baseUrl = "http://${provider.backendIp}";
    setState(() {
      _authLoading = true;
      _authError = null;
    });
    try {
      final tempApi = _OperatorApi(baseUrl: baseUrl, token: '');
      final res = await tempApi.login(
        _emailCtrl.text.trim(),
        _passCtrl.text.trim(),
      );
      if (res['access_token'] != null) {
        _api = _OperatorApi(
          baseUrl: baseUrl,
          token: res['access_token'] as String,
        );
        _loggedIn = true;
        await _refresh();
        _refreshTimer = Timer.periodic(const Duration(seconds: 10), (_) {
          if (mounted) _silentRefresh();
        });
      } else {
        _authError = res['detail']?.toString() ?? 'Login failed';
      }
    } catch (e) {
      _authError = 'Connection error: ${e.toString()}';
    } finally {
      if (mounted) setState(() => _authLoading = false);
    }
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _dataError = null;
    });
    try {
      final results = await Future.wait([
        _api!.getDeliveries(),
        _api!.getUsers(),
      ]);
      if (mounted) {
        setState(() {
          _deliveries = results[0];
          _users = results[1];
        });
      }
    } catch (e) {
      if (mounted) setState(() => _dataError = 'Load error: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _silentRefresh() async {
    try {
      final dels = await _api!.getDeliveries();
      if (mounted) setState(() => _deliveries = dels);
    } catch (_) {}
  }

  void _showCreateDialog() {
    _selectedResidentId = null;
    _selectedCommunityId = null;
    _selectedApartmentId = null;
    _notesCtrl.clear();

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => AlertDialog(
          backgroundColor: HudColors.cardBg,
          title: const Text(
            'Create New Delivery',
            style: TextStyle(color: Colors.white),
          ),
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: _selectedResidentId,
                  dropdownColor: HudColors.cardBg,
                  decoration: const InputDecoration(
                    labelText: 'Select Resident',
                    labelStyle: TextStyle(color: HudColors.textMuted),
                    enabledBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: HudColors.border),
                    ),
                  ),
                  style: const TextStyle(color: Colors.white),
                  items: _users
                      .where((u) => u['role'] == 'RESIDENT')
                      .map(
                        (u) => DropdownMenuItem<String>(
                          value: u['id'] as String,
                          child: Text(
                            '${u['name']} — ${u['apartment_id'] ?? 'No Apt'}',
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: (v) {
                    setDlgState(() {
                      _selectedResidentId = v;
                      final r = _users.firstWhere(
                        (u) => u['id'] == v,
                        orElse: () => null,
                      );
                      _selectedCommunityId = r?['community_id'] as String?;
                      _selectedApartmentId = r?['apartment_id'] as String?;
                    });
                  },
                ),
                const SizedBox(height: 10),
                if (_selectedApartmentId != null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Apt: $_selectedApartmentId | Community: $_selectedCommunityId',
                      style: const TextStyle(
                        color: HudColors.teal,
                        fontSize: 11,
                      ),
                    ),
                  ),
                const SizedBox(height: 10),
                TextField(
                  controller: _notesCtrl,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    labelText: 'Notes (optional)',
                    labelStyle: TextStyle(color: HudColors.textMuted),
                    enabledBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: HudColors.border),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text(
                'Cancel',
                style: TextStyle(color: HudColors.textMuted),
              ),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: HudColors.teal),
              onPressed:
                  (_selectedResidentId == null ||
                      _selectedCommunityId == null ||
                      _selectedApartmentId == null)
                  ? null
                  : () async {
                      Navigator.pop(ctx);
                      try {
                        final res = await _api!.createDelivery(
                          _selectedResidentId!,
                          _selectedCommunityId!,
                          _selectedApartmentId!,
                          _notesCtrl.text.trim().isEmpty
                              ? null
                              : _notesCtrl.text.trim(),
                        );
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                'Delivery created: ${res['order_id']}',
                              ),
                              backgroundColor: HudColors.teal,
                            ),
                          );
                          await _silentRefresh();
                        }
                      } catch (e) {
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('Error: $e'),
                              backgroundColor: HudColors.magenta,
                            ),
                          );
                        }
                      }
                    },
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    );
  }

  void _showStatusDialog(Map<String, dynamic> delivery) {
    String? newStatus = delivery['status'] as String?;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => AlertDialog(
          backgroundColor: HudColors.cardBg,
          title: Text(
            'Update: ${delivery['order_id']}',
            style: const TextStyle(color: Colors.white),
          ),
          content: SizedBox(
            width: 350,
            child: DropdownButtonFormField<String>(
              initialValue: newStatus,
              dropdownColor: HudColors.cardBg,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'New Status',
                labelStyle: TextStyle(color: HudColors.textMuted),
              ),
              items: _statuses
                  .map(
                    (s) => DropdownMenuItem(
                      value: s,
                      child: Text(_statusLabels[s] ?? s),
                    ),
                  )
                  .toList(),
              onChanged: (v) => setDlgState(() => newStatus = v),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text(
                'Cancel',
                style: TextStyle(color: HudColors.textMuted),
              ),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: HudColors.teal),
              onPressed: newStatus == null
                  ? null
                  : () async {
                      Navigator.pop(ctx);
                      try {
                        await _api!.updateStatus(
                          delivery['id'] as String,
                          newStatus!,
                        );
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                'Status updated — resident notified',
                              ),
                              backgroundColor: HudColors.teal,
                            ),
                          );
                          await _silentRefresh();
                        }
                      } catch (e) {
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('Error: $e'),
                              backgroundColor: HudColors.magenta,
                            ),
                          );
                        }
                      }
                    },
              child: const Text('Update & Notify'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_loggedIn) return _buildLoginPanel();
    return Column(
      children: [
        // Header
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          decoration: const BoxDecoration(
            color: HudColors.cardBg,
            border: Border(bottom: BorderSide(color: HudColors.border)),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.local_shipping_outlined,
                color: HudColors.teal,
                size: 20,
              ),
              const SizedBox(width: 10),
              const Text(
                'DELIVERY MANAGEMENT',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                  fontSize: 13,
                ),
              ),
              const Spacer(),
              if (_loading)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: HudColors.teal,
                  ),
                ),
              IconButton(
                icon: const Icon(
                  Icons.refresh_outlined,
                  color: HudColors.textMuted,
                  size: 18,
                ),
                onPressed: _loading ? null : _refresh,
              ),
              const SizedBox(width: 6),
              ElevatedButton.icon(
                icon: const Icon(Icons.add, size: 16),
                label: const Text(
                  'New Delivery',
                  style: TextStyle(fontSize: 12),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: HudColors.teal,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                ),
                onPressed: _showCreateDialog,
              ),
            ],
          ),
        ),

        if (_dataError != null)
          Container(
            color: HudColors.magenta.withValues(alpha: 0.1),
            padding: const EdgeInsets.all(10),
            child: Text(
              _dataError!,
              style: const TextStyle(color: HudColors.magenta, fontSize: 12),
            ),
          ),

        // Stats
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 14, 24, 0),
          child: Row(
            children: [
              _stat('TOTAL', _deliveries.length),
              const SizedBox(width: 12),
              _stat(
                'ACTIVE',
                _deliveries
                    .where(
                      (d) => ![
                        'DELIVERED',
                        'COMPLETED',
                        'FAILED',
                        'CANCELLED',
                      ].contains(d['status']),
                    )
                    .length,
              ),
              const SizedBox(width: 12),
              _stat(
                'DELIVERED',
                _deliveries.where((d) => d['status'] == 'DELIVERED').length,
              ),
              const SizedBox(width: 12),
              _stat(
                'RESIDENTS',
                _users.where((u) => u['role'] == 'RESIDENT').length,
              ),
            ],
          ),
        ),

        // List
        Expanded(
          child: _deliveries.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('📦', style: TextStyle(fontSize: 48)),
                      const SizedBox(height: 12),
                      Text(
                        _loading ? 'Loading...' : 'No deliveries yet.',
                        style: const TextStyle(color: HudColors.textMuted),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(24, 14, 24, 24),
                  itemCount: _deliveries.length,
                  itemBuilder: (ctx, i) =>
                      _buildCard(_deliveries[i] as Map<String, dynamic>),
                ),
        ),
      ],
    );
  }

  Widget _stat(String label, int count) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
    decoration: BoxDecoration(
      color: HudColors.bg,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: HudColors.border),
    ),
    child: Column(
      children: [
        Text(
          '$count',
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 18,
          ),
        ),
        Text(
          label,
          style: const TextStyle(
            color: HudColors.textMuted,
            fontSize: 9,
            letterSpacing: 1,
          ),
        ),
      ],
    ),
  );

  Widget _buildCard(Map<String, dynamic> d) {
    final status = d['status'] as String? ?? '';
    final color = _statusColor(status);
    final label = _statusLabels[status] ?? status;
    final isTerminal = [
      'DELIVERED',
      'COMPLETED',
      'FAILED',
      'CANCELLED',
    ].contains(status);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: HudColors.cardBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        leading: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            shape: BoxShape.circle,
            border: Border.all(color: color.withValues(alpha: 0.4)),
          ),
          child: Center(
            child: Icon(
              isTerminal
                  ? (status == 'DELIVERED'
                        ? Icons.check_circle_outline
                        : Icons.cancel_outlined)
                  : Icons.local_shipping_outlined,
              color: color,
              size: 18,
            ),
          ),
        ),
        title: Row(
          children: [
            Text(
              d['order_id'] as String? ?? 'N/A',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 13,
              ),
            ),
            const SizedBox(width: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: color.withValues(alpha: 0.4),
                  width: 0.5,
                ),
              ),
              child: Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Text(
            'Apt: ${d['apartment_id'] ?? '--'}',
            style: const TextStyle(color: HudColors.textMuted, fontSize: 11),
          ),
        ),
        trailing: isTerminal
            ? const Icon(
                Icons.lock_outline,
                color: HudColors.textMuted,
                size: 16,
              )
            : IconButton(
                icon: const Icon(
                  Icons.edit_outlined,
                  color: HudColors.teal,
                  size: 18,
                ),
                tooltip: 'Update status',
                onPressed: () => _showStatusDialog(d),
              ),
      ),
    );
  }

  Widget _buildLoginPanel() {
    return Center(
      child: SizedBox(
        width: 360,
        child: Container(
          padding: const EdgeInsets.all(32),
          decoration: BoxDecoration(
            color: HudColors.cardBg,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: HudColors.border),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.local_shipping_outlined,
                color: HudColors.teal,
                size: 44,
              ),
              const SizedBox(height: 14),
              const Text(
                'Delivery Management',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 20,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Sign in as operator',
                style: TextStyle(color: HudColors.textMuted, fontSize: 12),
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _emailCtrl,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'Email',
                  labelStyle: TextStyle(color: HudColors.textMuted),
                  enabledBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: HudColors.border),
                  ),
                  focusedBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: HudColors.teal),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _passCtrl,
                obscureText: true,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'Password',
                  labelStyle: TextStyle(color: HudColors.textMuted),
                  enabledBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: HudColors.border),
                  ),
                  focusedBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: HudColors.teal),
                  ),
                ),
                onSubmitted: (_) => _login(),
              ),
              if (_authError != null) ...[
                const SizedBox(height: 10),
                Text(
                  _authError!,
                  style: const TextStyle(
                    color: HudColors.magenta,
                    fontSize: 12,
                  ),
                ),
              ],
              const SizedBox(height: 22),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: HudColors.teal,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  onPressed: _authLoading ? null : _login,
                  child: _authLoading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.black,
                          ),
                        )
                      : const Text(
                          'Sign In',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                'Default: admin@navix.local / navix2024',
                style: TextStyle(color: HudColors.textMuted, fontSize: 10),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
