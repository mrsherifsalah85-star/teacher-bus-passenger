import 'dart:async';
import 'dart:convert';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:permission_handler/permission_handler.dart';

const String projectId = 'car-tracking-5ef70';
const String apiKey = 'AIzaSyDn7mzRrWvCeEyCdq_O0p-Aq1aOGWsT8ok';

void main() => runApp(const PassengerApp());

class PassengerApp extends StatelessWidget {
  const PassengerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'راكب الباص',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1A237E)),
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
  final AudioPlayer _player = AudioPlayer();
  final MapController _mapCtrl = MapController();
  StreamSubscription<Position>? _posSub;
  Timer? _timer;
  Timer? _alarmStop;
  Position? _me;
  LatLng? _bus;
  List<LatLng> _route = [];
  bool _centered = false;
  int _alertMin = 15;
  bool _watching = false;
  bool _alerted = false;
  bool _alarmOn = false;
  String _status = 'اختار الوقت واضغط "ابدأ المتابعة". بعدها تقدر تقفل الشاشة.';
  String _eta = '';

  double? _num(dynamic v) {
    if (v == null) return null;
    final d = v['doubleValue'];
    if (d != null) return (d as num).toDouble();
    final i = v['integerValue'];
    if (i != null) return double.tryParse(i.toString());
    return null;
  }

  Future<void> _start() async {
    final code = _car.text.trim();
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

    final settings = AndroidSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 0,
      intervalDuration: const Duration(seconds: 10),
      foregroundNotificationConfig: const ForegroundNotificationConfig(
        notificationTitle: 'متابعة الباص شغالة',
        notificationText: 'هنبّهك قبل ما الباص يوصل',
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
      _centered = false;
      _status = 'جارٍ المتابعة...';
    });
    _check();
  }

  Future<void> _check() async {
    final code = _car.text.trim();
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

      final me = _me;
      if (me == null) {
        _setStatus('الباص شغال ✅ — بحدد موقعك...', '');
        return;
      }
      final r = await http.get(Uri.parse(
        'https://router.project-osrm.org/route/v1/driving/'
        '$lng,$lat;${me.longitude},${me.latitude}?overview=full&geometries=geojson',
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
      _setStatus('الباص شغال ✅', 'الوقت المتوقع: $mins دقيقة  •  المسافة: $km كم');

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
    await _posSub?.cancel();
    _posSub = null;
    _timer?.cancel();
    _timer = null;
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
    super.dispose();
  }

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

    return Scaffold(
      appBar: AppBar(
        title: const Text('🧭 راكب الباص'),
        backgroundColor: const Color(0xFF1A237E),
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
            child: Row(
              children: [
                Expanded(
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
                const SizedBox(width: 10),
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
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: _watching ? _stop : _start,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _watching ? Colors.red.shade700 : Colors.green.shade700,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: Text(
                  _watching ? 'إيقاف المتابعة' : 'ابدأ المتابعة',
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ),
          if (_alarmOn)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
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
            child: FlutterMap(
              mapController: _mapCtrl,
              options: const MapOptions(
                initialCenter: LatLng(30.0444, 31.2357),
                initialZoom: 13,
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.teacherbus.teacher_bus_passenger',
                ),
                PolylineLayer(
                  polylines: [
                    if (_route.isNotEmpty)
                      Polyline(points: _route, strokeWidth: 5, color: Colors.green),
                  ],
                ),
                MarkerLayer(markers: markers),
              ],
            ),
          ),
          Container(
            width: double.infinity,
            color: const Color(0xFFF3F4FB),
            padding: const EdgeInsets.all(12),
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
                          fontSize: 17, fontWeight: FontWeight.bold, color: Color(0xFF2E7D32)),
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
