import 'package:flutter/material.dart';
import 'package:flutter_application_1/screens/customer/booking_flow_screen.dart';
import 'package:flutter_application_1/theme/app_theme.dart';
import 'package:flutter_application_1/extensions/context_extensions.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../services/timezone_service.dart';

class MyBookingsScreen extends StatefulWidget {
  final int? highlightId;

  const MyBookingsScreen({super.key, this.highlightId});

  @override
  State<MyBookingsScreen> createState() => _MyBookingsScreenState();
}

class _MyBookingsScreenState extends State<MyBookingsScreen>
    with SingleTickerProviderStateMixin {
  final supabase = Supabase.instance.client;

  List<Map<String, dynamic>> _bookings = [];
  List<Map<String, dynamic>> _overflowNotifications = [];
  bool _isLoading = true;
  String? _error;

  // Tab controller
  late TabController _tabController;

  // Colors
  final Color _vipColor = const Color(0xFF9C27B0);
  final Color _regularColor = const Color(0xFF4CAF50);

  // Loading states
  bool _isCancelling = false;
  bool _isProcessingOverflow = false;

  // ✅ Web Scroll Controller
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _loadData();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  // =====================================================
  // ✅ CURRENCY SYMBOL HELPER
  // =====================================================
  String _getCurrencySymbol(String? code) {
    switch (code) {
      case 'USD':
        return '\$';
      case 'INR':
        return '₹';
      case 'GBP':
        return '£';
      case 'EUR':
        return '€';
      case 'AUD':
        return 'A\$';
      case 'AED':
        return 'د.إ';
      case 'CAD':
        return 'C\$';
      case 'JPY':
        return '¥';
      case 'SGD':
        return 'S\$';
      case 'MYR':
        return 'RM';
      case 'LKR':
      default:
        return 'Rs.';
    }
  }

  Future<void> _loadData() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    await Future.wait([_loadBookings(), _loadOverflowNotifications()]);

    setState(() => _isLoading = false);
  }

  // =====================================================
  // ✅ LOAD BOOKINGS (Multi-service + discounts + extra charge)
  // =====================================================
  Future<void> _loadBookings() async {
    try {
      final user = supabase.auth.currentUser;
      if (user == null) {
        setState(() {
          _error = 'Please login to view your bookings';
          _isLoading = false;
        });
        return;
      }

      // ✅ Get customer role ID dynamically
      final roleResponse = await supabase
          .from('roles')
          .select('id')
          .eq('name', 'customer')
          .single();

      final customerRoleId = roleResponse['id'];

      // ✅ Check if user has active customer role
      final roleCheck = await supabase
          .from('user_roles')
          .select('status')
          .eq('user_id', user.id)
          .eq('role_id', customerRoleId)
          .maybeSingle();

      if (roleCheck == null || roleCheck['status'] != 'active') {
        setState(() {
          _error = 'Your account is not active. Please contact support.';
          _isLoading = false;
        });
        return;
      }

      // ✅ Get followed salons
      final followedSalons = await supabase
          .from('salon_followers')
          .select('salon_id')
          .eq('customer_id', user.id);

      final followedSalonIds =
          followedSalons.map((f) => f['salon_id'] as int).toList();

      if (followedSalonIds.isEmpty) {
        setState(() {
          _bookings = [];
          _isLoading = false;
        });
        return;
      }

      // ✅ NEW: Fetch appointments WITH appointment_services join
      final appointments = await supabase
          .from('appointments')
          .select('''
            *,
            appointment_services (
              id,
              service_id,
              variant_id,
              price,
              discount_amount,
              discount_type,
              final_price,
              currency_code,
              is_original,
              services!inner (id, name, description),
              service_variants (
                id,
                duration,
                price,
                salon_genders (display_name),
                salon_age_categories (display_name)
              ),
              offers (id, title, discount_type, discount_value)
            )
          ''')
          .eq('customer_id', user.id)
          .inFilter('salon_id', followedSalonIds)
          .order('appointment_date', ascending: false);

      final now = DateTime.now();
      final todayLocal = DateTime(now.year, now.month, now.day);
      final List<Map<String, dynamic>> processedBookings = [];

      for (var booking in appointments) {
        // ✅ Get salon details with currency
        final salon = await supabase
            .from('salons')
            .select('name, address, currency_code, currency_symbol')
            .eq('id', booking['salon_id'])
            .maybeSingle();

        // ✅ Get barber name
        String barberName = 'Barber';
        if (booking['barber_id'] != null) {
          final barber = await supabase
              .from('profiles')
              .select('full_name')
              .eq('id', booking['barber_id'])
              .maybeSingle();
          if (barber != null) {
            barberName = barber['full_name'] ?? 'Barber';
          }
        }

        // ✅ Process appointment_services (multi-service)
        final apptServices = (booking['appointment_services'] as List?) ?? [];

        final List<Map<String, dynamic>> services = [];
        double servicesSubtotal = 0.0;
        double totalDiscount = 0.0;
        double servicesFinalTotal = 0.0;
        int totalDuration = 0;

        for (var svc in apptServices) {
          final serviceName = svc['services']?['name'] ?? 'Service';
          final variant = svc['service_variants'] ?? {};
          final offer = svc['offers'];

          final price = (svc['price'] as num?)?.toDouble() ?? 0.0;
          final discount = (svc['discount_amount'] as num?)?.toDouble() ?? 0.0;
          final finalPrice = (svc['final_price'] as num?)?.toDouble() ?? 0.0;
          final duration = (variant['duration'] as num?)?.toInt() ?? 30;

          servicesSubtotal += price;
          totalDiscount += discount;
          servicesFinalTotal += finalPrice;
          totalDuration += duration;

          services.add({
            'appointment_service_id': svc['id'],
            'service_id': svc['service_id'],
            'service_name': serviceName,
            'variant_id': svc['variant_id'],
            'duration': duration,
            'price': price,
            'discount_amount': discount,
            'discount_type': svc['discount_type'],
            'final_price': finalPrice,
            'is_original': svc['is_original'] ?? false,
            'offer_title': offer?['title'],
            'offer_id': offer?['id'],
            'gender': variant['salon_genders']?['display_name'],
            'age': variant['salon_age_categories']?['display_name'],
          });
        }

        // ✅ Extra charge
        final extraCharge = (booking['extra_charge'] as num?)?.toDouble() ?? 0.0;
        final extraNote = booking['extra_charge_note'] as String?;

        // ✅ TOTAL = services final + extra charge
        final totalPrice = servicesFinalTotal + extraCharge;

        final currencyCode = (salon?['currency_code'] as String?) ?? 'LKR';

        // ✅ Service summary for backward compat
        String serviceSummary;
        if (services.isEmpty) {
          serviceSummary = 'No services';
        } else if (services.length == 1) {
          serviceSummary = services.first['service_name'] as String;
        } else {
          serviceSummary =
              '${services.first['service_name']} +${services.length - 1} more';
        }

        // ✅ TIME CONVERSION (UTC to LOCAL)
        final utcDate = DateTime.parse(booking['appointment_date']);
        final utcStartTime = booking['start_time'] as String;
        final utcEndTime = booking['end_time'] as String;

        final localStartTime = TimezoneService.utcToLocalTimeForDate(
          utcStartTime,
          utcDate,
        );
        final localEndTime = TimezoneService.utcToLocalTimeForDate(
          utcEndTime,
          utcDate,
        );

        final localDate = DateTime(utcDate.year, utcDate.month, utcDate.day);

        // ✅ Status category
        String statusCategory = 'upcoming';
        final status = booking['status'];
        if (status == 'cancelled' || status == 'no_show') {
          statusCategory = 'cancelled';
        } else if (status == 'completed') {
          statusCategory = 'completed';
        } else if (localDate.isBefore(todayLocal)) {
          statusCategory = 'completed';
        } else {
          statusCategory = 'upcoming';
        }

        // ✅ Queue number
        final isVip = booking['is_vip'] ?? false;
        String displayQueueNumber = '';

        if (isVip) {
          final vipNum = booking['vip_queue_number'];
          if (vipNum != null) {
            displayQueueNumber = 'VIP-$vipNum';
          } else if (booking['queue_number'] != null) {
            displayQueueNumber = 'VIP-${booking['queue_number']}';
          }
        } else {
          final regNum = booking['regular_queue_number'];
          if (regNum != null) {
            displayQueueNumber = 'Q$regNum';
          } else if (booking['queue_number'] != null) {
            displayQueueNumber = 'Q${booking['queue_number']}';
          }
        }

        processedBookings.add({
          ...booking,
          'local_start_time': localStartTime,
          'local_end_time': localEndTime,
          'status_category': statusCategory,
          'salon_name': salon?['name'] ?? 'Salon',
          'salon_address': salon?['address'],
          'currency_code': currencyCode,
          'barber_name': barberName,
          // ✅ Multi-service
          'services': services,
          'service_count': services.length,
          'service_name': serviceSummary,
          // ✅ Price breakdown
          'services_subtotal': servicesSubtotal,
          'total_discount': totalDiscount,
          'services_final_total': servicesFinalTotal,
          'extra_charge': extraCharge,
          'extra_charge_note': extraNote,
          'price': totalPrice,
          'duration': totalDuration,
          // ✅ Queue
          'display_queue_number': displayQueueNumber,
          'queue_position': booking['queue_position'],
          'is_vip': isVip,
        });
      }

      setState(() {
        _bookings = processedBookings;
      });
    } catch (e) {
      debugPrint('❌ Error loading bookings: $e');
      setState(() {
        _error = 'Failed to load bookings: $e';
      });
    } finally {
      setState(() => _isLoading = false);
    }
  }

  // =====================================================
  // LOAD OVERFLOW NOTIFICATIONS (unchanged)
  // =====================================================
  Future<void> _loadOverflowNotifications() async {
    try {
      final user = supabase.auth.currentUser;
      if (user == null) return;

      final roleResponse = await supabase
          .from('roles')
          .select('id')
          .eq('name', 'customer')
          .single();

      final customerRoleId = roleResponse['id'];

      final roleCheck = await supabase
          .from('user_roles')
          .select('status')
          .eq('user_id', user.id)
          .eq('role_id', customerRoleId)
          .maybeSingle();

      if (roleCheck == null || roleCheck['status'] != 'active') {
        setState(() => _overflowNotifications = []);
        return;
      }

      final followedSalons = await supabase
          .from('salon_followers')
          .select('salon_id')
          .eq('customer_id', user.id);

      final followedSalonIds =
          followedSalons.map((f) => f['salon_id'] as int).toList();

      if (followedSalonIds.isEmpty) {
        setState(() => _overflowNotifications = []);
        return;
      }

      final result = await supabase
          .from('overflow_notifications')
          .select('*')
          .eq('customer_id', user.id)
          .inFilter('salon_id', followedSalonIds)
          .eq('status', 'PENDING')
          .order('notified_at', ascending: false);

      final List<Map<String, dynamic>> notifications = [];

      for (var notice in result) {
        // ✅ NEW: use services instead of services!inner
        final apt = await supabase
            .from('appointments')
            .select('''
              *,
              salons!inner(name, address),
              appointment_services (
                id,
                service_id,
                services!inner (name)
              )
            ''')
            .eq('id', notice['appointment_id'])
            .single();

        String barberName = 'Barber';
        if (apt['barber_id'] != null) {
          final barber = await supabase
              .from('profiles')
              .select('full_name')
              .eq('id', apt['barber_id'])
              .maybeSingle();
          if (barber != null) {
            barberName = barber['full_name'] ?? 'Barber';
          }
        }

        final appointmentDate = DateTime.parse(apt['appointment_date']);
        final utcStartTime = apt['start_time'] as String;
        final utcEndTime = apt['end_time'] as String;

        final localStartTime = TimezoneService.utcToLocalTimeForDate(
          utcStartTime,
          appointmentDate,
        );
        final localEndTime = TimezoneService.utcToLocalTimeForDate(
          utcEndTime,
          appointmentDate,
        );

        // ✅ Service names summary
        final apptServices = (apt['appointment_services'] as List?) ?? [];
        final serviceNames = apptServices
            .map((s) => s['services']?['name']?.toString() ?? '')
            .where((n) => n.isNotEmpty)
            .toList();
        final serviceSummary = serviceNames.isEmpty
            ? 'Service'
            : serviceNames.length == 1
                ? serviceNames.first
                : '${serviceNames.first} +${serviceNames.length - 1} more';

        // ✅ Queue number
        final isVip = apt['is_vip'] ?? false;
        String displayQueue = '';
        if (isVip) {
          displayQueue =
              'VIP-${apt['vip_queue_number'] ?? apt['queue_number'] ?? ''}';
        } else {
          displayQueue =
              'Q${apt['regular_queue_number'] ?? apt['queue_number'] ?? ''}';
        }

        notifications.add({
          'id': notice['id'],
          'excess_minutes': notice['excess_minutes'],
          'estimated_end': notice['estimated_end'],
          'salon_close': notice['salon_close'],
          'notified_at': notice['notified_at'],
          'appointment': {
            'id': apt['id'],
            'booking_number': apt['booking_number'],
            'appointment_date': apt['appointment_date'],
            'start_time': localStartTime,
            'end_time': localEndTime,
            'utc_start_time': utcStartTime,
            'utc_end_time': utcEndTime,
            'status': apt['status'],
            'display_queue_number': displayQueue,
            'queue_position': apt['queue_position'],
            'is_vip': isVip,
            'child_name': apt['child_name'],
            'travel_time_minutes': apt['travel_time_minutes'],
            'salon_name': apt['salons']?['name'] ?? 'Salon',
            'salon_address': apt['salons']?['address'],
            'salon_id': apt['salon_id'],
            'service_name': serviceSummary,
            'barber_name': barberName,
          },
        });
      }

      setState(() => _overflowNotifications = notifications);
    } catch (e) {
      debugPrint('❌ Overflow notifications error: $e');
      setState(() => _overflowNotifications = []);
    }
  }

  // =====================================================
  // OVERFLOW RESPONSE HANDLER
  // =====================================================
  Future<void> _respondToOverflow(int notificationId, String response) async {
    setState(() => _isProcessingOverflow = true);

    try {
      final user = supabase.auth.currentUser;
      if (user == null) return;

      final result = await supabase.rpc(
        'handle_overflow_response',
        params: {
          'p_notification_id': notificationId,
          'p_customer_id': user.id,
          'p_response': response,
        },
      );

      if (mounted) {
        if (result['success'] == true) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Row(
                children: [
                  Icon(
                    response == 'MOVE'
                        ? Icons.calendar_today
                        : Icons.check_circle,
                    color: Colors.white,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text(result['message'] ?? 'Success')),
                ],
              ),
              backgroundColor:
                  response == 'MOVE' ? Colors.green : Colors.orange,
              behavior: SnackBarBehavior.floating,
            ),
          );
          await _loadData();
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(result['message'] ?? 'Failed'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isProcessingOverflow = false);
    }
  }

  // =====================================================
  // OVERFLOW DECISION DIALOG
  // =====================================================
  void _showOverflowDecisionDialog(Map<String, dynamic> notification) {
    final isDark = context.isDarkMode;
    final apt = notification['appointment'];
    final excessMinutes = notification['excess_minutes'];
    final estimatedEnd = notification['estimated_end'];
    final salonClose = notification['salon_close'];

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: isDark ? const Color(0xFF1E1E1E) : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Icon(
              Icons.warning_amber_rounded,
              color: Colors.orange.shade700,
              size: 28,
            ),
            const SizedBox(width: 12),
            Text(
              'Appointment Overflow',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: isDark ? Colors.white : Colors.black87,
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isDark
                    ? Colors.orange.withValues(alpha: 0.1)
                    : Colors.orange.shade50,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.orange.withValues(alpha: 0.2)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '⚠️ Delay of $excessMinutes minutes detected',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: isDark
                          ? Colors.orange.shade300
                          : Colors.orange.shade800,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Your appointment on ${apt['appointment_date']} at ${apt['start_time']} may be significantly delayed.',
                    style: TextStyle(
                      color: isDark
                          ? Colors.orange.shade300
                          : Colors.orange.shade700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Estimated end: $estimatedEnd | Salon closes: $salonClose',
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark
                          ? Colors.orange.shade300
                          : Colors.orange.shade600,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'What would you like to do?',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: isDark ? Colors.white : Colors.black87,
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isDark
                    ? Colors.green.withValues(alpha: 0.1)
                    : Colors.green.shade50,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(Icons.calendar_today, color: Colors.green.shade700),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Move to Next Day',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: isDark
                                ? Colors.green.shade300
                                : Colors.green.shade800,
                          ),
                        ),
                        Text(
                          'Reschedule your appointment to tomorrow',
                          style: TextStyle(
                            fontSize: 12,
                            color: isDark
                                ? Colors.green.shade300
                                : Colors.green.shade600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isDark
                    ? Colors.red.withValues(alpha: 0.1)
                    : Colors.red.shade50,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(Icons.cancel, color: Colors.red.shade700),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Cancel Appointment',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: isDark
                                ? Colors.red.shade300
                                : Colors.red.shade800,
                          ),
                        ),
                        Text(
                          'Cancel this appointment (no charges)',
                          style: TextStyle(
                            fontSize: 12,
                            color: isDark
                                ? Colors.red.shade300
                                : Colors.red.shade600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '⚠️ If no response within 30 minutes, your appointment will be auto-cancelled.',
              style: TextStyle(
                fontSize: 12,
                color:
                    isDark ? Colors.orange.shade300 : Colors.orange.shade600,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(
              'DECIDE LATER',
              style: TextStyle(
                color: isDark ? Colors.white60 : Colors.black87,
              ),
            ),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(dialogContext);
              await _showMoveCancelOptions(notification['id']);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orange,
              foregroundColor: Colors.white,
            ),
            child: const Text('PROCEED'),
          ),
        ],
      ),
    );
  }

  Future<void> _showMoveCancelOptions(int notificationId) async {
    final isDark = context.isDarkMode;

    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: isDark ? const Color(0xFF1E1E1E) : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'Choose Action',
          style: TextStyle(
            color: isDark ? Colors.white : Colors.black87,
          ),
        ),
        content: Text(
          'What would you like to do?',
          style: TextStyle(
            color: isDark ? Colors.white70 : Colors.black87,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'CANCEL'),
            child: Text(
              'CANCEL',
              style: TextStyle(
                color: isDark ? Colors.red.shade300 : Colors.red,
              ),
            ),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, 'MOVE'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green,
              foregroundColor: Colors.white,
            ),
            child: const Text('MOVE TO NEXT DAY'),
          ),
        ],
      ),
    );

    if (result != null) {
      await _respondToOverflow(notificationId, result);
    }
  }

  // =====================================================
  // ✅ CANCEL BOOKING (Fixed RPC params)
  // =====================================================
  Future<void> _cancelBooking(Map<String, dynamic> booking) async {
    final isDark = context.isDarkMode;
    final hasOverflow = _overflowNotifications.any(
      (n) => n['appointment']['id'] == booking['id'],
    );

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: isDark ? const Color(0xFF1E1E1E) : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Icon(
              Icons.warning_amber_rounded,
              color: Colors.red.shade700,
              size: 28,
            ),
            const SizedBox(width: 12),
            Text(
              'Cancel Booking?',
              style: TextStyle(
                color: isDark ? Colors.white : Colors.black87,
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Are you sure you want to cancel this booking?',
              style: TextStyle(
                fontSize: 16,
                color: isDark ? Colors.white70 : Colors.grey[800],
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF2A2A2A) : Colors.grey[100],
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.store, size: 16, color: AppTheme.primary),
                      const SizedBox(width: 8),
                      Text(
                        booking['salon_name'],
                        style: TextStyle(
                          fontWeight: FontWeight.w500,
                          color: isDark ? Colors.white : Colors.black87,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(
                        Icons.calendar_today,
                        size: 16,
                        color: AppTheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        DateFormat(
                          'EEEE, MMM dd, yyyy',
                        ).format(DateTime.parse(booking['appointment_date'])),
                        style: TextStyle(
                          color: isDark ? Colors.white : Colors.black87,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(
                        Icons.access_time,
                        size: 16,
                        color: AppTheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${booking['local_start_time']} - ${booking['local_end_time']}',
                        style: TextStyle(
                          color: isDark ? Colors.white : Colors.black87,
                        ),
                      ),
                    ],
                  ),
                  if (booking['display_queue_number'] != null &&
                      booking['display_queue_number'].isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Row(
                        children: [
                          Icon(
                            Icons.format_list_numbered,
                            size: 16,
                            color: booking['is_vip']
                                ? _vipColor
                                : _regularColor,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Queue: ${booking['display_queue_number']}',
                            style: TextStyle(
                              fontWeight: FontWeight.w500,
                              color: booking['is_vip']
                                  ? _vipColor
                                  : _regularColor,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            if (hasOverflow)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  '⚠️ Cancelling now will resolve overflow.',
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark
                        ? Colors.orange.shade300
                        : Colors.orange.shade700,
                  ),
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(
              'KEEP BOOKING',
              style: TextStyle(
                color: isDark ? Colors.white60 : Colors.black87,
              ),
            ),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: const Text('YES, CANCEL'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _isCancelling = true);

    try {
      final user = supabase.auth.currentUser;
      if (user == null) return;

      // ✅ FIXED: use p_cancelled_by and p_role instead of p_customer_id
      final result = await supabase.rpc(
        'cancel_booking_and_reorder',
        params: {
          'p_appointment_id': booking['id'],
          'p_cancelled_by': user.id,
          'p_cancel_reason': 'Cancelled by customer',
          'p_role': 'customer',
        },
      );

      if (!mounted) return;

      if (result['success'] == true) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Row(
              children: [
                Icon(Icons.check_circle, color: Colors.white, size: 20),
                SizedBox(width: 8),
                Text('Booking cancelled successfully'),
              ],
            ),
            backgroundColor: _regularColor,
            behavior: SnackBarBehavior.floating,
          ),
        );
        await _loadData();
      } else {
        throw Exception(result['message'] ?? 'Cancellation failed');
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to cancel: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _isCancelling = false);
    }
  }

  List<Map<String, dynamic>> get _upcomingBookings =>
      _bookings.where((b) => b['status_category'] == 'upcoming').toList();
  List<Map<String, dynamic>> get _completedBookings =>
      _bookings.where((b) => b['status_category'] == 'completed').toList();
  List<Map<String, dynamic>> get _cancelledBookings =>
      _bookings.where((b) => b['status_category'] == 'cancelled').toList();

  // =====================================================
  // LEAVE REVIEW DIALOG (unchanged)
  // =====================================================
  void _showLeaveReviewDialog(Map<String, dynamic> booking) {
    final isDark = context.isDarkMode;
    int selectedRating = 0;
    String reviewText = '';
    final TextEditingController reviewController = TextEditingController();

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) {
          return AlertDialog(
            backgroundColor: isDark ? const Color(0xFF1E1E1E) : Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
            ),
            title: Row(
              children: [
                Icon(Icons.star_rate_rounded, color: Colors.amber, size: 28),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Leave a Review',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: isDark ? Colors.white : Colors.black87,
                    ),
                  ),
                ),
              ],
            ),
            content: SizedBox(
              width: MediaQuery.of(context).size.width * 0.85,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: isDark
                            ? const Color(0xFF2A2A2A)
                            : Colors.grey[50],
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            booking['salon_name'],
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: isDark ? Colors.white : Colors.black87,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Barber: ${booking['barber_name']}',
                            style: TextStyle(
                              fontSize: 13,
                              color: isDark
                                  ? Colors.white60
                                  : Colors.grey[600],
                            ),
                          ),
                          Text(
                            'Service: ${booking['service_name']}',
                            style: TextStyle(
                              fontSize: 13,
                              color: isDark
                                  ? Colors.white60
                                  : Colors.grey[600],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      'Your Rating',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: isDark ? Colors.white : Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: List.generate(5, (index) {
                        final isSelected = index < selectedRating;
                        return IconButton(
                          onPressed: () =>
                              setState(() => selectedRating = index + 1),
                          icon: Icon(
                            isSelected ? Icons.star : Icons.star_border,
                            color: isSelected
                                ? Colors.amber
                                : (isDark
                                    ? Colors.grey[600]
                                    : Colors.grey[400]),
                            size: 36,
                          ),
                        );
                      }),
                    ),
                    const SizedBox(height: 8),
                    Center(
                      child: Text(
                        selectedRating == 0
                            ? 'Tap to rate'
                            : 'You rated: $selectedRating/5',
                        style: TextStyle(
                          fontSize: 13,
                          color: selectedRating == 0
                              ? (isDark
                                  ? Colors.white70
                                  : Colors.grey[500])
                              : Colors.amber[700],
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      'Your Review (Optional)',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: isDark ? Colors.white : Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: reviewController,
                      maxLines: 4,
                      maxLength: 500,
                      style: TextStyle(
                        color: isDark ? Colors.white : Colors.black87,
                      ),
                      decoration: InputDecoration(
                        hintText: 'Share your experience...',
                        hintStyle: TextStyle(
                          color:
                              isDark ? Colors.white70 : Colors.grey[400],
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide:
                              BorderSide(color: AppTheme.primary, width: 2),
                        ),
                        filled: true,
                        fillColor: isDark
                            ? const Color(0xFF2A2A2A)
                            : Colors.grey[50],
                      ),
                      onChanged: (value) => reviewText = value,
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(
                  'CANCEL',
                  style: TextStyle(
                    color: isDark ? Colors.white60 : Colors.black87,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              ElevatedButton(
                onPressed: selectedRating == 0
                    ? null
                    : () async {
                        if (selectedRating > 0) {
                          await _submitReview(
                            bookingId: booking['id'],
                            rating: selectedRating,
                            review: reviewText,
                          );
                          if (context.mounted) Navigator.pop(context);
                        }
                      },
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primary,
                  foregroundColor: Colors.white,
                ),
                child: const Text('SUBMIT REVIEW'),
              ),
            ],
            actionsPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          );
        },
      ),
    );
  }

  void _rebookBooking(Map<String, dynamic> booking) {
    // ✅ Build salon data from booking
    final salonData = {
      'id': booking['salon_id'],
      'name': booking['salon_name'],
    };

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => BookingFlowScreen(initialSalon: salonData),
      ),
    );
  }

  Future<void> _submitReview({
    required int bookingId,
    required int rating,
    required String review,
  }) async {
    try {
      final user = supabase.auth.currentUser;
      if (user == null) return;

      final roleResponse = await supabase
          .from('roles')
          .select('id')
          .eq('name', 'customer')
          .single();

      final customerRoleId = roleResponse['id'];

      final roleCheck = await supabase
          .from('user_roles')
          .select('status')
          .eq('user_id', user.id)
          .eq('role_id', customerRoleId)
          .maybeSingle();

      if (roleCheck == null || roleCheck['status'] != 'active') {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Your account is not active'),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }

      final appointment = await supabase
          .from('appointments')
          .select('barber_id, salon_id')
          .eq('id', bookingId)
          .single();

      final existingReview = await supabase
          .from('reviews')
          .select('id')
          .eq('appointment_id', bookingId)
          .maybeSingle();

      if (!mounted) return;

      if (existingReview != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('You already reviewed this appointment'),
            backgroundColor: Colors.orange,
          ),
        );
        return;
      }

      await supabase.from('reviews').insert({
        'appointment_id': bookingId,
        'customer_id': user.id,
        'barber_id': appointment['barber_id'],
        'salon_id': appointment['salon_id'],
        'overall_rating': rating,
        'comment': review,
        'created_at': DateTime.now().toIso8601String(),
      });

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Row(
            children: [
              Icon(Icons.check_circle, color: Colors.white, size: 20),
              SizedBox(width: 8),
              Text('Thank you for your review!'),
            ],
          ),
          backgroundColor: Colors.green,
        ),
      );

      await _loadData();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to submit review: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  // =====================================================
  // ✅ BOOKING DETAILS BOTTOM SHEET (Multi-service + breakdown)
  // =====================================================
  void _showBookingDetails(Map<String, dynamic> booking) {
    final isDark = context.isDarkMode;
    final isVip = booking['is_vip'] ?? false;
    final detailColor = isVip ? _vipColor : AppTheme.primary;
    final currencyCode = (booking['currency_code'] as String?) ?? 'LKR';
    final symbol = _getCurrencySymbol(currencyCode);
    final services = (booking['services'] as List?) ?? [];
    final servicesSubtotal =
        (booking['services_subtotal'] as num?)?.toDouble() ?? 0;
    final totalDiscount =
        (booking['total_discount'] as num?)?.toDouble() ?? 0;
    final extraCharge = (booking['extra_charge'] as num?)?.toDouble() ?? 0;
    final extraNote = booking['extra_charge_note'] as String?;
    final totalPrice = (booking['price'] as num?)?.toDouble() ?? 0;

    showModalBottomSheet(
      context: context,
      backgroundColor: isDark ? const Color(0xFF1E1E1E) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      isScrollControlled: true,
      builder: (context) => SingleChildScrollView(
        child: Container(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Handle
              Center(
                child: Container(
                  width: 50,
                  height: 4,
                  decoration: BoxDecoration(
                    color: isDark ? Colors.grey[700] : Colors.grey[300],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 20),

              // Header
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: detailColor.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      Icons.receipt_long,
                      color: detailColor,
                      size: 28,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Booking ${booking['booking_number']}',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: isDark ? Colors.white : Colors.black87,
                          ),
                        ),
                        Text(
                          DateFormat('MMM dd, yyyy • hh:mm a').format(
                            DateTime.parse(booking['appointment_date']),
                          ),
                          style: TextStyle(
                            fontSize: 12,
                            color:
                                isDark ? Colors.white60 : Colors.grey[600],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),

              // Basic info
              _buildDetailRow('Salon', booking['salon_name']),
              _buildDetailRow('Address', booking['salon_address'] ?? 'N/A'),
              _buildDetailRow('Barber', booking['barber_name']),
              if (booking['child_name'] != null &&
                  booking['child_name'].toString().isNotEmpty)
                _buildDetailRow('Booked For', booking['child_name']),
              if (booking['display_queue_number'] != null &&
                  booking['display_queue_number'].isNotEmpty)
                _buildDetailRow(
                    'Queue Number', booking['display_queue_number']),
              if (booking['queue_position'] != null)
                _buildDetailRow(
                    'Queue Position', '#${booking['queue_position']}'),
              if (booking['is_vip'] == true)
                _buildDetailRow('Booking Type', 'VIP'),

              const Divider(height: 24),

              // ✅ Services breakdown
              if (services.isNotEmpty) ...[
                Text(
                  'Services (${services.length})',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.white : Colors.black87,
                  ),
                ),
                const SizedBox(height: 12),
                ...services.map((s) {
                  final price = (s['price'] as num?)?.toDouble() ?? 0;
                  final discount =
                      (s['discount_amount'] as num?)?.toDouble() ?? 0;
                  final finalPrice =
                      (s['final_price'] as num?)?.toDouble() ?? 0;
                  final duration = (s['duration'] as num?)?.toInt() ?? 30;
                  final offerTitle = s['offer_title'] as String?;
                  final gender = s['gender'] as String?;
                  final age = s['age'] as String?;

                  final details = [
                    if (gender != null && gender.isNotEmpty) gender,
                    if (age != null && age.isNotEmpty) age,
                    '$duration min',
                  ].join(' • ');

                  return Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: isDark
                          ? const Color(0xFF2A2A2A)
                          : Colors.grey[50],
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: isDark
                            ? Colors.grey[800]!
                            : Colors.grey[200]!,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                s['service_name'] ?? 'Service',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: isDark
                                      ? Colors.white
                                      : Colors.black87,
                                ),
                              ),
                            ),
                            if (discount > 0)
                              Text(
                                '$symbol${price.toStringAsFixed(2)}',
                                style: TextStyle(
                                  fontSize: 11,
                                  decoration:
                                      TextDecoration.lineThrough,
                                  color: isDark
                                      ? Colors.white60
                                      : Colors.grey,
                                ),
                              ),
                            if (discount > 0) const SizedBox(width: 4),
                            Text(
                              '$symbol${(discount > 0 ? finalPrice : price).toStringAsFixed(2)}',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: discount > 0
                                    ? Colors.green.shade700
                                    : (isDark
                                        ? Colors.white70
                                        : Colors.black87),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          details,
                          style: TextStyle(
                            fontSize: 11,
                            color: isDark
                                ? Colors.white60
                                : Colors.grey[600],
                          ),
                        ),
                        if (discount > 0 && offerTitle != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.local_offer,
                                  size: 11,
                                  color: Colors.green.shade700,
                                ),
                                const SizedBox(width: 4),
                                Expanded(
                                  child: Text(
                                    '$offerTitle — save $symbol${discount.toStringAsFixed(2)}',
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: Colors.green.shade700,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  );
                }),
                const SizedBox(height: 12),
                const Divider(),
              ],

              // ✅ Price breakdown
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Services Subtotal',
                    style: TextStyle(
                      fontSize: 13,
                      color: isDark ? Colors.white70 : Colors.grey[700],
                    ),
                  ),
                  Text(
                    '$symbol${servicesSubtotal.toStringAsFixed(2)}',
                    style: TextStyle(
                      fontSize: 13,
                      color: isDark ? Colors.white70 : Colors.grey[700],
                    ),
                  ),
                ],
              ),
              if (totalDiscount > 0) ...[
                const SizedBox(height: 4),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.local_offer,
                          size: 13,
                          color: Colors.green.shade700,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          'Total Discount',
                          style: TextStyle(
                            fontSize: 13,
                            color: Colors.green.shade700,
                          ),
                        ),
                      ],
                    ),
                    Text(
                      '− $symbol${totalDiscount.toStringAsFixed(2)}',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Colors.green.shade700,
                      ),
                    ),
                  ],
                ),
              ],
              if (extraCharge > 0) ...[
                const SizedBox(height: 4),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.add_circle,
                          size: 13,
                          color: Colors.orange,
                        ),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            extraNote != null && extraNote.isNotEmpty
                                ? 'Extra ($extraNote)'
                                : 'Extra Charge',
                            style: TextStyle(
                              fontSize: 13,
                              color: Colors.orange,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    Text(
                      '+ $symbol${extraCharge.toStringAsFixed(2)}',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Colors.orange,
                      ),
                    ),
                  ],
                ),
              ],
              const Divider(height: 20),

              // ✅ Total
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: detailColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Total',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: isDark ? Colors.white : Colors.black87,
                      ),
                    ),
                    Text(
                      '$symbol${totalPrice.toStringAsFixed(2)}',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: detailColor,
                      ),
                    ),
                  ],
                ),
              ),

              if (booking['travel_time_minutes'] != null &&
                  booking['travel_time_minutes'] > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: _buildDetailRow(
                    'Travel Time',
                    '${booking['travel_time_minutes']} minutes',
                  ),
                ),

              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(context),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: detailColor,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: const Text(
                    'CLOSE',
                    style: TextStyle(color: Colors.white),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDetailRow(String label, String value) {
    final isDark = context.isDarkMode;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 14,
                color: isDark ? Colors.white60 : Colors.grey[600],
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: isDark ? Colors.white : Colors.black87,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // =====================================================
  // UI BUILDERS
  // =====================================================

  Widget _buildCancelButton(Map<String, dynamic> booking) {
    return OutlinedButton(
      onPressed: _isCancelling ? null : () => _cancelBooking(booking),
      style: OutlinedButton.styleFrom(
        side: const BorderSide(color: Colors.red, width: 1.5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        padding: const EdgeInsets.symmetric(vertical: 12),
      ),
      child: _isCancelling
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(Colors.red),
              ),
            )
          : const Text(
              'CANCEL',
              style: TextStyle(
                color: Colors.red,
                fontWeight: FontWeight.w600,
                fontSize: 14,
              ),
            ),
    );
  }

  Widget _buildReviewButton(Map<String, dynamic> booking) {
    return OutlinedButton(
      onPressed: () => _showLeaveReviewDialog(booking),
      style: OutlinedButton.styleFrom(
        side: const BorderSide(color: Colors.amber, width: 1.5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        padding: const EdgeInsets.symmetric(vertical: 12),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: const [
          Icon(Icons.star_outline, color: Colors.amber, size: 18),
          SizedBox(width: 8),
          Text(
            'REVIEW',
            style: TextStyle(
              color: Colors.amber,
              fontWeight: FontWeight.w600,
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRebookButton(Map<String, dynamic> booking) {
    final isVip = booking['is_vip'] ?? false;
    final buttonColor = isVip ? _vipColor : AppTheme.primary;

    return OutlinedButton(
      onPressed: () => _rebookBooking(booking),
      style: OutlinedButton.styleFrom(
        side: BorderSide(color: buttonColor, width: 1.5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        padding: const EdgeInsets.symmetric(vertical: 12),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.refresh, color: buttonColor, size: 18),
          const SizedBox(width: 8),
          Text(
            'BOOK AGAIN',
            style: TextStyle(
              color: buttonColor,
              fontWeight: FontWeight.w600,
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOverflowCard(Map<String, dynamic> notification) {
    final isDark = context.isDarkMode;
    final apt = notification['appointment'];
    final excessMinutes = notification['excess_minutes'];
    final estimatedEnd = notification['estimated_end'];
    final salonClose = notification['salon_close'];

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      elevation: 2,
      color: isDark ? const Color(0xFF2A2A2A) : Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: isDark
              ? Colors.orange.withValues(alpha: 0.1)
              : Colors.orange.shade50,
          border: Border.all(
            color: isDark
                ? Colors.orange.withValues(alpha: 0.3)
                : Colors.orange.shade300,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: isDark
                    ? Colors.orange.withValues(alpha: 0.15)
                    : Colors.orange.shade100,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(16),
                  topRight: Radius.circular(16),
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 45,
                    height: 45,
                    decoration: BoxDecoration(
                      color: isDark
                          ? Colors.orange.withValues(alpha: 0.2)
                          : Colors.orange.shade200,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.warning_amber,
                      color: Colors.orange,
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '⚠️ ACTION REQUIRED',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: isDark
                                ? Colors.orange.shade300
                                : Colors.orange,
                          ),
                        ),
                        Text(
                          apt['salon_name'],
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: isDark ? Colors.white : Colors.black87,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: isDark
                          ? Colors.red.withValues(alpha: 0.2)
                          : Colors.red.shade100,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      '$excessMinutes min overflow',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: isDark
                            ? Colors.red.shade300
                            : Colors.red.shade700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.calendar_today,
                        size: 16,
                        color: isDark ? Colors.white60 : Colors.grey[600],
                      ),
                      const SizedBox(width: 8),
                      Text(
                        apt['appointment_date'],
                        style: TextStyle(
                          fontSize: 14,
                          color:
                              isDark ? Colors.white70 : Colors.grey[700],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(
                        Icons.access_time,
                        size: 16,
                        color: isDark ? Colors.white60 : Colors.grey[600],
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${apt['start_time']} - ${apt['end_time']}',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: isDark ? Colors.white : Colors.black87,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '⚠️ Schedule Overflow Detected',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: isDark
                                ? Colors.orange.shade300
                                : Colors.orange.shade800,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Your appointment may be delayed by approximately $excessMinutes minutes.',
                          style: TextStyle(
                            color: isDark
                                ? Colors.white70
                                : Colors.grey.shade700,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Estimated end: $estimatedEnd | Salon closes: $salonClose',
                          style: TextStyle(
                            fontSize: 12,
                            color: isDark
                                ? Colors.white60
                                : Colors.grey.shade600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    onPressed: _isProcessingOverflow
                        ? null
                        : () => _showOverflowDecisionDialog(notification),
                    icon: _isProcessingOverflow
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child:
                                CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.check_circle, size: 18),
                    label: const Text('RESPOND NOW'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.orange,
                      side: const BorderSide(color: Colors.orange),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '⚠️ If no response within 30 minutes, this appointment will be auto-cancelled.',
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark
                          ? Colors.orange.shade300
                          : Colors.orange.shade600,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // =====================================================
  // ✅ BOOKING CARD (Multi-service + breakdown)
  // =====================================================
  Widget _buildBookingCard(Map<String, dynamic> booking, bool isUpcoming) {
    final isDark = context.isDarkMode;
    final appointmentDateRaw = DateTime.parse(booking['appointment_date']);
    final appointmentDate = DateTime(
      appointmentDateRaw.year,
      appointmentDateRaw.month,
      appointmentDateRaw.day,
    );

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    final isPastDate = appointmentDate.isBefore(today);
    final isSameDay = appointmentDate.isAtSameMomentAs(today);

    bool isTimePassed = false;
    if (isSameDay) {
      final endTimeStr = booking['local_end_time'];
      try {
        final endParts = endTimeStr.split(':');
        final endHour = int.parse(endParts[0]);
        final endMinute = int.parse(endParts[1]);
        final endDateTime = DateTime(
          today.year,
          today.month,
          today.day,
          endHour,
          endMinute,
        );
        isTimePassed = endDateTime.isBefore(now);
      } catch (e) {
        isTimePassed = false;
      }
    }

    final canCancel = isUpcoming &&
        !isPastDate &&
        !isTimePassed &&
        booking['status'] != 'cancelled';
    final status = booking['status'];
    final isVip = booking['is_vip'] ?? false;
    final queueColor = isVip ? _vipColor : _regularColor;

    final symbol = _getCurrencySymbol(booking['currency_code'] as String?);
    final services = (booking['services'] as List?) ?? [];
    final totalDiscount =
        (booking['total_discount'] as num?)?.toDouble() ?? 0;
    final extraCharge = (booking['extra_charge'] as num?)?.toDouble() ?? 0;
    final extraNote = booking['extra_charge_note'] as String?;
    final totalPrice = (booking['price'] as num?)?.toDouble() ?? 0;

    Color statusColor;
    String statusText;
    switch (status) {
      case 'confirmed':
        statusColor = Colors.green;
        statusText = 'Confirmed';
        break;
      case 'pending':
        statusColor = Colors.orange;
        statusText = 'Pending';
        break;
      case 'in_progress':
        statusColor = Colors.blue;
        statusText = 'In Progress';
        break;
      case 'completed':
        statusColor = Colors.purple;
        statusText = 'Completed';
        break;
      case 'cancelled':
        statusColor = Colors.red;
        statusText = 'Cancelled';
        break;
      default:
        statusColor = Colors.grey;
        statusText = status;
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      elevation: 2,
      color: isDark ? const Color(0xFF2A2A2A) : Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: isDark ? const Color(0xFF2A2A2A) : Colors.white,
          border: isVip
              ? Border.all(color: _vipColor.withValues(alpha: 0.3), width: 1)
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: isVip
                    ? _vipColor.withValues(alpha: 0.05)
                    : AppTheme.primary.withValues(alpha: 0.05),
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(16),
                  topRight: Radius.circular(16),
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 45,
                    height: 45,
                    decoration: BoxDecoration(
                      color: isVip
                          ? _vipColor.withValues(alpha: 0.1)
                          : AppTheme.primary.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: isVip
                        ? Icon(Icons.star, color: _vipColor, size: 24)
                        : Icon(Icons.store, color: AppTheme.primary, size: 24),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                booking['salon_name'],
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: isDark
                                      ? Colors.white
                                      : Colors.black87,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (isVip)
                              Container(
                                margin: const EdgeInsets.only(left: 8),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: _vipColor,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: const Text(
                                  'VIP',
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        if (booking['salon_address'] != null)
                          Text(
                            booking['salon_address'],
                            style: TextStyle(
                              fontSize: 12,
                              color: isDark
                                  ? Colors.white60
                                  : Colors.grey[600],
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: statusColor.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: statusColor.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Text(
                      statusText,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: statusColor,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // Body
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.calendar_today,
                        size: 16,
                        color: isDark ? Colors.white60 : Colors.grey[600],
                      ),
                      const SizedBox(width: 8),
                      Text(
                        DateFormat(
                          'EEEE, MMM dd, yyyy',
                        ).format(appointmentDateRaw),
                        style: TextStyle(
                          fontSize: 14,
                          color:
                              isDark ? Colors.white70 : Colors.grey[700],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(
                        Icons.access_time,
                        size: 16,
                        color: isDark ? Colors.white60 : Colors.grey[600],
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${booking['local_start_time']} - ${booking['local_end_time']}',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: isDark ? Colors.white : Colors.black87,
                        ),
                      ),
                    ],
                  ),
                  if (booking['display_queue_number'] != null &&
                      booking['display_queue_number'].isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Row(
                        children: [
                          Icon(
                            Icons.format_list_numbered,
                            size: 16,
                            color: queueColor,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Queue: ${booking['display_queue_number']}',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: queueColor,
                            ),
                          ),
                          if (booking['queue_position'] != null)
                            Text(
                              ' (Position ${booking['queue_position']})',
                              style: TextStyle(
                                fontSize: 12,
                                color: isDark
                                    ? Colors.white60
                                    : Colors.grey[600],
                              ),
                            ),
                        ],
                      ),
                    ),
                  const Divider(height: 24),

                  // ✅ Services list (multi-service)
                  if (services.isNotEmpty) ...[
                    Row(
                      children: [
                        Icon(
                          Icons.content_cut,
                          size: 14,
                          color: isDark ? Colors.white60 : Colors.grey[600],
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Services (${services.length})',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color:
                                isDark ? Colors.white70 : Colors.grey[700],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    ...services.take(3).map((s) {
                      final price =
                          (s['final_price'] as num?)?.toDouble() ?? 0;
                      final discount =
                          (s['discount_amount'] as num?)?.toDouble() ?? 0;
                      final hasDiscount = discount > 0;
                      return Padding(
                        padding: const EdgeInsets.only(left: 22, top: 2),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                '• ${s['service_name']}',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: isDark
                                      ? Colors.white
                                      : Colors.black87,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (hasDiscount)
                              Icon(
                                Icons.local_offer,
                                size: 11,
                                color: Colors.green.shade700,
                              ),
                            const SizedBox(width: 4),
                            Text(
                              '$symbol${price.toStringAsFixed(2)}',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: hasDiscount
                                    ? Colors.green.shade700
                                    : (isDark
                                        ? Colors.white
                                        : Colors.black87),
                              ),
                            ),
                          ],
                        ),
                      );
                    }),
                    if (services.length > 3)
                      Padding(
                        padding:
                            const EdgeInsets.only(left: 22, top: 4),
                        child: Text(
                          '+${services.length - 3} more service${services.length - 3 > 1 ? 's' : ''}',
                          style: TextStyle(
                            fontSize: 11,
                            fontStyle: FontStyle.italic,
                            color: isDark
                                ? Colors.white60
                                : Colors.grey[600],
                          ),
                        ),
                      ),
                    const SizedBox(height: 8),
                  ] else
                    Row(
                      children: [
                        Icon(
                          Icons.content_cut,
                          size: 16,
                          color: isDark ? Colors.white60 : Colors.grey[600],
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'No services',
                            style: TextStyle(
                              fontSize: 14,
                              color: isDark
                                  ? Colors.white60
                                  : Colors.grey[600],
                            ),
                          ),
                        ),
                      ],
                    ),

                  // Barber
                  Row(
                    children: [
                      Icon(
                        Icons.person,
                        size: 16,
                        color: isDark ? Colors.white60 : Colors.grey[600],
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          booking['barber_name'],
                          style: TextStyle(
                            fontSize: 14,
                            color: isDark ? Colors.white : Colors.black87,
                          ),
                        ),
                      ),
                    ],
                  ),

                  if (booking['child_name'] != null &&
                      booking['child_name'].toString().isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Row(
                        children: [
                          Icon(
                            Icons.badge,
                            size: 16,
                            color:
                                isDark ? Colors.white60 : Colors.grey[600],
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Booking for: ${booking['child_name']}',
                            style: TextStyle(
                              fontSize: 14,
                              color: isDark ? Colors.white : Colors.black87,
                            ),
                          ),
                        ],
                      ),
                    ),

                  // ✅ Extra charge line
                  if (extraCharge > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Row(
                        children: [
                          Icon(
                            Icons.add_circle,
                            size: 14,
                            color: Colors.orange,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              extraNote != null && extraNote.isNotEmpty
                                  ? 'Extra ($extraNote)'
                                  : 'Extra Charge',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.orange,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Text(
                            '+ $symbol${extraCharge.toStringAsFixed(2)}',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Colors.orange,
                            ),
                          ),
                        ],
                      ),
                    ),

                  // ✅ Total discount line
                  if (totalDiscount > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Row(
                        children: [
                          Icon(
                            Icons.local_offer,
                            size: 14,
                            color: Colors.green.shade700,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              'Discount',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.green.shade700,
                              ),
                            ),
                          ),
                          Text(
                            '− $symbol${totalDiscount.toStringAsFixed(2)}',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Colors.green.shade700,
                            ),
                          ),
                        ],
                      ),
                    ),

                  const Divider(height: 24),

                  // ✅ Total row
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.timer, size: 16, color: queueColor),
                          const SizedBox(width: 4),
                          Text(
                            '${booking['duration']} min',
                            style: TextStyle(
                              fontSize: 14,
                              color:
                                  isDark ? Colors.white70 : Colors.grey[700],
                            ),
                          ),
                        ],
                      ),
                      Text(
                        '$symbol${totalPrice.toStringAsFixed(2)}',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: isDark ? Colors.white : queueColor,
                        ),
                      ),
                    ],
                  ),

                  if (booking['travel_time_minutes'] != null &&
                      booking['travel_time_minutes'] > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Row(
                        children: [
                          Icon(
                            Icons.directions_car,
                            size: 14,
                            color:
                                isDark ? Colors.white70 : Colors.grey[500],
                          ),
                          const SizedBox(width: 4),
                          Text(
                            'Travel time: ${booking['travel_time_minutes']} min',
                            style: TextStyle(
                              fontSize: 12,
                              color: isDark
                                  ? Colors.white70
                                  : Colors.grey[500],
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),

            // Buttons
            if (isUpcoming && canCancel)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF1E1E1E) : Colors.grey[50],
                  borderRadius: const BorderRadius.only(
                    bottomLeft: Radius.circular(16),
                    bottomRight: Radius.circular(16),
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(child: _buildCancelButton(booking)),
                    const SizedBox(width: 12),
                    Container(
                      decoration: BoxDecoration(
                        color: isDark
                            ? const Color(0xFF2A2A2A)
                            : Colors.grey[100],
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: isDark
                              ? Colors.grey[700]!
                              : Colors.grey[300]!,
                        ),
                      ),
                      child: IconButton(
                        onPressed: () => _showBookingDetails(booking),
                        icon: Icon(
                          Icons.info_outline,
                          color: isVip ? _vipColor : AppTheme.primary,
                          size: 22,
                        ),
                        tooltip: 'View Details',
                      ),
                    ),
                  ],
                ),
              ),

            if (!isUpcoming && status == 'completed')
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF1E1E1E) : Colors.grey[50],
                  borderRadius: const BorderRadius.only(
                    bottomLeft: Radius.circular(16),
                    bottomRight: Radius.circular(16),
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(child: _buildReviewButton(booking)),
                    const SizedBox(width: 12),
                    Expanded(child: _buildRebookButton(booking)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildBookingList(
    List<Map<String, dynamic>> bookings, {
    required bool isUpcoming,
  }) {
    final isDark = context.isDarkMode;
    final totalItems =
        bookings.length + (isUpcoming ? _overflowNotifications.length : 0);

    if (totalItems == 0) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              isUpcoming ? Icons.event_available : Icons.history,
              size: 64,
              color: isDark ? Colors.white30 : Colors.grey[300],
            ),
            const SizedBox(height: 16),
            Text(
              isUpcoming ? 'No upcoming bookings' : 'No bookings found',
              style: TextStyle(
                color: isDark ? Colors.white60 : Colors.grey[500],
                fontSize: 16,
              ),
            ),
            if (isUpcoming) ...[
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () => Navigator.pop(context),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primary,
                  foregroundColor: Colors.white,
                ),
                child: const Text(
                  'BOOK NOW',
                  style: TextStyle(color: Colors.white),
                ),
              ),
            ],
          ],
        ),
      );
    }

    return ListView.builder(
      shrinkWrap: true,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(16),
      itemCount: totalItems,
      itemBuilder: (context, index) {
        if (isUpcoming && index < _overflowNotifications.length) {
          return _buildOverflowCard(_overflowNotifications[index]);
        }
        final bookingIndex =
            isUpcoming ? index - _overflowNotifications.length : index;
        if (bookingIndex < 0 || bookingIndex >= bookings.length) {
          return const SizedBox.shrink();
        }
        return _buildBookingCard(bookings[bookingIndex], isUpcoming);
      },
    );
  }

  Widget _buildEmptyState() {
    final isDark = context.isDarkMode;

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.event_busy,
            size: 80,
            color: isDark ? Colors.white30 : Colors.grey[300],
          ),
          const SizedBox(height: 16),
          Text(
            'No bookings found',
            style: TextStyle(
              fontSize: 20,
              color: isDark ? Colors.white60 : Colors.grey[600],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Start booking appointments at your favorite salons',
            style: TextStyle(
              fontSize: 14,
              color: isDark ? Colors.white70 : Colors.grey[500],
            ),
          ),
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: () => Navigator.pop(context),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primary,
              foregroundColor: Colors.white,
              padding:
                  const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: const Text(
              'BOOK NOW',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWebLayout() {
    final isDark = context.isDarkMode;
    final totalUpcoming =
        _upcomingBookings.length + _overflowNotifications.length;
    final totalCompleted = _completedBookings.length;
    final totalCancelled = _cancelledBookings.length;

    if (totalUpcoming == 0 && totalCompleted == 0 && totalCancelled == 0) {
      return Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 600),
          child: _buildEmptyState(),
        ),
      );
    }

    return Container(
      color: isDark ? const Color(0xFF121212) : const Color(0xFFF8F9FA),
      child: Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 1200),
          child: Column(
            children: [
              Container(
                color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TabBar(
                  controller: _tabController,
                  indicatorColor: AppTheme.primary,
                  labelColor: isDark ? Colors.white : Colors.black87,
                  unselectedLabelColor:
                      isDark ? Colors.white60 : Colors.grey[600],
                  tabs: [
                    Tab(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.calendar_today, size: 16),
                          const SizedBox(width: 8),
                          Text(
                              'Upcoming (${_upcomingBookings.length + _overflowNotifications.length})'),
                        ],
                      ),
                    ),
                    Tab(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.check_circle, size: 16),
                          const SizedBox(width: 8),
                          Text('Completed (${_completedBookings.length})'),
                        ],
                      ),
                    ),
                    Tab(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.cancel, size: 16),
                          const SizedBox(width: 8),
                          Text('Cancelled (${_cancelledBookings.length})'),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Scrollbar(
                  controller: _scrollController,
                  thumbVisibility: true,
                  trackVisibility: true,
                  thickness: 8.0,
                  radius: const Radius.circular(10),
                  scrollbarOrientation: ScrollbarOrientation.right,
                  child: SingleChildScrollView(
                    controller: _scrollController,
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(16),
                    child: SizedBox(
                      height: MediaQuery.of(context).size.height - 250,
                      child: TabBarView(
                        controller: _tabController,
                        children: [
                          _buildBookingList(_upcomingBookings,
                              isUpcoming: true),
                          _buildBookingList(_completedBookings,
                              isUpcoming: false),
                          _buildBookingList(_cancelledBookings,
                              isUpcoming: false),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMobileLayout() {
    final totalUpcoming =
        _upcomingBookings.length + _overflowNotifications.length;
    final totalCompleted = _completedBookings.length;
    final totalCancelled = _cancelledBookings.length;

    if (totalUpcoming == 0 && totalCompleted == 0 && totalCancelled == 0) {
      return _buildEmptyState();
    }

    return TabBarView(
      controller: _tabController,
      children: [
        _buildBookingList(_upcomingBookings, isUpcoming: true),
        _buildBookingList(_completedBookings, isUpcoming: false),
        _buildBookingList(_cancelledBookings, isUpcoming: false),
      ],
    );
  }

  // =====================================================
  // MAIN BUILD
  // =====================================================
  @override
  Widget build(BuildContext context) {
    final isDark = context.isDarkMode;
    final screenWidth = MediaQuery.of(context).size.width;
    final isWeb = screenWidth > 800;

    final totalUpcoming =
        _upcomingBookings.length + _overflowNotifications.length;
    final totalCompleted = _completedBookings.length;
    final totalCancelled = _cancelledBookings.length;
    final hasAnyBookings =
        totalUpcoming > 0 || totalCompleted > 0 || totalCancelled > 0;

    return Scaffold(
      backgroundColor:
          isDark ? const Color(0xFF121212) : const Color(0xFFF8F9FA),
      appBar: AppBar(
        title: Text(
          'My Bookings',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w600,
            color: Colors.white,
          ),
        ),
        backgroundColor: AppTheme.primary,
        elevation: 0,
        centerTitle: isWeb,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        bottom: hasAnyBookings
            ? TabBar(
                controller: _tabController,
                indicatorColor: Colors.white,
                labelColor: Colors.white,
                unselectedLabelColor: Colors.white70,
                tabs: const [
                  Tab(text: 'UPCOMING'),
                  Tab(text: 'COMPLETED'),
                  Tab(text: 'CANCELLED'),
                ],
              )
            : null,
      ),
      body: _isLoading
          ? Center(
              child: CircularProgressIndicator(
                color: AppTheme.primary,
              ),
            )
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.error_outline,
                        size: 64,
                        color: isDark ? Colors.white70 : Colors.grey[400],
                      ),
                      const SizedBox(height: 16),
                      Padding(
                        padding:
                            const EdgeInsets.symmetric(horizontal: 24),
                        child: Text(
                          _error!,
                          style: TextStyle(
                            color: isDark
                                ? Colors.white60
                                : Colors.grey[600],
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                      const SizedBox(height: 16),
                      ElevatedButton(
                        onPressed: _loadData,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.primary,
                          foregroundColor: Colors.white,
                        ),
                        child: const Text('TRY AGAIN'),
                      ),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _loadData,
                  color: AppTheme.primary,
                  child: isWeb ? _buildWebLayout() : _buildMobileLayout(),
                ),
    );
  }
}