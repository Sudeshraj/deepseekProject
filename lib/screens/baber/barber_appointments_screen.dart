import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:go_router/go_router.dart';
import '../../services/timezone_service.dart';
import '../../extensions/context_extensions.dart';
import '../../theme/app_theme.dart';

class BarberAppointmentsScreen extends StatefulWidget {
  const BarberAppointmentsScreen({super.key});

  @override
  State<BarberAppointmentsScreen> createState() =>
      _BarberAppointmentsScreenState();
}

class _BarberAppointmentsScreenState extends State<BarberAppointmentsScreen>
    with SingleTickerProviderStateMixin {
  final supabase = Supabase.instance.client;

  // Colors from AppTheme
  Color get _primaryColor => AppTheme.primary;
  Color get _vipColor => Colors.purple.shade400;
  Color get _secondaryColor => Colors.green;
  Color get _warningColor => Colors.orange;
  Color get _dangerColor => Colors.red;

  // Data
  List<Map<String, dynamic>> _todayAppointments = [];
  List<Map<String, dynamic>> _upcomingAppointments = [];
  List<Map<String, dynamic>> _pastAppointments = [];

  bool _isLoading = true;
  String? _error;
  bool _isBarberActive = true;

  // Tab controller
  late TabController _tabController;

  // Date selection
  DateTime _selectedDate = DateTime.now();

  // Action states
  bool _isProcessing = false;
  final TextEditingController _cancelReasonController = TextEditingController();

  // Web Scroll Controller
  final ScrollController _scrollController = ScrollController();

  // Responsive variables
  bool _isWeb = false;
  bool _isTablet = false;

  // ── Service Management State ──
  List<Map<String, dynamic>> _currentAppointmentServices = [];
  Map<String, dynamic>? _appointmentTotal = {
    'subtotal': 0.0,
    'total_discount': 0.0,
    'services_total': 0.0,
    'extra_charge': 0.0,
    'extra_charge_note': null,
    'total': 0.0,
    'currency_code': 'LKR',
    'service_count': 0,
  };
  List<Map<String, dynamic>> _availableServices = [];
  // ✅ NEW: Per-service offers cache
  final Map<int, List<Map<String, dynamic>>> _offersByService = {};
  bool _loadingServices = false;
  bool _savingExtraCharge = false;

  // Extra charge controllers
  double _extraCharge = 0.0;
  final TextEditingController _extraChargeController = TextEditingController();
  final TextEditingController _extraChargeNoteController =
      TextEditingController();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _checkBarberStatusAndLoad();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _checkScreenSize();
  }

  void _checkScreenSize() {
    final size = MediaQuery.of(context).size;
    final isWeb = size.width > 800;
    final isTablet = size.shortestSide >= 600;

    if (_isWeb != isWeb || _isTablet != isTablet) {
      setState(() {
        _isWeb = isWeb;
        _isTablet = isTablet;
      });
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _cancelReasonController.dispose();
    _scrollController.dispose();
    _extraChargeController.dispose();
    _extraChargeNoteController.dispose();
    super.dispose();
  }

  // =====================================================
  // ✅ CURRENCY SYMBOL
  // =====================================================
  String _currencySymbol(String? code) {
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

  // =====================================================
  // ✅ CHECK BARBER STATUS AND LOAD DATA
  // =====================================================
  Future<void> _checkBarberStatusAndLoad() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final user = supabase.auth.currentUser;
      if (user == null) {
        setState(() {
          _error = 'Please login to continue';
          _isLoading = false;
        });
        return;
      }

      final roleCheck = await supabase
          .from('user_roles')
          .select('status, roles!inner (name)')
          .eq('user_id', user.id)
          .eq('roles.name', 'barber')
          .maybeSingle();

      if (roleCheck == null) {
        setState(() {
          _error = 'Barber profile not found. Please contact support.';
          _isLoading = false;
          _isBarberActive = false;
        });
        return;
      }

      final status = roleCheck['status'] as String? ?? 'active';
      if (status != 'active') {
        String message = 'Your barber account is ';
        switch (status) {
          case 'inactive':
            message += 'deactivated. Please contact support.';
            break;
          case 'scheduled_for_deletion':
            message += 'scheduled for deletion. Please contact support.';
            break;
          case 'deleted':
            message += 'deleted. Please contact support.';
            break;
          default:
            message += 'not active. Please contact support.';
        }
        setState(() {
          _error = message;
          _isLoading = false;
          _isBarberActive = false;
        });
        return;
      }

      final profileCheck = await supabase
          .from('profiles')
          .select('is_active, is_blocked, full_name, extra_data')
          .eq('id', user.id)
          .maybeSingle();

      if (profileCheck != null) {
        if (profileCheck['is_blocked'] == true) {
          setState(() {
            _error = 'Your account has been blocked. Please contact support.';
            _isLoading = false;
            _isBarberActive = false;
          });
          return;
        }

        if (profileCheck['is_active'] == false) {
          final extraData =
              profileCheck['extra_data'] as Map<String, dynamic>? ?? {};
          final profileStatus =
              extraData['profile_status'] as Map<String, dynamic>?;

          if (profileStatus != null &&
              profileStatus['status'] == 'scheduled_for_deletion') {
            setState(() {
              _error =
                  'Your profile is scheduled for deletion. Please contact support.';
              _isLoading = false;
              _isBarberActive = false;
            });
            return;
          }

          setState(() {
            _error = 'Your profile is inactive. Please contact support.';
            _isLoading = false;
            _isBarberActive = false;
          });
          return;
        }
      }

      _isBarberActive = true;
      await _loadAppointments();
    } catch (e) {
      debugPrint('Error checking barber status: $e');
      setState(() {
        _error = 'Failed to load data: $e';
        _isLoading = false;
        _isBarberActive = false;
      });
    }
  }

  // =====================================================
  // ✅ LOAD APPOINTMENTS
  // =====================================================
  Future<void> _loadAppointments() async {
    if (!mounted) return;

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final user = supabase.auth.currentUser;
      if (user == null) {
        setState(() {
          _error = 'Please login to continue';
          _isLoading = false;
        });
        return;
      }

      final roleCheck = await supabase
          .from('user_roles')
          .select('status')
          .eq('user_id', user.id)
          .eq('role_id', 2)
          .maybeSingle();

      if (roleCheck == null || roleCheck['status'] != 'active') {
        setState(() {
          _error = 'Your barber account is not active.';
          _isLoading = false;
          _isBarberActive = false;
        });
        return;
      }

      // ✅ Load appointments (no service_id/variant_id here — they're in appointment_services)
      final appointments = await supabase
          .from('appointments')
          .select('''
            *,
            regular_queue_number,
            vip_queue_number,
            queue_position,
            is_vip,
            estimated_start_time,
            estimated_end_time,
            extra_charge,
            extra_charge_note
          ''')
          .eq('barber_id', user.id)
          .order('appointment_date', ascending: true);

      if (appointments.isEmpty) {
        setState(() {
          _todayAppointments = [];
          _upcomingAppointments = [];
          _pastAppointments = [];
          _isLoading = false;
        });
        return;
      }

      // Fetch customers
      final customerIds = appointments
          .map((a) => a['customer_id'] as String?)
          .where((id) => id != null)
          .toSet()
          .toList();

      Map<String, Map<String, dynamic>> customersMap = {};
      if (customerIds.isNotEmpty) {
        final activeCustomers = await supabase
            .from('user_roles')
            .select('user_id')
            .eq('role_id', 3)
            .eq('status', 'active')
            .inFilter('user_id', customerIds);

        final activeCustomerIds = activeCustomers
            .map((c) => c['user_id'] as String)
            .toList();

        if (activeCustomerIds.isNotEmpty) {
          final customers = await supabase
              .from('profiles')
              .select('id, full_name, avatar_url, phone, is_active, is_blocked')
              .inFilter('id', activeCustomerIds);

          for (var customer in customers) {
            if (customer['is_blocked'] == true ||
                customer['is_active'] == false) {
              continue;
            }
            customersMap[customer['id']] = customer;
          }
        }
      }

      // ✅ Fetch services from appointment_services
      final appointmentIds = appointments.map((a) => a['id']).toList();

      Map<int, List<Map<String, dynamic>>> servicesByAppointment = {};
      Map<int, double> servicesTotalByAppointment = {};

      if (appointmentIds.isNotEmpty) {
        final apptServices = await supabase
            .from('appointment_services')
            .select('''
              id,
              appointment_id,
              service_id,
              variant_id,
              price,
              discount_amount,
              discount_type,
              final_price,
              currency_code,
              is_original,
              offer_id,
              services!inner (name),
              service_variants (duration),
              offers (title)
            ''')
            .inFilter('appointment_id', appointmentIds);

        for (var svc in apptServices) {
          final aptId = svc['appointment_id'] as int;
          servicesByAppointment.putIfAbsent(aptId, () => []).add({
            'appointment_service_id': svc['id'],
            'service_id': svc['service_id'],
            'variant_id': svc['variant_id'],
            'service_name': svc['services']?['name'] ?? 'Service',
            'duration': svc['service_variants']?['duration'],
            'price': (svc['price'] as num?)?.toDouble() ?? 0.0,
            'discount_amount':
                (svc['discount_amount'] as num?)?.toDouble() ?? 0.0,
            'discount_type': svc['discount_type'],
            'offer_id': svc['offer_id'],
            'offer_title': svc['offers']?['title'],
            'final_price': (svc['final_price'] as num?)?.toDouble() ?? 0.0,
            'currency_code': svc['currency_code'] ?? 'LKR',
            'is_original': svc['is_original'] ?? false,
          });

          servicesTotalByAppointment[aptId] =
              (servicesTotalByAppointment[aptId] ?? 0.0) +
              ((svc['final_price'] as num?)?.toDouble() ?? 0.0);
        }
      }

      // Fetch salons
      final salonIds = appointments
          .map((a) => a['salon_id'] as int?)
          .where((id) => id != null)
          .toSet()
          .toList();

      Map<int, Map<String, dynamic>> salonsMap = {};
      if (salonIds.isNotEmpty) {
        final salons = await supabase
            .from('salons')
            .select('id, name, currency_code, currency_symbol')
            .inFilter('id', salonIds);

        for (var salon in salons) {
          salonsMap[salon['id']] = salon;
        }
      }

      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);

      final List<Map<String, dynamic>> todayList = [];
      final List<Map<String, dynamic>> upcomingList = [];
      final List<Map<String, dynamic>> pastList = [];

      for (var apt in appointments) {
        final customer = customersMap[apt['customer_id']];
        if (customer == null) continue;

        final salon = salonsMap[apt['salon_id']];
        final salonName = salon?['name'] ?? 'Salon';
        final currencyCode = (salon?['currency_code'] as String?) ?? 'LKR';

        // Services for this appointment
        final services = servicesByAppointment[apt['id']] ?? [];
        final servicesTotal = servicesTotalByAppointment[apt['id']] ?? 0.0;
        final extraCharge = (apt['extra_charge'] as num?)?.toDouble() ?? 0.0;
        final totalPrice = servicesTotal + extraCharge;

        // Service name summary
        String serviceSummary;
        if (services.isEmpty) {
          serviceSummary = 'No services';
        } else if (services.length == 1) {
          serviceSummary = services.first['service_name'] as String;
        } else {
          serviceSummary =
              '${services.first['service_name']} +${services.length - 1} more';
        }

        final utcDate = DateTime.parse(apt['appointment_date']);
        final localDate = TimezoneService.utcToLocalDateTimeForDate(
          '12:00:00',
          utcDate,
        );
        final appointmentDateOnly = DateTime(
          localDate.year,
          localDate.month,
          localDate.day,
        );

        final utcStart = apt['start_time'] as String;
        final utcEnd = apt['end_time'] as String;

        final localStart = TimezoneService.utcToLocalTimeForDate(
          utcStart,
          utcDate,
        );
        final localEnd = TimezoneService.utcToLocalTimeForDate(utcEnd, utcDate);

        String estimatedStartDisplay = '';
        String estimatedEndDisplay = '';
        if (apt['estimated_start_time'] != null) {
          final estStart = DateTime.parse(apt['estimated_start_time']);
          final localEstStart = TimezoneService.utcToLocalDateTimeForDate(
            '${estStart.hour.toString().padLeft(2, '0')}:${estStart.minute.toString().padLeft(2, '0')}:00',
            estStart,
          );
          estimatedStartDisplay = DateFormat('HH:mm').format(localEstStart);

          if (apt['estimated_end_time'] != null) {
            final estEnd = DateTime.parse(apt['estimated_end_time']);
            final localEstEnd = TimezoneService.utcToLocalDateTimeForDate(
              '${estEnd.hour.toString().padLeft(2, '0')}:${estEnd.minute.toString().padLeft(2, '0')}:00',
              estEnd,
            );
            estimatedEndDisplay = DateFormat('HH:mm').format(localEstEnd);
          }
        }

        final displayQueue = _getDisplayQueueNumber(apt);
        final isVip = apt['is_vip'] ?? false;
        final queuePosition = apt['queue_position'];
        final isStarted = apt['is_started'] ?? false;
        final isCompleted = apt['is_completed'] ?? false;

        final appointmentData = {
          'id': apt['id'],
          'booking_number': apt['booking_number'],
          'appointment_date': apt['appointment_date'],
          'start_time': apt['start_time'],
          'end_time': apt['end_time'],
          'status': apt['status'],
          'is_vip': isVip,
          'price': totalPrice,
          'services_total': servicesTotal,
          'extra_charge': extraCharge,
          'extra_charge_note': apt['extra_charge_note'],
          'currency_code': currencyCode,
          'currency_symbol': salon?['currency_symbol'],
          'services': services,
          'service_name': serviceSummary,
          'queue_number': apt['queue_number'],
          'regular_queue_number': apt['regular_queue_number'],
          'vip_queue_number': apt['vip_queue_number'],
          'queue_position': queuePosition,
          'display_queue': displayQueue,
          'child_name': apt['child_name'],
          'customer_name': customer['full_name'] ?? 'Customer',
          'customer_id': apt['customer_id'],
          'customer_avatar': customer['avatar_url'],
          'customer_phone': customer['phone'],
          'salon_id': apt['salon_id'],
          'salon_name': salonName,
          'local_start_time': localStart,
          'local_end_time': localEnd,
          'estimated_start_time': estimatedStartDisplay,
          'estimated_end_time': estimatedEndDisplay,
          'is_started': isStarted,
          'is_completed': isCompleted,
          'date_display': DateFormat('MMM dd, yyyy').format(localDate),
          'day_display': DateFormat('EEEE').format(localDate),
          'time_display': '$localStart - $localEnd',
          'display_time': _getDisplayTime({
            'estimated_start_time': apt['estimated_start_time'],
            'local_start_time': localStart,
          }),
        };

        if (apt['status'] == 'cancelled' || apt['status'] == 'no_show') {
          pastList.add(appointmentData);
        } else if (appointmentDateOnly.isAtSameMomentAs(today)) {
          todayList.add(appointmentData);
        } else if (appointmentDateOnly.isAfter(today)) {
          upcomingList.add(appointmentData);
        } else {
          pastList.add(appointmentData);
        }
      }

      todayList.sort((a, b) {
        final aPos = a['queue_position'] ?? 999;
        final bPos = b['queue_position'] ?? 999;
        return aPos.compareTo(bPos);
      });
      upcomingList.sort((a, b) {
        final aPos = a['queue_position'] ?? 999;
        final bPos = b['queue_position'] ?? 999;
        return aPos.compareTo(bPos);
      });
      pastList.sort((a, b) {
        return b['appointment_date'].compareTo(a['appointment_date']);
      });

      if (mounted) {
        setState(() {
          _todayAppointments = todayList;
          _upcomingAppointments = upcomingList;
          _pastAppointments = pastList;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Error loading appointments: $e');
      if (mounted) {
        setState(() {
          _error = 'Failed to load appointments: $e';
          _isLoading = false;
        });
      }
    }
  }

  // =====================================================
  // ✅ HELPER METHODS
  // =====================================================
  String _getDisplayQueueNumber(Map<String, dynamic> appointment) {
    final isVip = appointment['is_vip'] ?? false;
    final regularQueueNumber = appointment['regular_queue_number'];
    final vipQueueNumber = appointment['vip_queue_number'];

    if (isVip && vipQueueNumber != null) {
      return 'VIP-$vipQueueNumber';
    } else if (!isVip && regularQueueNumber != null) {
      return 'Q$regularQueueNumber';
    }
    return '';
  }

  String _getDisplayTime(Map<String, dynamic> appointment) {
    if (appointment['estimated_start_time'] != null) {
      final estimatedTime = appointment['estimated_start_time'].toString();
      if (estimatedTime.length > 5) {
        return estimatedTime.substring(0, 5);
      }
      return estimatedTime;
    }
    return appointment['local_start_time'] ?? '';
  }

  Future<bool> _checkBarberActive() async {
    try {
      final user = supabase.auth.currentUser;
      if (user == null) return false;

      final roleCheck = await supabase
          .from('user_roles')
          .select('status')
          .eq('user_id', user.id)
          .eq('role_id', 2)
          .maybeSingle();

      if (roleCheck == null) return false;
      return roleCheck['status'] == 'active';
    } catch (e) {
      debugPrint('Error checking barber active status: $e');
      return false;
    }
  }

  Future<bool> _checkForOverflowWarning(int appointmentId) async {
    try {
      final result = await supabase
          .from('overflow_notifications')
          .select('id')
          .eq('appointment_id', appointmentId)
          .eq('status', 'PENDING')
          .maybeSingle();

      return result != null;
    } catch (e) {
      return false;
    }
  }

  // =====================================================
  // ✅ SERVICE MANAGEMENT METHODS
  // =====================================================
  Future<void> _loadAppointmentServices(int appointmentId) async {
    setState(() {
      _loadingServices = true;
      _currentAppointmentServices = [];
      _appointmentTotal = null;
    });

    try {
      final servicesRes = await supabase.rpc(
        'get_appointment_services',
        params: {'p_appointment_id': appointmentId},
      );

      final totalRes = await supabase.rpc(
        'calculate_appointment_total',
        params: {'p_appointment_id': appointmentId},
      );

      if (mounted) {
        final totalMap = Map<String, dynamic>.from(totalRes as Map);
        setState(() {
          _currentAppointmentServices = List<Map<String, dynamic>>.from(
            servicesRes as List,
          );
          _appointmentTotal = totalMap;

          _extraCharge = (totalMap['extra_charge'] as num?)?.toDouble() ?? 0.0;
          _extraChargeController.text = _extraCharge > 0
              ? _extraCharge.toStringAsFixed(2)
              : '';
          _extraChargeNoteController.text =
              (totalMap['extra_charge_note'] as String?) ?? '';

          _loadingServices = false;
        });
      }
    } catch (e) {
      debugPrint('Error loading appointment services: $e');
      if (mounted) setState(() => _loadingServices = false);
    }
  }

  Future<void> _loadAvailableServices(int salonId) async {
    try {
      final res = await supabase
          .from('services')
          .select('''
            id,
            name,
            description,
            salon_categories!inner (display_name),
            service_variants!inner (
              id, price, duration, is_active,
              salon_genders (display_name),
              salon_age_categories (display_name)
            )
          ''')
          .eq('salon_id', salonId)
          .eq('is_active', true);

      final List<Map<String, dynamic>> list = [];
      for (final svc in res) {
        final variants = (svc['service_variants'] as List?) ?? [];
        for (final v in variants) {
          if (v['is_active'] == false) continue;
          list.add({
            'service_id': svc['id'],
            'service_name': svc['name'],
            'category_name': svc['salon_categories']?['display_name'],
            'variant_id': v['id'],
            'price': (v['price'] as num?)?.toDouble() ?? 0,
            'duration': v['duration'],
            'gender_name': v['salon_genders']?['display_name'],
            'age_category_name': v['salon_age_categories']?['display_name'],
          });
        }
      }

      if (mounted) {
        setState(() => _availableServices = list);
      }
    } catch (e) {
      debugPrint('Error loading available services: $e');
    }
  }

  /// ✅ NEW: Load offers for a SPECIFIC service (per-service offers)
  Future<List<Map<String, dynamic>>> _loadOffersForService(
    int salonId,
    int serviceId,
    double servicePrice,
  ) async {
    // Check cache first
    if (_offersByService.containsKey(serviceId)) {
      return _offersByService[serviceId]!;
    }

    try {
      final res = await supabase.rpc(
        'get_offers_for_service',
        params: {
          'p_salon_id': salonId,
          'p_service_id': serviceId,
          'p_service_price': servicePrice,
        },
      );

      final offers = List<Map<String, dynamic>>.from(res as List);

      // Cache it
      _offersByService[serviceId] = offers;

      return offers;
    } catch (e) {
      debugPrint('Error loading offers for service $serviceId: $e');
      return [];
    }
  }

  Future<void> _saveExtraCharge(Map<String, dynamic> appointment) async {
    if (_savingExtraCharge) return;

    final value = double.tryParse(_extraChargeController.text.trim()) ?? 0.0;

    if (value < 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Extra charge cannot be negative'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() => _savingExtraCharge = true);

    try {
      final res = await supabase.rpc(
        'update_appointment_extra_charge',
        params: {
          'p_appointment_id': appointment['id'],
          'p_barber_id': supabase.auth.currentUser!.id,
          'p_extra_charge': value,
          'p_note': _extraChargeNoteController.text.trim().isEmpty
              ? null
              : _extraChargeNoteController.text.trim(),
        },
      );

      if (res['success'] == true) {
        await _loadAppointmentServices(appointment['id']);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Extra charge saved: ${_currencySymbol(res['currency_code'])}${(res['extra_charge'] as num).toStringAsFixed(2)}',
              ),
              backgroundColor: _secondaryColor,
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      } else {
        throw Exception(res['message'] ?? 'Failed to save');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _savingExtraCharge = false);
    }
  }

  // =====================================================
  // ✅ ADD SERVICE DIALOG (with per-service offers)
  // =====================================================
  Future<void> _showAddServiceDialog(
    Map<String, dynamic> appointment,
    StateSetter parentSetState,
  ) async {
    final isDark = context.isDarkMode;
    final salonId = appointment['salon_id'] as int;
    final currencyCode =
        (_appointmentTotal?['currency_code'] as String?) ?? 'LKR';
    final symbol = _currencySymbol(currencyCode);

    Map<String, dynamic>? selectedService;
    Map<String, dynamic>? selectedOffer;
    List<Map<String, dynamic>> availableOffers = [];
    bool loadingOffers = false;
    bool isSubmitting = false;

    await showDialog(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            // Load offers when service changes
            Future<void> loadOffersForSelectedService() async {
              if (selectedService == null) return;
              setDialogState(() {
                loadingOffers = true;
                availableOffers = [];
                selectedOffer = null;
              });

              final offers = await _loadOffersForService(
                salonId,
                selectedService!['service_id'],
                (selectedService!['price'] as num).toDouble(),
              );

              setDialogState(() {
                availableOffers = offers;
                loadingOffers = false;
              });
            }

            return AlertDialog(
              backgroundColor: isDark ? const Color(0xFF1E1E1E) : Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              title: Text(
                'Add Service',
                style: context.titleLarge.copyWith(color: context.textColor),
              ),
              content: SizedBox(
                width: 400,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Service',
                        style: context.titleSmall.copyWith(
                          color: context.textColor,
                        ),
                      ),
                      const SizedBox(height: 6),
                      DropdownButtonFormField<Map<String, dynamic>>(
                        initialValue: selectedService,
                        isExpanded: true,
                        dropdownColor: isDark
                            ? const Color(0xFF2A2A2A)
                            : Colors.white,
                        decoration: InputDecoration(
                          hintText: 'Select service',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          filled: true,
                          fillColor: isDark
                              ? const Color(0xFF2A2A2A)
                              : Colors.grey[50],
                        ),
                        style: TextStyle(color: context.textColor),
                        items: _availableServices.map((s) {
                          return DropdownMenuItem<Map<String, dynamic>>(
                            value: s,
                            child: Text(
                              '${s['service_name']} — $symbol${(s['price'] as num).toStringAsFixed(2)}',
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: context.textColor),
                            ),
                          );
                        }).toList(),
                        onChanged: (v) {
                          setDialogState(() {
                            selectedService = v;
                            selectedOffer = null;
                            availableOffers = [];
                          });
                          if (v != null) {
                            loadOffersForSelectedService();
                          }
                        },
                      ),

                      // ✅ Offers section — only for selected service
                      if (selectedService != null) ...[
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Icon(
                              Icons.local_offer,
                              size: 16,
                              color: _warningColor,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              'Apply Offer (optional)',
                              style: context.titleSmall.copyWith(
                                color: context.textColor,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        if (loadingOffers)
                          Container(
                            padding: const EdgeInsets.all(12),
                            child: Row(
                              children: [
                                SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: _primaryColor,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Text(
                                  'Loading offers...',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: context.secondaryTextColor,
                                  ),
                                ),
                              ],
                            ),
                          )
                        else if (availableOffers.isEmpty)
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: isDark
                                  ? Colors.grey[800]
                                  : Colors.grey[100],
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.info_outline,
                                  size: 14,
                                  color: context.secondaryTextColor,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'No offers available for this service',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: context.secondaryTextColor,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          )
                        else
                          DropdownButtonFormField<Map<String, dynamic>?>(
                            initialValue: selectedOffer,
                            isExpanded: true,
                            dropdownColor: isDark
                                ? const Color(0xFF2A2A2A)
                                : Colors.white,
                            decoration: InputDecoration(
                              hintText: 'No offer',
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                              filled: true,
                              fillColor: isDark
                                  ? const Color(0xFF2A2A2A)
                                  : Colors.grey[50],
                            ),
                            style: TextStyle(color: context.textColor),
                            items: [
                              DropdownMenuItem<Map<String, dynamic>?>(
                                value: null,
                                child: Text(
                                  'No offer',
                                  style: TextStyle(
                                    color: context.secondaryTextColor,
                                  ),
                                ),
                              ),
                              ...availableOffers.map((o) {
                                final discountType =
                                    o['discount_type'] as String?;
                                final discountValue =
                                    (o['discount_value'] as num?)?.toDouble() ??
                                    0;
                                String label;
                                if (discountType == 'percentage') {
                                  label =
                                      '${o['title']} (${discountValue.toStringAsFixed(0)}% off)';
                                } else if (discountType == 'fixed') {
                                  label =
                                      '${o['title']} ($symbol${discountValue.toStringAsFixed(2)} off)';
                                } else {
                                  label = '${o['title']} (Free)';
                                }
                                return DropdownMenuItem<Map<String, dynamic>?>(
                                  value: o,
                                  child: Text(
                                    label,
                                    style: TextStyle(color: context.textColor),
                                  ),
                                );
                              }),
                            ],
                            onChanged: (v) =>
                                setDialogState(() => selectedOffer = v),
                          ),

                        // Preview
                        const SizedBox(height: 16),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: _primaryColor.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Preview',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: _primaryColor,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    'Service Price:',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: context.textColor,
                                    ),
                                  ),
                                  Text(
                                    '$symbol${(selectedService!['price'] as num).toStringAsFixed(2)}',
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      color: context.textColor,
                                    ),
                                  ),
                                ],
                              ),
                              if (selectedOffer != null) ...[
                                const SizedBox(height: 2),
                                Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      'Discount:',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: _secondaryColor,
                                      ),
                                    ),
                                    Text(
                                      '-${_calculateDiscount(selectedService!, selectedOffer!, symbol)}',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: _secondaryColor,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                              const Divider(height: 12),
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    'Total:',
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.bold,
                                      color: context.textColor,
                                    ),
                                  ),
                                  Text(
                                    _calculateFinalPrice(
                                      selectedService!,
                                      selectedOffer,
                                      symbol,
                                    ),
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.bold,
                                      color: _primaryColor,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: isSubmitting
                      ? null
                      : () => Navigator.pop(dialogContext),
                  child: const Text('CANCEL'),
                ),
                ElevatedButton(
                  onPressed: isSubmitting || selectedService == null
                      ? null
                      : () async {
                          setDialogState(() => isSubmitting = true);
                          try {
                            final res = await supabase.rpc(
                              'add_service_to_appointment',
                              params: {
                                'p_appointment_id': appointment['id'],
                                'p_service_id': selectedService!['service_id'],
                                'p_variant_id': selectedService!['variant_id'],
                                'p_barber_id': supabase.auth.currentUser!.id,
                                'p_offer_id': selectedOffer?['offer_id'],
                              },
                            );

                            if (res['success'] == true) {
                              if (dialogContext.mounted) {
                                Navigator.pop(dialogContext);
                              }
                              await _loadAppointmentServices(appointment['id']);
                              parentSetState(() {});
                              if (mounted) {
                                setState(() {});
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      'Service added: $symbol${(res['final_price'] as num).toStringAsFixed(2)}',
                                    ),
                                    backgroundColor: _secondaryColor,
                                    behavior: SnackBarBehavior.floating,
                                  ),
                                );
                              }
                            } else {
                              throw Exception(
                                res['message'] ?? 'Failed to add service',
                              );
                            }
                          } catch (e) {
                            setDialogState(() => isSubmitting = false);
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text('Error: $e'),
                                  backgroundColor: Colors.red,
                                ),
                              );
                            }
                          }
                        },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _primaryColor,
                    foregroundColor: Colors.white,
                  ),
                  child: isSubmitting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Text('ADD'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  String _calculateDiscount(
    Map<String, dynamic> service,
    Map<String, dynamic> offer,
    String symbol,
  ) {
    final price =
        (service['price'] as num?)?.toDouble() ??
        0; // ✅ was: (service['price'] as num).toDouble()
    final discountType = offer['discount_type'] as String?;
    final discountValue = (offer['discount_value'] as num?)?.toDouble() ?? 0;

    double discount = 0;
    if (price > 0) {
      // ✅ Only calculate if price > 0
      if (discountType == 'percentage') {
        discount = price * (discountValue / 100);
      } else if (discountType == 'fixed') {
        discount = discountValue > price ? price : discountValue;
      } else if (discountType == 'free_service') {
        discount = price;
      }
    }
    return '$symbol${discount.toStringAsFixed(2)}';
  }

  String _calculateFinalPrice(
    Map<String, dynamic> service,
    Map<String, dynamic>? offer,
    String symbol,
  ) {
    final price = (service['price'] as num?)?.toDouble() ?? 0; // ✅ Null-safe
    if (offer == null || price <= 0) {
      return '$symbol${price.toStringAsFixed(2)}';
    }

    final discountType = offer['discount_type'] as String?;
    final discountValue = (offer['discount_value'] as num?)?.toDouble() ?? 0;

    double discount = 0;
    if (discountType == 'percentage') {
      discount = price * (discountValue / 100);
    } else if (discountType == 'fixed') {
      discount = discountValue > price ? price : discountValue;
    } else if (discountType == 'free_service') {
      discount = price;
    }
    final finalPrice = price - discount;
    return '$symbol${(finalPrice < 0 ? 0 : finalPrice).toStringAsFixed(2)}';
  }

  // =====================================================
  // ✅ ACTION METHODS
  // =====================================================
  Future<void> _startAppointment(Map<String, dynamic> appointment) async {
    if (_isProcessing) return;

    final isActive = await _checkBarberActive();
    if (!isActive) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Your barber account is not active.'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }
    if (!mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: context.backgroundColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'Start Appointment?',
          style: context.titleLarge.copyWith(color: context.textColor),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Are you ready to start ${appointment['customer_name']}\'s appointment?',
              style: context.bodyMedium.copyWith(color: context.textColor),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: context.isDarkMode ? Colors.grey[800] : Colors.grey[100],
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      Icon(Icons.access_time, size: 16, color: _primaryColor),
                      const SizedBox(width: 8),
                      Text(
                        'Display Time: ${appointment['display_time']}',
                        style: TextStyle(
                          fontWeight: FontWeight.w500,
                          color: context.textColor,
                        ),
                      ),
                    ],
                  ),
                  const Divider(),
                  Row(
                    children: [
                      Icon(
                        appointment['is_vip'] == true
                            ? Icons.star
                            : Icons.person,
                        size: 16,
                        color: appointment['is_vip'] == true
                            ? _vipColor
                            : _primaryColor,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Customer: ${appointment['customer_name']}',
                        style: TextStyle(color: context.textColor),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '⚠️ If you start late, next appointments will be adjusted automatically.',
              style: TextStyle(fontSize: 11, color: _warningColor),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('CANCEL'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: _secondaryColor,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: const Text('START NOW'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _isProcessing = true);

    try {
      final user = supabase.auth.currentUser;
      if (user == null) throw Exception('User not found');

      final nowUtc = DateTime.now().toUtc();
      final userTimezone = TimezoneService.getCurrentTimezone();

      final result = await supabase.rpc(
        'adjust_on_appointment_start',
        params: {
          'p_appointment_id': appointment['id'],
          'p_actual_start_time': nowUtc.toIso8601String(),
          'p_country_timezone': userTimezone,
        },
      );

      if (result['success'] == true) {
        if (mounted) {
          String message = '✅ Appointment started!';
          if (result['start_delay_minutes'] != null &&
              result['start_delay_minutes'] > 0) {
            message =
                '⚠️ Started ${result['start_delay_minutes']} min late. Next appointments adjusted.';
          } else if (result['start_delay_minutes'] != null &&
              result['start_delay_minutes'] < 0) {
            message =
                '✅ Started ${result['start_delay_minutes'].abs()} min early.';
          }

          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(message),
              backgroundColor: result['start_delay_minutes'] > 0
                  ? _warningColor
                  : _secondaryColor,
              behavior: SnackBarBehavior.floating,
              duration: const Duration(seconds: 3),
            ),
          );
          await _loadAppointments();
        }
      } else {
        throw Exception(result['message'] ?? 'Failed to start appointment');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<void> _endAppointment(Map<String, dynamic> appointment) async {
    if (_isProcessing) return;

    final isActive = await _checkBarberActive();
    if (!isActive) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Your barber account is not active.'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }

    // Load fresh total
    final totalRes = await supabase.rpc(
      'calculate_appointment_total',
      params: {'p_appointment_id': appointment['id']},
    );
    final totalMap = Map<String, dynamic>.from(totalRes as Map);
    final symbol = _currencySymbol(totalMap['currency_code'] as String?);
    final servicesTotal = (totalMap['services_total'] as num?)?.toDouble() ?? 0;
    final extraCharge = (totalMap['extra_charge'] as num?)?.toDouble() ?? 0;
    final total = (totalMap['total'] as num?)?.toDouble() ?? 0;

    final hasOverflow = await _checkForOverflowWarning(appointment['id']);
    if (!mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: context.backgroundColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'End Appointment?',
          style: context.titleLarge.copyWith(color: context.textColor),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Mark ${appointment['customer_name']}\'s appointment as completed?',
              style: context.bodyMedium.copyWith(color: context.textColor),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: context.isDarkMode ? Colors.grey[800] : Colors.grey[100],
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Services:',
                        style: TextStyle(color: context.textColor),
                      ),
                      Text(
                        '$symbol${servicesTotal.toStringAsFixed(2)}',
                        style: TextStyle(color: context.textColor),
                      ),
                    ],
                  ),
                  if (extraCharge > 0) ...[
                    const SizedBox(height: 4),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Extra Charge:',
                          style: TextStyle(color: _warningColor),
                        ),
                        Text(
                          '+$symbol${extraCharge.toStringAsFixed(2)}',
                          style: TextStyle(color: _warningColor),
                        ),
                      ],
                    ),
                  ],
                  const Divider(),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Total:',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: context.textColor,
                        ),
                      ),
                      Text(
                        '$symbol${total.toStringAsFixed(2)}',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: _primaryColor,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (hasOverflow)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: _warningColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: _warningColor),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.warning_amber, size: 18, color: _warningColor),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '⚠️ This appointment has an overflow warning.',
                          style: TextStyle(fontSize: 12, color: _warningColor),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 8),
            Text(
              '⚠️ Final total: $symbol${total.toStringAsFixed(2)} will be saved.',
              style: TextStyle(fontSize: 11, color: _warningColor),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('CANCEL'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: _secondaryColor,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: const Text('END APPOINTMENT'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _isProcessing = true);

    try {
      final user = supabase.auth.currentUser;
      if (user == null) throw Exception('User not found');

      final nowUtc = DateTime.now().toUtc();

      final result = await supabase.rpc(
        'adjust_queue_on_appointment_end',
        params: {
          'p_appointment_id': appointment['id'],
          'p_actual_end_time': nowUtc.toIso8601String(),
          'p_customer_decision': null,
        },
      );

      if (result['success'] == true) {
        if (mounted) {
          String message = '✅ Appointment completed!';
          if (result['delay_minutes'] != null && result['delay_minutes'] > 0) {
            message =
                '⚠️ Completed ${result['delay_minutes']} min late. Next appointments adjusted.';
          }

          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(message),
              backgroundColor:
                  result['delay_minutes'] != null && result['delay_minutes'] > 0
                  ? _warningColor
                  : _secondaryColor,
              behavior: SnackBarBehavior.floating,
              duration: const Duration(seconds: 3),
            ),
          );

          if (result['needs_confirmation'] == true) {
            _showOverflowNotificationDialog(result);
          }

          await _loadAppointments();
        }
      } else {
        throw Exception(result['message'] ?? 'Failed to complete appointment');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<void> _cancelAppointment(Map<String, dynamic> appointment) async {
    if (_isProcessing) return;

    final isActive = await _checkBarberActive();
    if (!isActive) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Your barber account is not active.'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }

    String? selectedReason;
    final TextEditingController otherReasonController = TextEditingController();
    bool showOtherField = false;
    String? validationError;

    final List<Map<String, String>> cancelReasons = [
      {'value': 'Customer no show', 'label': '❌ Customer No Show'},
      {
        'value': 'Customer requested cancellation',
        'label': '🙋 Customer Requested Cancellation',
      },
      {'value': 'Barber unavailable', 'label': '👤 Barber Unavailable'},
      {'value': 'Equipment issue', 'label': '🔧 Equipment Issue'},
      {'value': 'Schedule conflict', 'label': '📅 Schedule Conflict'},
      {'value': 'Other', 'label': '📝 Other'},
    ];
    if (!mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setStateDialog) {
          return AlertDialog(
            backgroundColor: context.backgroundColor,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
            ),
            title: Row(
              children: [
                Icon(Icons.cancel_outlined, color: _dangerColor, size: 28),
                const SizedBox(width: 12),
                Text(
                  'Cancel Appointment',
                  style: context.titleLarge.copyWith(color: context.textColor),
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
                    color: context.isDarkMode
                        ? Colors.grey[800]
                        : Colors.grey[50],
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: context.isDarkMode
                          ? Colors.grey[700]!
                          : Colors.grey[200]!,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            appointment['is_vip'] == true
                                ? Icons.star
                                : Icons.person,
                            size: 16,
                            color: appointment['is_vip'] == true
                                ? _vipColor
                                : _primaryColor,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            appointment['customer_name'],
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: context.textColor,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(
                            Icons.calendar_today,
                            size: 14,
                            color: context.secondaryTextColor,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '${appointment['date_display']} at ${appointment['display_time']}',
                            style: TextStyle(
                              fontSize: 13,
                              color: context.secondaryTextColor,
                            ),
                          ),
                        ],
                      ),
                      if (appointment['service_name'] != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Row(
                            children: [
                              Icon(
                                Icons.content_cut,
                                size: 14,
                                color: context.secondaryTextColor,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  appointment['service_name']!,
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: context.secondaryTextColor,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  'Reason for cancellation',
                  style: context.titleSmall.copyWith(color: context.textColor),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: selectedReason,
                  isExpanded: true,
                  dropdownColor: context.backgroundColor,
                  decoration: InputDecoration(
                    hintText: 'Select a reason',
                    hintStyle: TextStyle(color: context.secondaryTextColor),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 12,
                    ),
                    filled: true,
                    fillColor: context.isDarkMode
                        ? const Color(0xFF2A2A2A)
                        : Colors.white,
                  ),
                  style: TextStyle(color: context.textColor),
                  items: cancelReasons.map((reason) {
                    return DropdownMenuItem<String>(
                      value: reason['value'],
                      child: Text(reason['label']!),
                    );
                  }).toList(),
                  onChanged: (value) {
                    setStateDialog(() {
                      selectedReason = value;
                      showOtherField = (value == 'Other');
                      validationError = null;
                      if (!showOtherField) {
                        otherReasonController.clear();
                      }
                    });
                  },
                ),
                if (showOtherField) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: otherReasonController,
                    maxLines: 2,
                    style: TextStyle(color: context.textColor),
                    decoration: InputDecoration(
                      hintText: 'Please specify the reason...',
                      hintStyle: TextStyle(color: context.secondaryTextColor),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: _primaryColor, width: 2),
                      ),
                      filled: true,
                      fillColor: context.isDarkMode
                          ? const Color(0xFF2A2A2A)
                          : Colors.white,
                    ),
                    onChanged: (_) {
                      setStateDialog(() {
                        validationError = null;
                      });
                    },
                  ),
                ],
                if (validationError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.error_outline,
                          size: 16,
                          color: Colors.red,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            validationError!,
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.red,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.orange.shade50,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.orange.shade200),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.warning_amber,
                        size: 18,
                        color: Colors.orange.shade700,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'This action cannot be undone. Customer will be notified.',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.orange.shade700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                style: TextButton.styleFrom(
                  foregroundColor: context.secondaryTextColor,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                ),
                child: const Text('KEEP BOOKING'),
              ),
              ElevatedButton(
                onPressed: () {
                  if (selectedReason == null) {
                    setStateDialog(() {
                      validationError = 'Please select a reason';
                    });
                    return;
                  }
                  if (selectedReason == 'Other' &&
                      otherReasonController.text.trim().isEmpty) {
                    setStateDialog(() {
                      validationError = 'Please specify the reason';
                    });
                    return;
                  }
                  Navigator.pop(context, true);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: _dangerColor,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 12,
                  ),
                ),
                child: const Text('YES, CANCEL'),
              ),
            ],
          );
        },
      ),
    );

    if (confirmed != true) return;

    setState(() => _isProcessing = true);

    try {
      final user = supabase.auth.currentUser;
      if (user == null) throw Exception('User not found');

      String finalReason;
      if (selectedReason == 'Other') {
        finalReason = otherReasonController.text.trim();
      } else {
        finalReason = selectedReason!;
      }

      final result = await supabase.rpc(
        'cancel_booking_and_reorder',
        params: {
          'p_appointment_id': appointment['id'],
          'p_cancelled_by': user.id,
          'p_cancel_reason': finalReason,
          'p_role': 'barber',
        },
      );

      if (result['success'] == true) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Row(
                children: [
                  const Icon(Icons.check_circle, color: Colors.white, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(result['message'] ?? 'Appointment cancelled'),
                  ),
                ],
              ),
              backgroundColor: Colors.orange,
              behavior: SnackBarBehavior.floating,
            ),
          );
          await _loadAppointments();
        }
      } else {
        throw Exception(result['message'] ?? 'Cancellation failed');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isProcessing = false);
        otherReasonController.dispose();
      }
    }
  }

  void _showOverflowNotificationDialog(Map<String, dynamic> result) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: context.backgroundColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Icon(Icons.warning_amber, color: _warningColor),
            const SizedBox(width: 8),
            Text(
              'Customer Notification Sent',
              style: context.titleLarge.copyWith(color: context.textColor),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              result['message'] ?? 'Appointment exceeds salon hours.',
              style: context.bodyMedium.copyWith(color: context.textColor),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _warningColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                'Customer has been notified and can choose to MOVE or CANCEL.\n\nIf no response within 30 minutes, the appointment will be auto-cancelled.',
                style: context.bodySmall.copyWith(color: _warningColor),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _showCustomerInfo(Map<String, dynamic> appointment) {
    final isVip = appointment['is_vip'] ?? false;
    final displayQueue = appointment['display_queue'] ?? '';
    final queuePosition = appointment['queue_position'];
    final displayTime = appointment['display_time'];
    final isDark = context.isDarkMode;
    final symbol = _currencySymbol(appointment['currency_code'] as String?);
    final total = (appointment['price'] as num?)?.toDouble() ?? 0;
    final extraCharge = (appointment['extra_charge'] as num?)?.toDouble() ?? 0;
    final extraNote = appointment['extra_charge_note'] as String?;
    final services = (appointment['services'] as List?) ?? [];

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
              Row(
                children: [
                  CircleAvatar(
                    radius: 30,
                    backgroundColor: isVip
                        ? _vipColor.withValues(alpha: 0.1)
                        : _primaryColor.withValues(alpha: 0.1),
                    backgroundImage: appointment['customer_avatar'] != null
                        ? NetworkImage(appointment['customer_avatar'])
                        : null,
                    child: appointment['customer_avatar'] == null
                        ? Text(
                            (appointment['customer_name'][0]).toUpperCase(),
                            style: TextStyle(
                              fontSize: 24,
                              color: isVip ? _vipColor : _primaryColor,
                            ),
                          )
                        : null,
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              appointment['customer_name'],
                              style: context.titleMedium.copyWith(
                                color: context.textColor,
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
                                    color: Colors.white,
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        if (appointment['customer_phone'] != null)
                          Text(
                            appointment['customer_phone'],
                            style: context.bodyMedium.copyWith(
                              color: context.secondaryTextColor,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),

              // ✅ Services breakdown with per-service discounts
              if (services.isNotEmpty) ...[
                Text(
                  'Services',
                  style: context.titleSmall.copyWith(color: context.textColor),
                ),
                const SizedBox(height: 8),
                ...services.map((s) {
                  final price = (s['price'] as num?)?.toDouble() ?? 0;
                  final discount =
                      (s['discount_amount'] as num?)?.toDouble() ?? 0;
                  final finalPrice =
                      (s['final_price'] as num?)?.toDouble() ?? 0;
                  final offerTitle = s['offer_title'] as String?;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 6),
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
                                  color: context.textColor,
                                ),
                              ),
                            ),
                            if (discount > 0)
                              Text(
                                '$symbol${price.toStringAsFixed(2)}',
                                style: TextStyle(
                                  fontSize: 11,
                                  decoration: TextDecoration.lineThrough,
                                  color: context.secondaryTextColor,
                                ),
                              ),
                            if (discount > 0) const SizedBox(width: 4),
                            Text(
                              '$symbol${(discount > 0 ? finalPrice : price).toStringAsFixed(2)}',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: discount > 0
                                    ? _secondaryColor
                                    : context.textColor,
                              ),
                            ),
                          ],
                        ),
                        if (discount > 0 && offerTitle != null)
                          Padding(
                            padding: const EdgeInsets.only(left: 4, top: 2),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.local_offer,
                                  size: 10,
                                  color: _secondaryColor,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  '$offerTitle — save $symbol${discount.toStringAsFixed(2)}',
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: _secondaryColor,
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
              ],

              _buildInfoTile('Date', appointment['date_display']),
              _buildInfoTile('Time', displayTime),
              _buildInfoTile('Salon', appointment['salon_name']),
              if (appointment['child_name'] != null &&
                  appointment['child_name'].toString().isNotEmpty)
                _buildInfoTile('Booked For', appointment['child_name']),
              if (displayQueue.isNotEmpty)
                _buildInfoTile('Queue Number', displayQueue),
              if (queuePosition != null)
                _buildInfoTile('Position', '#$queuePosition'),

              // ✅ Total breakdown
              const Divider(height: 24),
              if (extraCharge > 0)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.add_circle,
                            size: 14,
                            color: _warningColor,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            extraNote != null && extraNote.isNotEmpty
                                ? 'Extra ($extraNote)'
                                : 'Extra Charge',
                            style: TextStyle(
                              fontSize: 13,
                              color: _warningColor,
                            ),
                          ),
                        ],
                      ),
                      Text(
                        '+$symbol${extraCharge.toStringAsFixed(2)}',
                        style: TextStyle(fontSize: 13, color: _warningColor),
                      ),
                    ],
                  ),
                ),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: _primaryColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Total Price',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: context.textColor,
                      ),
                    ),
                    Text(
                      '$symbol${total.toStringAsFixed(2)}',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: _primaryColor,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(context),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: isVip ? _vipColor : _primaryColor,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: const Text('CLOSE'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInfoTile(String label, String value, {String? subtitle}) {
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
              style: context.bodyMedium.copyWith(
                color: isDark ? Colors.white60 : context.secondaryTextColor,
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value,
                  style: context.bodyMedium.copyWith(
                    fontWeight: FontWeight.w500,
                    color: isDark ? Colors.white : context.textColor,
                  ),
                ),
                if (subtitle != null)
                  Text(
                    subtitle,
                    style: context.bodySmall.copyWith(
                      color: isDark
                          ? Colors.white60
                          : context.secondaryTextColor,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showDatePickerDialog() {
    final isDark = context.isDarkMode;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: isDark ? const Color(0xFF1E1E1E) : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'Select Date',
          style: context.titleLarge.copyWith(
            color: isDark ? Colors.white : Colors.black87,
          ),
        ),
        content: SizedBox(
          width: 300,
          height: 350,
          child: CalendarDatePicker(
            initialDate: _selectedDate,
            firstDate: DateTime.now().subtract(const Duration(days: 30)),
            lastDate: DateTime.now().add(const Duration(days: 60)),
            onDateChanged: (date) {
              Navigator.pop(context);
              setState(() {
                _selectedDate = date;
              });
              _loadAppointments();
            },
          ),
        ),
      ),
    );
  }

  // =====================================================
  // ✅ MANAGE SERVICES BOTTOM SHEET
  // =====================================================
  Future<void> _showManageServicesSheet(
    Map<String, dynamic> appointment,
  ) async {
    final isDark = context.isDarkMode;
    final salonId = appointment['salon_id'] as int?;
    final currencyCode = (appointment['currency_code'] as String?) ?? 'LKR';
    final symbol = _currencySymbol(currencyCode);
    final isLocked =
        appointment['status'] == 'completed' ||
        appointment['status'] == 'cancelled';

    if (salonId == null) return;

    // ✅ Clear offers cache to get fresh data
    _offersByService.clear();

    await Future.wait([
      _loadAppointmentServices(appointment['id']),
      _loadAvailableServices(salonId),
    ]);

    if (!mounted) return;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: isDark ? const Color(0xFF1E1E1E) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return DraggableScrollableSheet(
              initialChildSize: 0.9,
              minChildSize: 0.5,
              maxChildSize: 0.95,
              expand: false,
              builder: (context, scrollController) {
                return Column(
                  children: [
                    Container(
                      margin: const EdgeInsets.only(top: 12, bottom: 8),
                      width: 50,
                      height: 4,
                      decoration: BoxDecoration(
                        color: isDark ? Colors.grey[700] : Colors.grey[300],
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Row(
                        children: [
                          Icon(Icons.content_cut, color: _primaryColor),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Services',
                                  style: context.titleLarge.copyWith(
                                    color: context.textColor,
                                  ),
                                ),
                                Text(
                                  appointment['customer_name'],
                                  style: context.bodySmall.copyWith(
                                    color: context.secondaryTextColor,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (isLocked)
                            Chip(
                              label: Text(
                                appointment['status'],
                                style: const TextStyle(fontSize: 10),
                              ),
                              backgroundColor: Colors.grey.withValues(
                                alpha: 0.2,
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: _loadingServices
                          ? Center(
                              child: CircularProgressIndicator(
                                color: _primaryColor,
                              ),
                            )
                          : ListView(
                              controller: scrollController,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                              children: [
                                Text(
                                  'Current Services',
                                  style: context.titleSmall.copyWith(
                                    color: context.textColor,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                if (_currentAppointmentServices.isEmpty)
                                  Padding(
                                    padding: const EdgeInsets.all(16),
                                    child: Text(
                                      'No services added yet',
                                      style: TextStyle(
                                        color: context.secondaryTextColor,
                                      ),
                                    ),
                                  )
                                else
                                  ..._currentAppointmentServices.map((s) {
                                    return _buildServiceTile(
                                      service: s,
                                      symbol: symbol,
                                      isDark: isDark,
                                      canRemove:
                                          !isLocked &&
                                          (s['is_original'] != true),
                                      onRemove: () async {
                                        final res = await supabase.rpc(
                                          'remove_service_from_appointment',
                                          params: {
                                            'p_appointment_service_id':
                                                s['appointment_service_id'],
                                            'p_barber_id':
                                                supabase.auth.currentUser!.id,
                                          },
                                        );
                                        if (res['success'] == true) {
                                          await _loadAppointmentServices(
                                            appointment['id'],
                                          );
                                          setSheetState(() {});
                                          if (mounted) setState(() {});
                                        } else {
                                          if (mounted) {
                                            ScaffoldMessenger.of(
                                              context,
                                            ).showSnackBar(
                                              SnackBar(
                                                content: Text(
                                                  res['message'] ?? 'Failed',
                                                ),
                                              ),
                                            );
                                          }
                                        }
                                      },
                                    );
                                  }),

                                const SizedBox(height: 20),

                                _buildTotalSummary(
                                  isDark: isDark,
                                  symbol: symbol,
                                ),

                                const SizedBox(height: 16),

                                // ✅ Extra Charge section
                                _buildExtraChargeSection(
                                  appointment: appointment,
                                  isDark: isDark,
                                  symbol: symbol,
                                  isLocked: isLocked,
                                  setSheetState: setSheetState,
                                ),

                                const SizedBox(height: 24),

                                if (!isLocked) ...[
                                  Text(
                                    'Add Service',
                                    style: context.titleSmall.copyWith(
                                      color: context.textColor,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  ElevatedButton.icon(
                                    onPressed: () => _showAddServiceDialog(
                                      appointment,
                                      setSheetState,
                                    ),
                                    icon: const Icon(Icons.add),
                                    label: const Text('ADD SERVICE'),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: _primaryColor,
                                      foregroundColor: Colors.white,
                                      minimumSize: const Size.fromHeight(48),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                    ),
                                  ),
                                ] else ...[
                                  Container(
                                    padding: const EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      color: Colors.grey.withValues(alpha: 0.1),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Row(
                                      children: [
                                        const Icon(
                                          Icons.lock_outline,
                                          size: 16,
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text(
                                            'Appointment is ${appointment['status']} — services cannot be modified',
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: context.secondaryTextColor,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                                const SizedBox(height: 24),
                              ],
                            ),
                    ),
                  ],
                );
              },
            );
          },
        );
      },
    );

    // After sheet closes, reload appointments
    await _loadAppointments();
  }

  Widget _buildServiceTile({
    required Map<String, dynamic> service,
    required String symbol,
    required bool isDark,
    required bool canRemove,
    required VoidCallback onRemove,
  }) {
    final price = (service['price'] as num?)?.toDouble() ?? 0;
    final discount = (service['discount_amount'] as num?)?.toDouble() ?? 0;
    final finalPrice = (service['final_price'] as num?)?.toDouble() ?? 0;
    final offerTitle = service['offer_title'] as String?;
    final duration = service['duration'];

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF2A2A2A) : Colors.grey[50],
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDark ? Colors.grey[800]! : Colors.grey[200]!,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            service['service_name'] ?? 'Service',
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: context.textColor,
                            ),
                          ),
                        ),
                        if (service['is_original'] == true)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: _primaryColor.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              'Original',
                              style: TextStyle(
                                fontSize: 9,
                                color: _primaryColor,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                      ],
                    ),
                    if (duration != null)
                      Text(
                        '$duration min',
                        style: TextStyle(
                          fontSize: 11,
                          color: context.secondaryTextColor,
                        ),
                      ),
                  ],
                ),
              ),
              if (canRemove)
                IconButton(
                  onPressed: onRemove,
                  icon: Icon(
                    Icons.delete_outline,
                    size: 20,
                    color: _dangerColor,
                  ),
                  tooltip: 'Remove',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '$symbol${price.toStringAsFixed(2)}',
                style: TextStyle(
                  fontSize: 13,
                  color: discount > 0
                      ? context.secondaryTextColor
                      : context.textColor,
                  decoration: discount > 0 ? TextDecoration.lineThrough : null,
                ),
              ),
              if (discount > 0)
                Text(
                  '$symbol${finalPrice.toStringAsFixed(2)}',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: _secondaryColor,
                  ),
                ),
            ],
          ),
          if (discount > 0 && offerTitle != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  Icon(Icons.local_offer, size: 12, color: _secondaryColor),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      '$offerTitle  •  −$symbol${discount.toStringAsFixed(2)}',
                      style: TextStyle(
                        fontSize: 11,
                        color: _secondaryColor,
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
  }

  Widget _buildTotalSummary({required bool isDark, required String symbol}) {
    final subtotal = (_appointmentTotal?['subtotal'] as num?)?.toDouble() ?? 0;
    final discount =
        (_appointmentTotal?['total_discount'] as num?)?.toDouble() ?? 0;
    final servicesTotal =
        (_appointmentTotal?['services_total'] as num?)?.toDouble() ?? 0;
    final extraCharge =
        (_appointmentTotal?['extra_charge'] as num?)?.toDouble() ?? 0;
    final extraNote = _appointmentTotal?['extra_charge_note'] as String?;
    final total = (_appointmentTotal?['total'] as num?)?.toDouble() ?? 0;
    final count = (_appointmentTotal?['service_count'] as num?)?.toInt() ?? 0;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            _primaryColor.withValues(alpha: 0.1),
            _primaryColor.withValues(alpha: 0.05),
          ],
        ),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _primaryColor.withValues(alpha: 0.3)),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Services ($count)',
                style: TextStyle(color: context.secondaryTextColor),
              ),
              Text(
                '$symbol${subtotal.toStringAsFixed(2)}',
                style: TextStyle(color: context.textColor),
              ),
            ],
          ),
          if (discount > 0) ...[
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(Icons.local_offer, size: 14, color: _secondaryColor),
                    const SizedBox(width: 6),
                    Text('Discount', style: TextStyle(color: _secondaryColor)),
                  ],
                ),
                Text(
                  '−$symbol${discount.toStringAsFixed(2)}',
                  style: TextStyle(
                    color: _secondaryColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ],
          if (extraCharge > 0) ...[
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(Icons.add_circle, size: 14, color: _warningColor),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        extraNote != null && extraNote.isNotEmpty
                            ? 'Extra ($extraNote)'
                            : 'Extra Charge',
                        style: TextStyle(color: _warningColor),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                Text(
                  '+$symbol${extraCharge.toStringAsFixed(2)}',
                  style: TextStyle(
                    color: _warningColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ],
          const Divider(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Total',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: context.textColor,
                ),
              ),
              Text(
                '$symbol${total.toStringAsFixed(2)}',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: _primaryColor,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildExtraChargeSection({
    required Map<String, dynamic> appointment,
    required bool isDark,
    required String symbol,
    required bool isLocked,
    required StateSetter setSheetState,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF2A2A2A) : Colors.amber.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _warningColor.withValues(alpha: 0.4),
          width: 1.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.add_circle_outline, size: 18, color: _warningColor),
              const SizedBox(width: 8),
              Text(
                'Extra Charge',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                  color: context.textColor,
                ),
              ),
              const Spacer(),
              if (_extraCharge > 0)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: _warningColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '+$symbol${_extraCharge.toStringAsFixed(2)}',
                    style: TextStyle(
                      fontSize: 11,
                      color: _warningColor,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Additional fee for materials, transport, etc.',
            style: TextStyle(fontSize: 11, color: context.secondaryTextColor),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _extraChargeController,
            enabled: !isLocked && !_savingExtraCharge,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}')),
            ],
            style: TextStyle(color: context.textColor),
            decoration: InputDecoration(
              labelText: 'Amount',
              hintText: '0.00',
              prefixText: '$symbol ',
              prefixStyle: TextStyle(color: context.textColor),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
              ),
              filled: true,
              fillColor: isDark ? const Color(0xFF1E1E1E) : Colors.white,
              suffixIcon: _extraChargeController.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: () {
                        _extraChargeController.clear();
                        setSheetState(() {});
                      },
                    )
                  : null,
            ),
            onChanged: (_) => setSheetState(() {}),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _extraChargeNoteController,
            enabled: !isLocked && !_savingExtraCharge,
            maxLines: 1,
            style: TextStyle(color: context.textColor, fontSize: 13),
            decoration: InputDecoration(
              labelText: 'Note (optional)',
              hintText: 'e.g., Hair wash, Shampoo',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
              ),
              filled: true,
              fillColor: isDark ? const Color(0xFF1E1E1E) : Colors.white,
              isDense: true,
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: isLocked || _savingExtraCharge
                  ? null
                  : () async {
                      await _saveExtraCharge(appointment);
                      setSheetState(() {});
                    },
              icon: _savingExtraCharge
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.save, size: 18),
              label: Text(
                _savingExtraCharge ? 'SAVING...' : 'SAVE EXTRA CHARGE',
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: _warningColor,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // =====================================================
  // ✅ BUILD METHODS
  // =====================================================
  Widget _buildStatCard(String title, int count, IconData icon, Color color) {
    final isDark = context.isDarkMode;

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          Icon(icon, color: color, size: 24),
          const SizedBox(height: 4),
          Text(
            count.toString(),
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
          Text(
            title,
            style: TextStyle(
              fontSize: 12,
              color: isDark ? Colors.white60 : Colors.grey[600],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAppointmentCard(Map<String, dynamic> appointment, bool isToday) {
    final isDark = context.isDarkMode;
    final status = appointment['status'];
    final isInProgress = status == 'in_progress';
    final isCompleted = status == 'completed';
    final isCancelled = status == 'cancelled';
    final isVip = appointment['is_vip'] ?? false;
    final displayQueue = appointment['display_queue'] ?? '';
    final queuePosition = appointment['queue_position'];
    final displayTime = appointment['display_time'];
    final hasEstimatedTime =
        appointment['estimated_start_time'].isNotEmpty &&
        appointment['estimated_start_time'] != appointment['local_start_time'];

    final symbol = _currencySymbol(appointment['currency_code'] as String?);
    final totalPrice = (appointment['price'] as num?)?.toDouble() ?? 0;
    final extraCharge = (appointment['extra_charge'] as num?)?.toDouble() ?? 0;
    final services = (appointment['services'] as List?) ?? [];
    final isLocked = isCompleted || isCancelled;

    Color statusColor;
    String statusText;
    IconData statusIcon;

    switch (status) {
      case 'confirmed':
        statusColor = Colors.green;
        statusText = 'Confirmed';
        statusIcon = Icons.check_circle_outline;
        break;
      case 'pending':
        statusColor = Colors.orange;
        statusText = 'Pending';
        statusIcon = Icons.pending_outlined;
        break;
      case 'in_progress':
        statusColor = Colors.blue;
        statusText = 'In Progress';
        statusIcon = Icons.play_circle_outline;
        break;
      case 'completed':
        statusColor = Colors.purple;
        statusText = 'Completed';
        statusIcon = Icons.check_circle;
        break;
      case 'cancelled':
        statusColor = Colors.red;
        statusText = 'Cancelled';
        statusIcon = Icons.cancel_outlined;
        break;
      default:
        statusColor = Colors.grey;
        statusText = status;
        statusIcon = Icons.circle_outlined;
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: isInProgress
            ? const BorderSide(color: Colors.blue, width: 2)
            : (isVip
                  ? BorderSide(color: _vipColor, width: 1)
                  : BorderSide.none),
      ),
      child: Container(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: isVip
                        ? _vipColor.withValues(alpha: 0.1)
                        : _primaryColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (hasEstimatedTime)
                        Icon(Icons.schedule, size: 12, color: _warningColor),
                      if (hasEstimatedTime) const SizedBox(width: 4),
                      Text(
                        displayTime,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: isVip ? _vipColor : _primaryColor,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                if (isVip)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: _vipColor,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.star, size: 12, color: Colors.white),
                        SizedBox(width: 4),
                        Text(
                          'VIP',
                          style: TextStyle(
                            fontSize: 10,
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                const Spacer(),
                if (displayQueue.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: isVip
                          ? _vipColor.withValues(alpha: 0.1)
                          : (isDark ? Colors.grey[800] : Colors.grey[200]),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      displayQueue,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: isVip
                            ? _vipColor
                            : (isDark ? Colors.white70 : Colors.grey[700]),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),

            // Customer info
            Row(
              children: [
                CircleAvatar(
                  radius: 20,
                  backgroundColor: isVip
                      ? _vipColor.withValues(alpha: 0.1)
                      : _primaryColor.withValues(alpha: 0.1),
                  backgroundImage: appointment['customer_avatar'] != null
                      ? NetworkImage(appointment['customer_avatar'])
                      : null,
                  child: appointment['customer_avatar'] == null
                      ? Text(
                          (appointment['customer_name'][0]).toUpperCase(),
                          style: TextStyle(
                            fontSize: 16,
                            color: isVip ? _vipColor : _primaryColor,
                          ),
                        )
                      : null,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        appointment['customer_name'],
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                          color: context.textColor,
                        ),
                      ),
                      if (appointment['child_name'] != null &&
                          appointment['child_name'].toString().isNotEmpty)
                        Text(
                          'Booked for: ${appointment['child_name']}',
                          style: TextStyle(
                            fontSize: 12,
                            color: context.secondaryTextColor,
                          ),
                        ),
                      Row(
                        children: [
                          Icon(statusIcon, size: 12, color: statusColor),
                          const SizedBox(width: 4),
                          Text(
                            statusText,
                            style: TextStyle(
                              fontSize: 11,
                              color: statusColor,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: Icon(
                    Icons.info_outline,
                    color: context.secondaryTextColor,
                    size: 20,
                  ),
                  onPressed: () => _showCustomerInfo(appointment),
                  tooltip: 'Customer Info',
                ),
              ],
            ),
            const SizedBox(height: 12),

            // ✅ Services section
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF2A2A2A) : Colors.grey[50],
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: isDark ? Colors.grey[800]! : Colors.grey[200]!,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.content_cut, size: 12, color: _primaryColor),
                      const SizedBox(width: 6),
                      Text(
                        'Services (${services.length})',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: context.secondaryTextColor,
                        ),
                      ),
                      const Spacer(),
                      if (!isLocked)
                        TextButton.icon(
                          onPressed: () =>
                              _showManageServicesSheet(appointment),
                          icon: const Icon(Icons.edit, size: 14),
                          label: const Text(
                            'Manage',
                            style: TextStyle(fontSize: 11),
                          ),
                          style: TextButton.styleFrom(
                            foregroundColor: _primaryColor,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                    ],
                  ),
                  if (services.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Text(
                        'No services',
                        style: TextStyle(
                          fontSize: 12,
                          color: context.secondaryTextColor,
                        ),
                      ),
                    )
                  else
                    ...services.take(3).map((s) {
                      final price = (s['final_price'] as num?)?.toDouble() ?? 0;
                      final hasDiscount =
                          ((s['discount_amount'] as num?)?.toDouble() ?? 0) > 0;
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                '• ${s['service_name']}',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: context.textColor,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (hasDiscount)
                              Icon(
                                Icons.local_offer,
                                size: 10,
                                color: _secondaryColor,
                              ),
                            const SizedBox(width: 4),
                            Text(
                              '$symbol${price.toStringAsFixed(2)}',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                                color: hasDiscount
                                    ? _secondaryColor
                                    : context.textColor,
                              ),
                            ),
                          ],
                        ),
                      );
                    }),
                  if (services.length > 3)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        '+${services.length - 3} more service${services.length - 3 > 1 ? 's' : ''}',
                        style: TextStyle(
                          fontSize: 11,
                          fontStyle: FontStyle.italic,
                          color: context.secondaryTextColor,
                        ),
                      ),
                    ),

                  if (extraCharge > 0) ...[
                    const Divider(height: 12),
                    Row(
                      children: [
                        Icon(Icons.add_circle, size: 12, color: _warningColor),
                        const SizedBox(width: 4),
                        Text(
                          'Extra Charge',
                          style: TextStyle(fontSize: 11, color: _warningColor),
                        ),
                        const Spacer(),
                        Text(
                          '+$symbol${extraCharge.toStringAsFixed(2)}',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: _warningColor,
                          ),
                        ),
                      ],
                    ),
                  ],

                  const Divider(height: 12),

                  Row(
                    children: [
                      Text(
                        'Total',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: context.textColor,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        '$symbol${totalPrice.toStringAsFixed(2)}',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: isVip ? _vipColor : _primaryColor,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            const SizedBox(height: 12),

            // Action buttons
            if (isToday && !isCancelled && !isCompleted)
              Row(
                children: [
                  if (!isInProgress)
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: _isProcessing
                            ? null
                            : () => _startAppointment(appointment),
                        icon: const Icon(Icons.play_arrow, size: 18),
                        label: const Text('START'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _secondaryColor,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 10),
                        ),
                      ),
                    ),
                  if (isInProgress)
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: _isProcessing
                            ? null
                            : () => _endAppointment(appointment),
                        icon: const Icon(Icons.check, size: 18),
                        label: const Text('END'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _secondaryColor,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 10),
                        ),
                      ),
                    ),
                  const SizedBox(width: 12),
                  if (!isInProgress)
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _isProcessing
                            ? null
                            : () => _cancelAppointment(appointment),
                        icon: const Icon(Icons.close, size: 18),
                        label: const Text('CANCEL'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: _dangerColor,
                          side: BorderSide(color: _dangerColor),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 10),
                        ),
                      ),
                    ),
                ],
              ),
            if (!isToday && isCompleted)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: _secondaryColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.check_circle,
                        size: 16,
                        color: _secondaryColor,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Completed on ${appointment['date_display']}',
                        style: TextStyle(fontSize: 12, color: _secondaryColor),
                      ),
                    ],
                  ),
                ),
              ),
            if (!isToday && isCancelled)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: _dangerColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.cancel, size: 16, color: _dangerColor),
                      const SizedBox(width: 8),
                      Text(
                        'Cancelled',
                        style: TextStyle(fontSize: 12, color: _dangerColor),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildAppointmentList(
    List<Map<String, dynamic>> appointments, {
    required bool isToday,
  }) {
    final isDark = context.isDarkMode;

    if (appointments.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.event_busy,
              size: 64,
              color: isDark ? Colors.white30 : Colors.grey[300],
            ),
            const SizedBox(height: 16),
            Text(
              isToday ? 'No appointments today' : 'No appointments found',
              style: TextStyle(
                fontSize: 16,
                color: isDark ? Colors.white70 : Colors.grey[500],
              ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadAppointments,
      color: _primaryColor,
      child: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: appointments.length,
        itemBuilder: (context, index) =>
            _buildAppointmentCard(appointments[index], isToday),
      ),
    );
  }

  // =====================================================
  // ✅ BUILD METHOD
  // =====================================================
  @override
  Widget build(BuildContext context) {
    final isDark = context.isDarkMode;
    final screenWidth = MediaQuery.of(context).size.width;
    final isWeb = screenWidth > 800;

    _checkScreenSize();

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF121212) : Colors.grey[100],
      appBar: AppBar(
        title: const Text(
          'My Appointments',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        backgroundColor: _primaryColor,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: isWeb,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
          tooltip: 'Back',
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.calendar_today, color: Colors.white),
            onPressed: _showDatePickerDialog,
            tooltip: 'Select Date',
          ),
        ],
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator(color: _primaryColor))
          : _error != null
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.error_outline,
                    size: 64,
                    color: isDark ? Colors.white30 : Colors.grey[400],
                  ),
                  const SizedBox(height: 16),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: isDark ? Colors.white60 : Colors.grey[600],
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: _checkBarberStatusAndLoad,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _primaryColor,
                    ),
                    child: const Text('Retry'),
                  ),
                  if (!_isBarberActive)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: TextButton(
                        onPressed: () => context.go('/login'),
                        child: Text(
                          'Go to Login',
                          style: TextStyle(
                            color: isDark ? Colors.white60 : Colors.blue,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            )
          : isWeb
          ? _buildWebLayout()
          : _buildMobileLayout(),
    );
  }

  Widget _buildWebLayout() {
    final isDark = context.isDarkMode;

    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 1000),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 20,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
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
              padding: const EdgeInsets.all(24),
              child: _buildContent(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMobileLayout() {
    final isDark = context.isDarkMode;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.05),
                  blurRadius: 4,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Row(
              children: [
                Icon(Icons.today, size: 20, color: _primaryColor),
                const SizedBox(width: 12),
                Text(
                  DateFormat('EEEE, MMM dd, yyyy').format(_selectedDate),
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: isDark ? Colors.white : Colors.black87,
                  ),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: _showDatePickerDialog,
                  icon: Icon(
                    Icons.edit_calendar,
                    size: 16,
                    color: _primaryColor,
                  ),
                  label: Text('Change', style: TextStyle(color: _primaryColor)),
                ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(
                child: _buildStatCard(
                  'Today',
                  _todayAppointments.length,
                  Icons.today,
                  _primaryColor,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildStatCard(
                  'Upcoming',
                  _upcomingAppointments.length,
                  Icons.calendar_month,
                  _warningColor,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildStatCard(
                  'Completed',
                  _pastAppointments
                      .where((a) => a['status'] == 'completed')
                      .length,
                  Icons.check_circle,
                  _secondaryColor,
                ),
              ),
            ],
          ),
        ),
        TabBar(
          controller: _tabController,
          labelColor: _primaryColor,
          unselectedLabelColor: Colors.grey,
          indicatorColor: _primaryColor,
          tabs: const [
            Tab(text: 'TODAY'),
            Tab(text: 'UPCOMING'),
            Tab(text: 'PAST'),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              _buildAppointmentList(_todayAppointments, isToday: true),
              _buildAppointmentList(_upcomingAppointments, isToday: false),
              _buildAppointmentList(_pastAppointments, isToday: false),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildContent() {
    final isDark = context.isDarkMode;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.05),
                blurRadius: 4,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            children: [
              Icon(Icons.today, size: 20, color: _primaryColor),
              const SizedBox(width: 12),
              Text(
                DateFormat('EEEE, MMM dd, yyyy').format(_selectedDate),
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.white : Colors.black87,
                ),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: _showDatePickerDialog,
                icon: Icon(Icons.edit_calendar, size: 16, color: _primaryColor),
                label: Text('Change', style: TextStyle(color: _primaryColor)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: _buildStatCard(
                'Today',
                _todayAppointments.length,
                Icons.today,
                _primaryColor,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _buildStatCard(
                'Upcoming',
                _upcomingAppointments.length,
                Icons.calendar_month,
                _warningColor,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _buildStatCard(
                'Completed',
                _pastAppointments
                    .where((a) => a['status'] == 'completed')
                    .length,
                Icons.check_circle,
                _secondaryColor,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Container(
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.05),
                blurRadius: 4,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: TabBar(
            controller: _tabController,
            labelColor: _primaryColor,
            unselectedLabelColor: Colors.grey,
            indicatorColor: _primaryColor,
            indicatorSize: TabBarIndicatorSize.tab,
            labelStyle: const TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 14,
            ),
            tabs: const [
              Tab(text: '📅 TODAY'),
              Tab(text: '📆 UPCOMING'),
              Tab(text: '📋 PAST'),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Container(
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.05),
                blurRadius: 4,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: SizedBox(
            height: MediaQuery.of(context).size.height * 0.6,
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildAppointmentList(_todayAppointments, isToday: true),
                _buildAppointmentList(_upcomingAppointments, isToday: false),
                _buildAppointmentList(_pastAppointments, isToday: false),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
