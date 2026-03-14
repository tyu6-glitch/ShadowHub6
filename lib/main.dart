import 'package:flutter/material.dart';
import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'dart:typed_data'; 
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_mjpeg/flutter_mjpeg.dart'; 

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]).then((_) {
    runApp(const ShadowHubApp());
  });
}

class ShadowHubApp extends StatelessWidget {
  const ShadowHubApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(scaffoldBackgroundColor: const Color(0xFF0B0C10)),
      home: const MainScreen(),
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});
  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _currentIndex = 4;
  String deviceIp = ""; 
  List<Map<String, String>> customApps = [];
  
  final TextEditingController _keyboardController = TextEditingController();
  final FocusNode _keyboardFocus = FocusNode();
  String _lastText = ""; 

  bool isStreamDeckMode = false;
  bool isMonitorMode = false; 
  bool isScanning = false; 
  bool isWifiSelected = true; 

  String connectionStatus = "لم يتم الاتصال";
  Color statusColor = Colors.grey;
  String cpuUsage = "0";
  String ramUsage = "0";
  Timer? _monitorTimer;
  bool isSyncing = false;

  // مسار الاتصال المزدوج
  Socket? _wifiCmdSocket; 
  
  // مسار الـ USB (سيرفرات)
  ServerSocket? _usbCmdServer;
  Socket? _usbActiveCmdSocket;
  ServerSocket? _usbVideoServer;
  Socket? _usbActiveVideoSocket;
  
  Uint8List? _currentFrame;
  final BytesBuilder _videoBuffer = BytesBuilder();
  int _expectedFrameSize = 0;
  bool isIosUsbMode = false; 

  double floatingX = 20.0;
  double floatingY = 100.0;
  double savedPortraitX = 20.0;
  double savedPortraitY = 100.0;
  Offset? _lastTouchPosition;

  @override
  void dispose() {
    _monitorTimer?.cancel();
    _wifiCmdSocket?.close(); 
    _usbCmdServer?.close();
    _stopUsbVideoStream();
    super.dispose();
  }

  // ==========================================
  // 1. نظام إرسال الأوامر الموحد
  // ==========================================
  void sendCommand(String command) {
    if (isIosUsbMode) {
      if (_usbActiveCmdSocket != null) {
        try { _usbActiveCmdSocket!.write("$command\n"); } catch (e) {}
      }
    } else {
      if (_wifiCmdSocket != null) {
        try { _wifiCmdSocket!.write("$command\n"); } catch (e) { _connectWifiCmd(); }
      }
    }
  }

  // ==========================================
  // 2. هندسة اتصال الواي فاي (الآيباد هو العميل ويستمع للرادار)
  // ==========================================
  Future<void> _connectWifiCmd() async {
    _wifiCmdSocket?.close();
    if (deviceIp.isEmpty) return;
    try {
      _wifiCmdSocket = await Socket.connect(deviceIp, 8888, timeout: const Duration(seconds: 2));
      _wifiCmdSocket?.setOption(SocketOption.tcpNoDelay, true);
    } catch (e) {}
  }

  Future<void> _startWifiDiscovery() async {
    try {
      // فتح الأذن على منفذ 5555 لسماع نداء الكمبيوتر
      RawDatagramSocket udpSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 5555);
      
      udpSocket.listen((RawSocketEvent event) {
        if (event == RawSocketEvent.read) {
          Datagram? dg = udpSocket.receive();
          if (dg != null) {
            String msg = utf8.decode(dg.data).trim();
            if (msg == "PC_SERVER_HERE") { // إذا سمع الآيباد نداء الكمبيوتر
              if (deviceIp.isEmpty && mounted) {
                setState(() {
                  deviceIp = dg.address.address; // التقاط آيبي الكمبيوتر فوراً
                  connectionStatus = "متصل عبر الواي فاي 📶";
                  statusColor = Colors.green;
                  isScanning = false;
                });
                startMonitor();
                _connectWifiCmd();
                udpSocket.close();
              }
            }
          }
        }
      });
      
      // ننتظر 3 ثواني، إذا ما سمعنا شيء يعني فشل
      await Future.delayed(const Duration(seconds: 3));
      udpSocket.close();
    } catch (e) {
      debugPrint("WiFi Scan Error: $e");
    }

    if (deviceIp.isEmpty && mounted) {
      setState(() { connectionStatus = "لم يتم العثور على الكمبيوتر ✗"; statusColor = Colors.red; isScanning = false; });
    }
  }

  // ==========================================
  // 3. هندسة اتصال الـ USB (الآيباد هو السيرفر وينتظر الهجوم)
  // ==========================================
  Future<void> _startUsbServers() async {
    try {
      _usbCmdServer?.close();
      _usbCmdServer = await ServerSocket.bind(InternetAddress.anyIPv4, 8080);
      _usbCmdServer!.listen((Socket socket) {
        setState(() {
          isIosUsbMode = true;
          deviceIp = "127.0.0.1";
          _usbActiveCmdSocket = socket;
          connectionStatus = "متصل عبر سلك الـ USB الخارق 🚀";
          statusColor = Colors.green;
          isScanning = false;
        });
        socket.listen((data) {}, onDone: _onUsbDisconnect, onError: (e) => _onUsbDisconnect());
      });

      _usbVideoServer?.close();
      _usbVideoServer = await ServerSocket.bind(InternetAddress.anyIPv4, 5001);
      _usbVideoServer!.listen((Socket socket) {
        _usbActiveVideoSocket = socket;
        socket.listen((Uint8List data) {
          _videoBuffer.add(data);
          _processVideoBuffer();
        }, onDone: _stopUsbVideoStream, onError: (e) => _stopUsbVideoStream());
      });
    } catch (e) {
      setState(() { connectionStatus = "خطأ في سيرفرات الـ USB: $e"; statusColor = Colors.red; isScanning = false; });
    }
  }

  void _onUsbDisconnect() {
    if (mounted) {
      setState(() { connectionStatus = "تم فصل سلك الـ USB ✗"; statusColor = Colors.red; _usbActiveCmdSocket = null; });
    }
    _stopUsbVideoStream();
  }

  void _processVideoBuffer() {
    var bytes = _videoBuffer.takeBytes(); 
    int offset = 0;
    Uint8List? latestFrame; 
    while (true) {
      if (_expectedFrameSize == 0 && (bytes.length - offset) >= 4) {
        _expectedFrameSize = ByteData.sublistView(bytes, offset, offset + 4).getUint32(0, Endian.big);
        offset += 4;
      }
      if (_expectedFrameSize > 0 && (bytes.length - offset) >= _expectedFrameSize) {
        latestFrame = bytes.sublist(offset, offset + _expectedFrameSize);
        offset += _expectedFrameSize;
        _expectedFrameSize = 0; 
      } else { break; }
    }
    if (latestFrame != null && mounted && isMonitorMode) {
      setState(() { _currentFrame = latestFrame; });
    }
    if (offset < bytes.length) _videoBuffer.add(bytes.sublist(offset));
  }

  void _stopUsbVideoStream() {
    _usbActiveVideoSocket?.close();
    _usbActiveVideoSocket = null;
    _videoBuffer.clear();
    _expectedFrameSize = 0;
    if (mounted) setState(() { _currentFrame = null; });
  }

  // ==========================================
  // الواجهة الرئيسية
  // ==========================================
  Future<void> autoDiscoverPC() async {
    setState(() { isScanning = true; deviceIp = ""; });
    if (!isWifiSelected) {
      setState(() { connectionStatus = "جاري بناء النفق عبر السلك ⏳..."; statusColor = Colors.orange; });
      await _startUsbServers();
    } else {
      setState(() { connectionStatus = "جاري الاستماع للرادار 📶..."; statusColor = Colors.orange; });
      await _startWifiDiscovery();
    }
  }

  void startMonitor() {
    _monitorTimer?.cancel();
    if (deviceIp.isEmpty || isIosUsbMode) return; 
    _monitorTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      try {
        final res = await http.get(Uri.parse('http://$deviceIp:5000/get_stats')).timeout(const Duration(seconds: 1));
        if (res.statusCode == 200) {
          final data = json.decode(res.body);
          if (mounted) setState(() {
            cpuUsage = (double.tryParse(data['cpu']?.toString() ?? '0') ?? 0.0).toStringAsFixed(1);
            ramUsage = (double.tryParse(data['ram']?.toString() ?? '0') ?? 0.0).toStringAsFixed(1);
          });
        }
      } catch (e) {}
    });
  }

  void stopMonitor() => _monitorTimer?.cancel();

  Future<void> syncApps() async {
    if (isIosUsbMode) {
      if (mounted) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("الرجاء استخدام الواي فاي لمرة واحدة لمزامنة التطبيقات."))); }
      return;
    }
    if (deviceIp.isEmpty) return; 
    setState(() => isSyncing = true);
    try {
      sendCommand("SYNC");
      await Future.delayed(const Duration(milliseconds: 1000));
      final res = await http.get(Uri.parse('http://$deviceIp:5000/get_all_data')).timeout(const Duration(seconds: 15)); 
      if (res.statusCode == 200) {
        final data = json.decode(utf8.decode(res.bodyBytes));
        String appsRaw = data['apps_raw'] ?? "";
        List<dynamic> icons = data['icons'] ?? [];
        if (appsRaw.isNotEmpty) {
          List<String> appNames = appsRaw.split('|');
          List<Map<String, String>> fetchedApps = [];
          for (int i = 0; i < appNames.length; i++) {
            if (appNames[i].trim().isNotEmpty) {
               String iconBase64 = "";
               if (i < icons.length && icons[i] != null) {
                 String rawIcon = icons[i].toString();
                 if (rawIcon.contains(",")) rawIcon = rawIcon.split(',')[1];
                 iconBase64 = rawIcon.replaceAll(RegExp(r'[^A-Za-z0-9+/=]'), '');
                 int padding = iconBase64.length % 4;
                 if (padding != 0) iconBase64 += '=' * (4 - padding); 
               }
               fetchedApps.add({"name": appNames[i], "icon": iconBase64, "index": i.toString()});
            }
          }
          if (mounted) setState(() => customApps = fetchedApps);
        }
      }
    } catch (e) {} finally { if (mounted) setState(() => isSyncing = false); }
  }

  void _exitFullScreenMode() {
    setState(() {
      if (isMonitorMode) { floatingX = savedPortraitX; floatingY = savedPortraitY; }
      isStreamDeckMode = false; isMonitorMode = false; _currentIndex = 4; 
    });
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    startMonitor();
  }

  @override
  Widget build(BuildContext context) {
    double keyboardHeight = MediaQuery.of(context).viewInsets.bottom;
    bool isKeyboardOpen = keyboardHeight > 0;
    double screenHeight = MediaQuery.of(context).size.height;
    double safeFloatingY = floatingY;
    if (isKeyboardOpen) {
      double maxSafeY = screenHeight - keyboardHeight - 80; 
      if (safeFloatingY > maxSafeY) safeFloatingY = maxSafeY;
    }

    Widget activeScreen;

    if (isMonitorMode) {
      activeScreen = Scaffold(
        resizeToAvoidBottomInset: false, backgroundColor: Colors.black,
        body: SafeArea(
          left: false, right: false, top: false, bottom: false,
          child: Stack(
            children: [
              Center(
                child: deviceIp.isEmpty 
                    ? const Text("الرجاء الاتصال بالكمبيوتر أولاً", style: TextStyle(color: Colors.white54, fontSize: 16))
                    // 🔥 السحر الهجين في عرض الفيديو 🔥
                    : (isIosUsbMode
                        ? (_currentFrame == null
                            ? const Text("جاري التقاط بث الـ USB الخارق...", style: TextStyle(color: Colors.white54, fontSize: 16))
                            : Image.memory(_currentFrame!, fit: BoxFit.contain, gaplessPlayback: true))
                        : Mjpeg(
                            isLive: true,
                            stream: 'http://$deviceIp:5000/video_feed',
                            fit: BoxFit.contain,
                            error: (context, error, stack) => const Text("فشل تحميل بث الواي فاي", style: TextStyle(color: Colors.red)),
                          )),
              ),
              Positioned(top: 20, left: 20, child: Container(decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(50)), child: IconButton(icon: const Icon(Icons.arrow_back, color: Colors.white, size: 30), onPressed: _exitFullScreenMode))),
            ],
          ),
        ),
      );
    } else if (isStreamDeckMode) {
      activeScreen = Scaffold(
        resizeToAvoidBottomInset: false, backgroundColor: Colors.black, 
        body: SafeArea(
          child: Stack(
            children: [
              GridView.builder(
                padding: const EdgeInsets.only(top: 80, left: 20, right: 20, bottom: 20),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 4, mainAxisSpacing: 15, crossAxisSpacing: 15),
                itemCount: customApps.length,
                itemBuilder: (context, index) {
                  var app = customApps[index];
                  return _buildAppItem(app['name']!, app['icon']!, "LAUNCH:${app['index']}");
                },
              ),
              Positioned(top: 10, left: 10, child: Container(decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(50)), child: IconButton(icon: const Icon(Icons.arrow_back, color: Colors.white, size: 30), onPressed: _exitFullScreenMode))),
            ],
          ),
        ),
      );
    } else {
      activeScreen = Scaffold(
        resizeToAvoidBottomInset: false, 
        appBar: AppBar(backgroundColor: const Color(0xFF15161E), title: const Text('ShadowHub', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)), centerTitle: true),
        body: IndexedStack(index: _currentIndex, children: [const SizedBox(), _buildMediaScreen(), _buildMouseScreen(), const SizedBox(), _buildSettingsScreen()]),
        bottomNavigationBar: BottomNavigationBar(
          backgroundColor: const Color(0xFF15161E), selectedItemColor: const Color(0xFFB829EA), unselectedItemColor: const Color(0xFF888B94), type: BottomNavigationBarType.fixed, currentIndex: _currentIndex,
          onTap: (index) {
            if (index == 0) {
              setState(() => isStreamDeckMode = true);
              SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
              stopMonitor(); 
            } else if (index == 3) {
              setState(() { isMonitorMode = true; savedPortraitX = floatingX; savedPortraitY = floatingY; floatingX = 20.0; floatingY = 180.0; });
              SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
              SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
              stopMonitor();
            } else {
              setState(() => _currentIndex = index);
              index == 4 ? startMonitor() : stopMonitor(); 
            }
          },
          items: const [
            BottomNavigationBarItem(icon: Icon(Icons.apps), label: 'StreamDeck'), BottomNavigationBarItem(icon: Icon(Icons.music_note), label: 'الميديا'),
            BottomNavigationBarItem(icon: Icon(Icons.mouse), label: 'الماوس'), BottomNavigationBarItem(icon: Icon(Icons.monitor), label: 'الشاشة'),
            BottomNavigationBarItem(icon: Icon(Icons.settings), label: 'الإعدادات'),
          ],
        ),
      );
    }

    return Material(
      type: MaterialType.transparency,
      child: Stack(
        children: [
          GestureDetector(
            onTap: () {
              if (isKeyboardOpen || _keyboardFocus.hasFocus) { FocusManager.instance.primaryFocus?.unfocus(); SystemChannels.textInput.invokeMethod('TextInput.hide'); }
            },
            behavior: HitTestBehavior.translucent, child: activeScreen,
          ),
          Positioned(
            top: 0, left: 0,
            child: Opacity(
              opacity: 0.0,
              child: SizedBox(
                width: 1, height: 1,
                child: TextField(
                  controller: _keyboardController, focusNode: _keyboardFocus, autocorrect: false, enableSuggestions: false, keyboardType: TextInputType.multiline, maxLines: null,
                  onChanged: (text) {
                    if (text.isNotEmpty && text.length > _lastText.length) {
                      String newChars = text.substring(_lastText.length);
                      for (int i = 0; i < newChars.length; i++) {
                        String char = newChars[i];
                        if (char == " ") sendCommand("K_SPACE"); 
                        else if (char == "\n") sendCommand("K_ENTER"); 
                        else sendCommand("K_TYPE:$char");
                      }
                    } else if (text.length < _lastText.length) {
                      for (int i = 0; i < (_lastText.length - text.length); i++) sendCommand("K_BACK"); 
                    }
                    _lastText = text;
                  },
                ),
              ),
            ),
          ),
          Positioned(
            left: floatingX, top: safeFloatingY, 
            child: GestureDetector(
              onPanUpdate: (details) { setState(() { floatingX += details.delta.dx; floatingY += details.delta.dy; }); },
              onTap: () {
                if (isKeyboardOpen || _keyboardFocus.hasFocus) { _keyboardFocus.unfocus(); SystemChannels.textInput.invokeMethod('TextInput.hide'); } 
                else { _keyboardFocus.requestFocus(); SystemChannels.textInput.invokeMethod('TextInput.show'); }
                HapticFeedback.lightImpact();
              },
              child: Container(padding: const EdgeInsets.all(15), decoration: BoxDecoration(color: Colors.white.withOpacity(0.5), shape: BoxShape.circle, boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.3), blurRadius: 10, offset: const Offset(0, 4))]), child: const Icon(Icons.keyboard, color: Colors.black, size: 30)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSettingsScreen() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(20), decoration: BoxDecoration(color: const Color(0xFF15161E), borderRadius: BorderRadius.circular(15), border: Border.all(color: const Color(0xFFB829EA).withOpacity(0.3))),
            child: Column(
              children: [
                const Text("طريقة الاتصال", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)), const SizedBox(height: 15),
                Row(
                  children: [
                    Expanded(child: GestureDetector(onTap: () => setState(() => isWifiSelected = true), child: Container(padding: const EdgeInsets.symmetric(vertical: 15), decoration: BoxDecoration(color: isWifiSelected ? const Color(0xFFB829EA) : const Color(0xFF0B0C10), borderRadius: BorderRadius.circular(10), border: Border.all(color: isWifiSelected ? const Color(0xFFB829EA) : Colors.grey.shade800)), child: Column(children: [Icon(Icons.wifi, color: isWifiSelected ? Colors.white : Colors.grey), const SizedBox(height: 5), Text("واي فاي", style: TextStyle(color: isWifiSelected ? Colors.white : Colors.grey, fontWeight: FontWeight.bold))])))),
                    const SizedBox(width: 15),
                    Expanded(child: GestureDetector(onTap: () => setState(() => isWifiSelected = false), child: Container(padding: const EdgeInsets.symmetric(vertical: 15), decoration: BoxDecoration(color: !isWifiSelected ? const Color(0xFFB829EA) : const Color(0xFF0B0C10), borderRadius: BorderRadius.circular(10), border: Border.all(color: !isWifiSelected ? const Color(0xFFB829EA) : Colors.grey.shade800)), child: Column(children: [Icon(Icons.usb, color: !isWifiSelected ? Colors.white : Colors.grey), const SizedBox(height: 5), Text("كيبل USB", style: TextStyle(color: !isWifiSelected ? Colors.white : Colors.grey, fontWeight: FontWeight.bold))])))),
                  ],
                ),
                const SizedBox(height: 20),
                ElevatedButton.icon(
                  onPressed: isScanning ? null : autoDiscoverPC,
                  icon: isScanning ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)) : const Icon(Icons.radar, color: Colors.white),
                  label: Text(isScanning ? 'جاري الاتصال...' : 'اتصال بالكمبيوتر الآن', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFB829EA), foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 15), minimumSize: const Size(double.infinity, 55)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 15),
          Center(child: Text(connectionStatus, textAlign: TextAlign.center, style: TextStyle(color: statusColor, fontWeight: FontWeight.bold, fontSize: 14))),
          const Divider(height: 40, color: Colors.grey),
          const Text("مراقب النظام (Live)", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)), const SizedBox(height: 15),
          Row(children: [Expanded(child: _buildMonitorCard("المعالج (CPU)", "$cpuUsage%", Icons.memory, Colors.blue)), const SizedBox(width: 15), Expanded(child: _buildMonitorCard("الرام (RAM)", "$ramUsage%", Icons.storage, Colors.green))]),
          const Divider(height: 40, color: Colors.grey),
          ElevatedButton.icon(
            onPressed: syncApps,
            icon: isSyncing ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)) : const Icon(Icons.sync),
            label: const Text('مزامنة التطبيقات والأيقونات'),
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF2A2C38), foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 15)),
          ),
        ],
      ),
    );
  }

  Widget _buildMonitorCard(String title, String value, IconData icon, Color color) {
    return Container(padding: const EdgeInsets.all(15), decoration: BoxDecoration(color: const Color(0xFF15161E), borderRadius: BorderRadius.circular(15)), child: Column(children: [Icon(icon, color: color, size: 40), const SizedBox(height: 10), Text(title, style: const TextStyle(color: Colors.grey, fontSize: 12)), Text(value, style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold))]));
  }

  Widget _buildAppItem(String name, String iconBase64, String cmd) {
    return GestureDetector(
      onTap: () { sendCommand(cmd); HapticFeedback.lightImpact(); },
      child: Container(decoration: BoxDecoration(color: const Color(0xFF15161E), borderRadius: BorderRadius.circular(15), border: Border.all(color: const Color(0xFF333333))), child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [_buildSafeIcon(iconBase64), const SizedBox(height: 5), Text(name, style: const TextStyle(fontSize: 11), textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis)])),
    );
  }

  Widget _buildSafeIcon(String base64Str) {
    if (base64Str.isEmpty) return const Icon(Icons.apps, size: 45);
    try { return Image.memory(base64Decode(base64Str), width: 45, height: 45, errorBuilder: (context, error, stackTrace) => const Icon(Icons.broken_image, size: 45, color: Colors.grey)); } 
    catch (e) { return const Icon(Icons.warning_amber_rounded, size: 45, color: Colors.orange); }
  }

  Widget _buildMediaScreen() {
    return GridView.count(crossAxisCount: 2, padding: const EdgeInsets.all(20), mainAxisSpacing: 20, crossAxisSpacing: 20, children: [_buildMediaBtn('رفع الصوت', Icons.volume_up, 'VOL_UP'), _buildMediaBtn('خفض الصوت', Icons.volume_down, 'VOL_DOWN'), _buildMediaBtn('كتم', Icons.volume_off, 'VOL_MUTE'), _buildMediaBtn('إيقاف / تشغيل', Icons.play_arrow, 'MEDIA_PLAY_PAUSE'), _buildMediaBtn('المقطع التالي', Icons.skip_next, 'MEDIA_NEXT'), _buildMediaBtn('المقطع السابق', Icons.skip_previous, 'MEDIA_PREV')]);
  }

  Widget _buildMediaBtn(String t, IconData i, String c) {
    return GestureDetector(onTap: () { sendCommand(c); HapticFeedback.lightImpact(); }, child: Container(decoration: BoxDecoration(color: const Color(0xFF15161E), borderRadius: BorderRadius.circular(15)), child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(i, size: 40), Text(t)])));
  }

  Widget _buildMouseScreen() {
    return Column(
      children: [
        Expanded(child: GestureDetector(onPanStart: (details) => _lastTouchPosition = details.localPosition, onPanUpdate: (details) { if (_lastTouchPosition != null) { double dx = details.localPosition.dx - _lastTouchPosition!.dx; double dy = details.localPosition.dy - _lastTouchPosition!.dy; _lastTouchPosition = details.localPosition; sendCommand('M_MOVE:${dx.toStringAsFixed(1)}:${dy.toStringAsFixed(1)}'); } }, onPanEnd: (details) => _lastTouchPosition = null, onTap: () { sendCommand('M_CLICK'); HapticFeedback.selectionClick(); }, onDoubleTap: () { sendCommand('M_DCLICK'); HapticFeedback.mediumImpact(); }, child: Container(margin: const EdgeInsets.all(20), decoration: BoxDecoration(border: Border.all(color: const Color(0xFFB829EA), width: 2), borderRadius: BorderRadius.circular(20), color: const Color(0xFF15161E)), child: const Center(child: Text('اسحب للتحريك - المس للنقر\n(Trackpad)', textAlign: TextAlign.center, style: TextStyle(color: Colors.white70, fontSize: 16)))))),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [IconButton(icon: const Icon(Icons.remove_circle_outline, color: Colors.redAccent, size: 30), onPressed: () => sendCommand("SPEED_DOWN")), const Padding(padding: EdgeInsets.symmetric(horizontal: 15), child: Text("حساسية الماوس", style: TextStyle(color: Colors.white, fontSize: 16))), IconButton(icon: const Icon(Icons.add_circle_outline, color: Colors.greenAccent, size: 30), onPressed: () => sendCommand("SPEED_UP"))]),
        Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [_mouseBtn('يسار', 'M_L_DOWN', 'M_L_UP'), _mouseBtn('يمين', 'M_R_DOWN', 'M_R_UP')]),
        const SizedBox(height: 80), 
      ],
    );
  }

  Widget _mouseBtn(String t, String down, String up) {
    return GestureDetector(onTapDown: (_) => sendCommand(down), onTapUp: (_) => sendCommand(up), child: Container(padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 20), decoration: BoxDecoration(color: const Color(0xFF15161E), borderRadius: BorderRadius.circular(10)), child: Text(t)));
  }
}