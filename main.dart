import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String projectId = 'car-tracking-5ef70';
const String apiKey = 'AIzaSyDn7mzRrWvCeEyCdq_O0p-Aq1aOGWsT8ok';
const String ridersCol = 'riders_69c0006e66edbeb4';

const Color kGreen = Color(0xFF2E7D32);
const Color kBlue = Color(0xFF1A237E);
const Color kBg = Color(0xFFF3F4FB);

void main() => runApp(const PassengerApp());

class PassengerApp extends StatelessWidget {
  const PassengerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'راكب الباص',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: kBlue),
        scaffoldBackgroundColor: kBg,
        useMaterial3: true,
      ),
      builder: (context, child) =>
          Directionality(textDirection: TextDirection.rtl, child: child!),
      home: const PassengerPage(),
    );
  }
}

class PassengerPage extends StatefulWidget {
  const PassengerPage({super.key});

  @override
  State<PassengerPage> createState() => _PassengerPageState();
}

class _PassengerPageState extends State<PassengerPage> {
  final TextEditingController _car = TextEditingController(text: 'car-001');
  final TextEditingController _name = TextEditingController();
  final AudioPlayer _player = AudioPlayer();
  final MapController _mapCtrl = MapController();
  final FlutterLocalNotificationsPlugin _notif = FlutterLocalNotificationsPlugin();
  StreamSubscription<Position>? _posSub;
  Timer? _timer;
  Timer? _alarmStop;
  Position? _me;
  LatLng? _bus;
  LatLng? _station;
  List<LatLng> _route = [];
  String _riderId = '';
  bool? _busActive;
  bool _choosing = false;
  bool _centered = false;
  int _alertMin = 15;
  bool _watching = false;
  bool _alerted = false;
  bool _alarmOn = false;
  String _status = 'اكتب اسمك، واختار الوقت، واضغط "ابدأ المتابعة". بعدها تقدر تقفل الشاشة.';
  String _eta = '';

  @override
  void initState() {
    super.initState();
    _loadPrefs();
    _initNotif();
  }

  Future<void> _initNotif() async {
    try {
      await _notif.initialize(const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ));
    } catch (_) {}
  }

  Future<void> _notifyTripStarted() async {
    try {
      await _notif.show(
        1,
        'الباص بدأ الرحلة 🚌',
        'افتح التطبيق وتابع وصوله.',
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'trip_started',
            'بدء الرحلة',
            importance: Importance.max,
            priority: Priority.high,
          ),
        ),
      );
    } catch (_) {}
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString('rider_id');
    if (id == null) {
      id = 'r${DateTime.now().millisecondsSinceEpoch}${Random().nextInt(99999)}';
      await prefs.setString('rider_id', id);
    }
    final name = prefs.getString('rider_name') ?? '';
    final la = prefs.getDouble('station_lat');
    final ln = prefs.getDouble('station_lng');
    if (!mounted) return;
    setState(() {
      _riderId = id!;
      _name.text = name;
      if (la != null && ln != null) _station = LatLng(la, ln);
    });
    if (_station != null) {
      try {
        _mapCtrl.move(_station!, 15);
      } catch (_) {}
    }
  }

  Future<void> _saveStation(LatLng p) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('station_lat', p.latitude);
    await prefs.setDouble('station_lng', p.longitude);
    if (!mounted) return;
    setState(() {
      _station = p;
      _choosing = false;
      _route = [];
      _status = 'اتحفظت محطتك ✅';
    });
    if (_watching) _check();
  }

  Future<void> _clearStation() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('station_lat');
    await prefs.remove('station_lng');
    if (!mounted) return;
    setState(() {
      _station = null;
      _route = [];
      _status = 'اتمسحت المحطة. هيتحسب الوقت لموقعك الحالي.';
    });
  }

  Future<void> _useMyLocation() async {
    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
        setState(() => _status = 'لازم تسمح للتطبيق بالوصول للموقع.');
        return;
      }
      setState(() => _status = 'بحدد موقعك...');
      final p = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      ).timeout(const Duration(seconds: 20));
      final pt = LatLng(p.latitude, p.longitude);
      await _saveStation(pt);
      try {
        _mapCtrl.move(pt, 16);
      } catch (_) {}
    } catch (_) {
      if (!mounted) return;
      setState(() => _status = 'مقدرتش أحدد موقعك. جرب تاني أو اختار من الخريطة.');
    }
  }

  double? _num(dynamic v) {
    if (v == null) return null;
    final d = v['doubleValue'];
    if (d != null) return (d as num).toDouble();
    final i = v['integerValue'];
    if (i != null) return double.tryParse(i.toString());
    return null;
  }

  Future<void> _sendRider({required bool active}) async {
    final name = _name.text.trim();
    if (name.isEmpty || _riderId.isEmpty) return;
    try {
      final fields = <String, dynamic>{
        'name': {'stringValue': name},
        'active': {'booleanValue': active},
        'updated': {'timestampValue': DateTime.now().toUtc().toIso8601String()},
      };
      final mask = <String>['name', 'active', 'updated', 'lat', 'lng', 'stLat', 'stLng'];
      final me = _me;
      if (me != null) {
        fields['lat'] = {'doubleValue': me.latitude};
        fields['lng'] = {'doubleValue': me.longitude};
      }
      final st = _station;
      if (st != null) {
        fields['stLat'] = {'doubleValue': st.latitude};
        fields['stLng'] = {'doubleValue': st.longitude};
      }
      await http.patch(
        Uri.https(
          'firestore.googleapis.com',
          '/v1/projects/$projectId/databases/(default)/documents/$ridersCol/$_riderId',
          {'updateMask.fieldPaths': mask, 'key': apiKey},
        ),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'fields': fields}),
      );
    } catch (_) {}
  }

  Future<void> _start() async {
    final code = _car.text.trim();
    if (_name.text.trim().isEmpty) {
      setState(() => _status = 'اكتب اسمك الأول عشان السائق يعرفك.');
      return;
    }
    if (code.isEmpty) {
      setState(() => _status = 'اكتب كود السيارة الأول.');
      return;
    }
    if (!await Geolocator.isLocationServiceEnabled()) {
      setState(() => _status = 'شغّل الـ GPS من إعدادات الموبايل وجرب تاني.');
      return;
    }
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
      setState(() => _status = 'لازم تسمح للتطبيق بالوصول للموقع. هفتحلك الإعدادات.');
      await openAppSettings();
      return;
    }
    await Permission.notification.request();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('rider_name', _name.text.trim());

    final settings = AndroidSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 0,
      intervalDuration: const Duration(seconds: 10),
      foregroundNotificationConfig: const ForegroundNotificationConfig(
        notificationTitle: 'متابعة الباص شغالة',
        notificationText: 'هنبّهك لما الباص يبدأ ويقرب',
        enableWakeLock: true,
        setOngoing: true,
      ),
    );

    _posSub = Geolocator.getPositionStream(locationSettings: settings).listen(
      (p) {
        if (!mounted) return;
        setState(() => _me = p);
      },
      onError: (e) {
        if (!mounted) return;
        setState(() => _status = 'مشكلة في قراءة موقعك: $e');
      },
    );
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => _check());
    setState(() {
      _watching = true;
      _alerted = false;
      _busActive = null;
      _centered = false;
      _status = 'جارٍ المتابعة...';
    });
    _check();
  }

  Future<void> _check() async {
    final code = _car.text.trim();
    await _sendRider(active: true);
    try {
      final res = await http.get(Uri.https(
        'firestore.googleapis.com',
        '/v1/projects/$projectId/databases/(default)/documents/tracking/$code',
        {'key': apiKey},
      ));
      if (res.statusCode == 404) {
        _setStatus('مفيش بيانات للكود ده.', '', clearBus: true);
        return;
      }
      if (res.statusCode != 200) {
        _setStatus('مشكلة في الاتصال. هحاول تاني.', '');
        return;
      }
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final f = (body['fields'] as Map<String, dynamic>?) ?? {};
      final active = f['active']?['booleanValue'] == true;
      final wasActive = _busActive;
      _busActive = active;
      if (active && wasActive == false) {
        await _notifyTripStarted();
      }
      final lat = _num(f['lat']);
      final lng = _num(f['lng']);
      if (!active || lat == null || lng == null || (lat == 0 && lng == 0)) {
        _setStatus('الباص مش شغال حاليًا. هنبّهك أول ما يبدأ.', '', clearBus: true);
        return;
      }

      final busPos = LatLng(lat, lng);
      if (mounted) setState(() => _bus = busPos);
      if (!_centered) {
        _centered = true;
        try {
          _mapCtrl.move(busPos, 15);
        } catch (_) {}
      }

      final LatLng? target = _station ??
          (_me == null ? null : LatLng(_me!.latitude, _me!.longitude));
      if (target == null) {
        _setStatus('الباص شغال ✅ — بحدد موقعك...', '');
        return;
      }
      final r = await http.get(Uri.parse(
        'https://router.project-osrm.org/route/v1/driving/'
        '$lng,$lat;${target.longitude},${target.latitude}?overview=full&geometries=geojson',
      ));
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      if (j['code'] != 'Ok') {
        _setStatus('الباص شغال ✅ — تعذر حساب المسافة.', '');
        return;
      }
      final route = (j['routes'] as List).first as Map<String, dynamic>;
      final coords = (route['geometry']['coordinates'] as List)
          .map((c) => LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()))
          .toList();
      final mins = ((route['duration'] as num) / 60).round();
      final km = ((route['distance'] as num) / 1000).toStringAsFixed(1);
      if (mounted) setState(() => _route = coords);
      final toWhere = _station != null ? ' لمحطتك' : '';
      _setStatus('الباص شغال ✅', 'الوقت المتوقع$toWhere: $mins دقيقة  •  المسافة: $km كم');

      if (mins <= _alertMin && !_alerted) {
        _alerted = true;
        await _startAlarm();
      } else if (mins > _alertMin + 1) {
        _alerted = false;
      }
    } catch (_) {
      _setStatus('مشكلة في النت. هحاول تاني.', '');
    }
  }

  void _setStatus(String s, String eta, {bool clearBus = false}) {
    if (!mounted) return;
    setState(() {
      _status = s;
      _eta = eta;
      if (clearBus) {
        _bus = null;
        _route = [];
      }
    });
  }

  Future<void> _startAlarm() async {
    if (_alarmOn) return;
    setState(() => _alarmOn = true);
    await _player.setReleaseMode(ReleaseMode.loop);
    await _player.play(AssetSource('alarm.wav'));
    _alarmStop?.cancel();
    _alarmStop = Timer(const Duration(seconds: 90), _stopAlarm);
  }

  Future<void> _stopAlarm() async {
    _alarmStop?.cancel();
    await _player.stop();
    if (!mounted) return;
    setState(() => _alarmOn = false);
  }

  Future<void> _stop() async {
    _timer?.cancel();
    _timer = null;
    await _sendRider(active: false);
    await _posSub?.cancel();
    _posSub = null;
    await _stopAlarm();
    if (!mounted) return;
    setState(() {
      _watching = false;
      _eta = '';
      _bus = null;
      _route = [];
      _status = 'المتابعة اتوقفت.';
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _alarmStop?.cancel();
    _posSub?.cancel();
    _player.dispose();
    _car.dispose();
    _name.dispose();
    super.dispose();
  }

  BoxDecoration get _card => BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [BoxShadow(color: Color(0x14000000), blurRadius: 8)],
      );

  @override
  Widget build(BuildContext context) {
    final markers = <Marker>[];
    if (_bus != null) {
      markers.add(Marker(
        point: _bus!,
        width: 44,
        height: 44,
        child: const Text('🚌', style: TextStyle(fontSize: 34)),
      ));
    }
    if (_me != null) {
      markers.add(Marker(
        point: LatLng(_me!.latitude, _me!.longitude),
        width: 40,
        height: 40,
        child: const Text('📍', style: TextStyle(fontSize: 30)),
      ));
    }
    if (_station != null) {
      markers.add(Marker(
        point: _station!,
        width: 44,
        height: 44,
        child: const Text('🚏', style: TextStyle(fontSize: 32)),
      ));
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('🧭 راكب الباص'),
        backgroundColor: kGreen,
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
          Container(
            margin: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            padding: const EdgeInsets.all(12),
            decoration: _card,
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: TextField(
                        controller: _name,
                        enabled: !_watching,
                        decoration: const InputDecoration(
                          labelText: 'اسمك',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 2,
                      child: TextField(
                        controller: _car,
                        enabled: !_watching,
                        textAlign: TextAlign.center,
                        decoration: const InputDecoration(
                          labelText: 'كود السيارة',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<int>(
                        value: _alertMin,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'نبّهني قبل',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        items: const [
                          DropdownMenuItem(value: 15, child: Text('15 دقيقة')),
                          DropdownMenuItem(value: 10, child: Text('10 دقايق')),
                          DropdownMenuItem(value: 5, child: Text('5 دقايق')),
                          DropdownMenuItem(value: 3, child: Text('3 دقايق')),
                          DropdownMenuItem(value: 1, child: Text('دقيقة')),
                        ],
                        onChanged: _watching ? null : (v) => setState(() => _alertMin = v ?? 15),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: SizedBox(
                        height: 48,
                        child: ElevatedButton(
                          onPressed: _watching ? _stop : _start,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _watching ? Colors.red.shade700 : kGreen,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                          child: Text(
                            _watching ? 'إيقاف' : 'ابدأ المتابعة',
                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    OutlinedButton(
                      onPressed: () => setState(() {
                        _choosing = !_choosing;
                        if (_choosing) _status = 'اضغط على الخريطة في مكان محطتك.';
                      }),
                      child: Text(_choosing ? 'إلغاء' : '🚏 حدد محطتي'),
                    ),
                    OutlinedButton(
                      onPressed: _useMyLocation,
                      child: const Text('📍 محطتي هنا'),
                    ),
                    if (_station != null)
                      OutlinedButton(
                        onPressed: _clearStation,
                        child: const Text('مسح المحطة'),
                      ),
                  ],
                ),
              ],
            ),
          ),
          if (_alarmOn)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: _stopAlarm,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                    foregroundColor: Colors.white,
                  ),
                  child: const Text('🔕 إيقاف صوت التنبيه',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                ),
              ),
            ),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: FlutterMap(
                mapController: _mapCtrl,
                options: MapOptions(
                  initialCenter: _station ?? const LatLng(31.2, 29.95),
                  initialZoom: 13,
                  onTap: (tapPos, point) {
                    if (_choosing) _saveStation(point);
                  },
                ),
                children: [
                  TileLayer(
                    urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: 'com.teacherbus.teacher_bus_passenger',
                  ),
                  PolylineLayer(
                    polylines: [
                      if (_route.isNotEmpty)
                        Polyline(points: _route, strokeWidth: 5, color: kGreen),
                    ],
                  ),
                  MarkerLayer(markers: markers),
                ],
              ),
            ),
          ),
          Container(
            width: double.infinity,
            margin: const EdgeInsets.all(12),
            padding: const EdgeInsets.all(12),
            decoration: _card,
            child: Column(
              children: [
                Text(_status, textAlign: TextAlign.center, style: const TextStyle(fontSize: 15)),
                if (_eta.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      _eta,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontSize: 17, fontWeight: FontWeight.bold, color: kGreen),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
