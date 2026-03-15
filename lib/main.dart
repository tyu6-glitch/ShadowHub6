import 'package:flutter/material.dart';
import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:network_info_plus/network_info_plus.dart';

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
  List<Map<String, dynamic>> syncedApps = []; 
  
  final TextEditingController _keyboardController = TextEditingController();
  final FocusNode _keyboardFocus = FocusNode();
  String _lastText = ""; 

  bool isMonitorMode = false; 
  bool isConnecting = false;
  bool _isQuickBarOpen = false;

  String connectionStatus = "اختر طريقة الاتصال للبدء 👇";
  Color statusColor = Colors.white;
  String currentActiveMode = "none"; // usb, wifi, none
  
  double mouseSpeed = 4.0;
  double streamQuality = 75.0;

  Socket? activeSocket;
  ServerSocket? serverSocket;
  bool isConnected = false;
  ValueNotifier<Uint8List?> currentFrame = ValueNotifier(null);
  List<int> dataBuffer = [];
  int expectedFrameLength = 0;
  bool isHandshakeDone = false;

  Offset? _lastLongPressOffset;
  Timer? _volumeTimer;
  int _lastMouseSendTime = 0;

  @override
  void dispose() {
    _volumeTimer?.cancel();
    activeSocket?.close();
    serverSocket?.close();
    super.dispose();
  }

  // ===========================================
  // 1. الاتصال عبر USB (الآيباد ينتظر الكمبيوتر)
  // ===========================================
  Future<void> startUsbMode() async {
    manualDisconnect(); // تنظيف أي اتصال سابق
    setState(() {
      currentActiveMode = "usb";
      isConnecting = true;
      connectionStatus = "جاري انتظار الكمبيوتر عبر سلك USB ⏳...";
      statusColor = Colors.orange;
    });

    try {
      serverSocket = await ServerSocket.bind('127.0.0.1', 8080);
      serverSocket!.listen((Socket client) {
        setupConnection(client, "سلك USB 🚀");
      });
    } catch (e) {
      setState(() {
        isConnecting = false;
        connectionStatus = "فشل تشغيل خادم USB. أعد المحاولة.";
        statusColor = Colors.red;
      });
    }
  }

  // ===========================================
  // 2. الاتصال عبر Wi-Fi (الآيباد يبحث عن الكمبيوتر)
  // ===========================================
  Future<void> startWifiMode() async {
    manualDisconnect();
    setState(() {
      currentActiveMode = "wifi";
      isConnecting = true;
      connectionStatus = "جاري مسح شبكة الـ Wi-Fi للبحث عن الكمبيوتر 📡...";
      statusColor = Colors.orange;
    });

    try {
      final info = NetworkInfo();
      String? wifiIP = await info.getWifiIP();
      if (wifiIP == null || !wifiIP.contains('.')) {
        setState(() { isConnecting = false; connectionStatus = "الآيباد غير متصل بالواي فاي!"; statusColor = Colors.red; });
        return;
      }
      String subnet = wifiIP.substring(0, wifiIP.lastIndexOf('.'));
      bool found = false;
      List<Future<void>> sweepTasks = [];
      
      for (int i = 1; i < 255; i++) {
        sweepTasks.add(
          Socket.connect('$subnet.$i', 8080, timeout: const Duration(milliseconds: 1500)).then((socket) {
            if (!found && !isConnected) { 
              found = true; 
              setupConnection(socket, "الـ Wi-Fi 📶");
            } else { socket.destroy(); }
          }).catchError((_) {})
        );
      }
      
      await Future.wait(sweepTasks).timeout(const Duration(milliseconds: 2000), onTimeout: () => []);
      
      if (!found && mounted && !isConnected) {
        setState(() { isConnecting = false; connectionStatus = "لم يتم العثور على الكمبيوتر في الشبكة."; statusColor = Colors.red; });
      }
    } catch (e) {
      setState(() { isConnecting = false; connectionStatus = "حدث خطأ أثناء البحث."; statusColor = Colors.red; });
    }
  }

  // ===========================================
  // إعداد وتجهيز الاتصال بعد النجاح
  // ===========================================
  void setupConnection(Socket socket, String type) {
    activeSocket = socket;
    activeSocket!.setOption(SocketOption.tcpNoDelay, true);
    isHandshakeDone = false; dataBuffer.clear(); expectedFrameLength = 0;

    activeSocket!.listen((Uint8List data) {
      if (!isHandshakeDone) {
        String msg = utf8.decode(data, allowMalformed: true);
        if (msg.contains("PC_READY")) {
          activeSocket!.write("IPAD_READY\n");
          sendCommand("SET_QUALITY:$streamQuality");
          sendCommand("SET_SENSITIVITY:$mouseSpeed");
          isHandshakeDone = true;
          if (mounted) setState(() { 
            isConnected = true; 
            isConnecting = false; 
            connectionStatus = "متصل بنجاح عبر $type ✅"; 
            statusColor = Colors.green; 
          });
        }
        return;
      }

      dataBuffer.addAll(data);
      while (true) {
        if (expectedFrameLength == 0) {
          if (dataBuffer.length >= 4) {
            var lengthBytes = Uint8List.fromList(dataBuffer.sublist(0, 4));
            expectedFrameLength = ByteData.sublistView(lengthBytes).getUint32(0, Endian.big);
            dataBuffer.removeRange(0, 4);
          } else { break; }
        }

        if (expectedFrameLength > 0 && dataBuffer.length >= expectedFrameLength) {
          var frameData = Uint8List.fromList(dataBuffer.sublist(0, expectedFrameLength));
          
          if (frameData.length > 10 && 
              frameData[0] == 83 && frameData[1] == 89 && frameData[2] == 78 && frameData[3] == 67 &&
              frameData[4] == 95 && frameData[5] == 74 && frameData[6] == 83 && frameData[7] == 79 &&
              frameData[8] == 78 && frameData[9] == 58) {
              
              String jsonStr = utf8.decode(frameData.sublist(10));
              try {
                  List<dynamic> parsedApps = jsonDecode(jsonStr);
                  if (mounted) {
                    setState(() { syncedApps = List<Map<String, dynamic>>.from(parsedApps); });
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم مزامنة التطبيقات! 🚀'), backgroundColor: Colors.green));
                  }
              } catch (e) {}
          } else {
              if (isMonitorMode) { currentFrame.value = frameData; }
              sendCommand("FRAME_ACK"); 
          }
          dataBuffer.removeRange(0, expectedFrameLength);
          expectedFrameLength = 0; 
        } else { break; }
      }
    }, onDone: _handleDisconnect, onError: (e) => _handleDisconnect());
  }

  void _handleDisconnect() {
    activeSocket?.close(); activeSocket = null; 
    serverSocket?.close(); serverSocket = null;
    isHandshakeDone = false;
    if (mounted) setState(() { 
      isConnected = false; isConnecting = false;
      currentFrame.value = null; 
      connectionStatus = "تم قطع الاتصال. يرجى اختيار طريقة للاتصال."; 
      statusColor = Colors.grey; 
      currentActiveMode = "none";
    });
  }

  void manualDisconnect() { 
    if (activeSocket != null) { sendCommand("K_SPACE"); }
    _handleDisconnect(); 
  }

  void sendCommand(String cmd) {
    if (activeSocket != null && isConnected) {
      try { activeSocket!.write("$cmd\n"); } catch (e) {}
    }
  }

  void _throttledMouseMove(double dx, double dy) {
    int now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastMouseSendTime > 16) { 
      sendCommand("M_MOVE:$dx:$dy");
      _lastMouseSendTime = now;
    }
  }

  void _exitFullScreenMode() {
    setState(() { isMonitorMode = false; _currentIndex = 4; });
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  Widget _buildGestureArea({required Widget child}) {
    return GestureDetector(
      onScaleUpdate: (details) {
        if (details.pointerCount == 1) _throttledMouseMove(details.focalPointDelta.dx, details.focalPointDelta.dy);
        else if (details.pointerCount == 2) {
          int now = DateTime.now().millisecondsSinceEpoch;
          if (now - _lastMouseSendTime > 30) {
            sendCommand("M_SCROLL:${details.focalPointDelta.dy}");
            _lastMouseSendTime = now;
          }
        }
      },
      onTap: () { sendCommand("M_CLICK"); HapticFeedback.selectionClick(); },
      onDoubleTap: () { sendCommand("M_DCLICK"); HapticFeedback.mediumImpact(); },
      onSecondaryTap: () => sendCommand("M_R_CLICK"),
      onLongPressStart: (details) { _lastLongPressOffset = Offset.zero; sendCommand("M_L_DOWN"); HapticFeedback.heavyImpact(); },
      onLongPressMoveUpdate: (details) { 
        if (_lastLongPressOffset != null) {
          double dx = details.localOffsetFromOrigin.dx - _lastLongPressOffset!.dx;
          double dy = details.localOffsetFromOrigin.dy - _lastLongPressOffset!.dy;
          _lastLongPressOffset = details.localOffsetFromOrigin;
          _throttledMouseMove(dx, dy);
        }
      },
      onLongPressEnd: (details) { _lastLongPressOffset = null; sendCommand("M_L_UP"); HapticFeedback.selectionClick(); },
      child: child,
    );
  }

  Widget _buildStreamDeckScreen() {
    if (syncedApps.isEmpty) { return const Center(child: Text("لا توجد تطبيقات متزامنة.\nافتح برنامج الكمبيوتر واضغط 'مزامنة'.", textAlign: TextAlign.center, style: TextStyle(color: Colors.white54, fontSize: 16))); }
    return GridView.builder(
      padding: const EdgeInsets.only(top: 80, left: 20, right: 20, bottom: 20),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 5, childAspectRatio: 0.9, mainAxisSpacing: 20, crossAxisSpacing: 20),
      itemCount: syncedApps.length,
      itemBuilder: (context, index) {
        final app = syncedApps[index];
        bool hasIcon = app['icon'] != null && app['icon'].toString().isNotEmpty;
        return GestureDetector(
          onTap: () { sendCommand("LAUNCH:${app['path']}"); HapticFeedback.heavyImpact(); },
          child: Container(
            decoration: BoxDecoration(color: const Color(0xFF15161E), borderRadius: BorderRadius.circular(15), border: Border.all(color: const Color(0xFFB829EA).withOpacity(0.5)), boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 5)]),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (hasIcon) Image.memory(base64Decode(app['icon']), width: 45, height: 45, gaplessPlayback: true) else const Icon(Icons.apps, size: 45, color: Colors.white54),
                const SizedBox(height: 10), Text(app['name'] ?? '', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold), overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    double keyboardHeight = MediaQuery.of(context).viewInsets.bottom;
    bool isKeyboardOpen = keyboardHeight > 0;

    Widget activeScreen;

    if (isMonitorMode) {
      activeScreen = Scaffold(
        resizeToAvoidBottomInset: false, backgroundColor: Colors.black,
        body: SafeArea(
          left: false, right: false, top: false, bottom: false,
          child: Stack(
            children: [
              Center(
                child: !isConnected 
                    ? const Text("لا يوجد اتصال بالكمبيوتر.", style: TextStyle(color: Colors.white54, fontSize: 16))
                    : ValueListenableBuilder<Uint8List?>(
                        valueListenable: currentFrame,
                        builder: (context, frameData, child) {
                          if (frameData == null) return const Text("جاري التقاط البث...", style: TextStyle(color: Colors.white54, fontSize: 16));
                          return _buildGestureArea(child: Image.memory(frameData, fit: BoxFit.contain, gaplessPlayback: true, width: double.infinity, height: double.infinity));
                        },
                      ),
              ),
              Positioned(top: 20, left: 20, child: Container(decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(50)), child: IconButton(icon: const Icon(Icons.close, color: Colors.white, size: 30), onPressed: _exitFullScreenMode))),
            ],
          ),
        ),
      );
    } else {
      activeScreen = Scaffold(
        resizeToAvoidBottomInset: false, 
        appBar: AppBar(backgroundColor: const Color(0xFF15161E), title: const Text('ShadowHub', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)), centerTitle: true),
        body: IndexedStack(index: _currentIndex, children: [_buildStreamDeckScreen(), _buildMediaScreen(), _buildMouseScreen(), const SizedBox(), _buildSettingsScreen()]),
        bottomNavigationBar: BottomNavigationBar(
          backgroundColor: const Color(0xFF15161E), selectedItemColor: const Color(0xFFB829EA), unselectedItemColor: const Color(0xFF888B94), type: BottomNavigationBarType.fixed, currentIndex: _currentIndex,
          onTap: (index) {
            if (index == 0) {
              setState(() => _currentIndex = index); 
              SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]); SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
            } else if (index == 3) {
              setState(() { isMonitorMode = true; });
              SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]); SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
            } else { setState(() => _currentIndex = index); }
          },
          items: const [BottomNavigationBarItem(icon: Icon(Icons.apps), label: 'StreamDeck'), BottomNavigationBarItem(icon: Icon(Icons.music_note), label: 'الميديا'), BottomNavigationBarItem(icon: Icon(Icons.mouse), label: 'الماوس'), BottomNavigationBarItem(icon: Icon(Icons.monitor), label: 'الشاشة'), BottomNavigationBarItem(icon: Icon(Icons.settings), label: 'الإعدادات')],
        ),
      );
    }

    return Material(
      type: MaterialType.transparency,
      child: Stack(
        children: [
          GestureDetector(
            onTap: () { if (isKeyboardOpen || _keyboardFocus.hasFocus) { FocusManager.instance.primaryFocus?.unfocus(); SystemChannels.textInput.invokeMethod('TextInput.hide'); } },
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
                    } else if (text.length < _lastText.length) { for (int i = 0; i < (_lastText.length - text.length); i++) sendCommand("K_BACK"); }
                    _lastText = text;
                  },
                ),
              ),
            ),
          ),
          
          if (isMonitorMode || _currentIndex == 0 || _currentIndex == 1)
            Positioned(
              top: isMonitorMode ? 20 : 60, right: 20,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (_isQuickBarOpen)
                    Container(
                      margin: const EdgeInsets.only(right: 10), padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 0),
                      decoration: BoxDecoration(color: const Color(0xFF15161E), borderRadius: BorderRadius.circular(25), border: Border.all(color: const Color(0xFFB829EA), width: 1.5), boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 10)]),
                      child: Row(
                        children: [
                          IconButton(icon: const Icon(Icons.monitor, color: Colors.white70, size: 22), tooltip: 'تبديل الشاشة', onPressed: () { sendCommand("TOGGLE_SCREEN"); HapticFeedback.heavyImpact(); }),
                          IconButton(icon: const Icon(Icons.keyboard, color: Colors.white70, size: 22), tooltip: 'الكيبورد', onPressed: () { if (isKeyboardOpen || _keyboardFocus.hasFocus) { FocusManager.instance.primaryFocus?.unfocus(); SystemChannels.textInput.invokeMethod('TextInput.hide'); } else { _keyboardFocus.requestFocus(); SystemChannels.textInput.invokeMethod('TextInput.show'); } HapticFeedback.lightImpact(); }),
                          _quickBtn(Icons.copy, 'نسخ', 'HOTKEY:ctrl+c'), _quickBtn(Icons.paste, 'لصق', 'HOTKEY:ctrl+v'), _quickBtn(Icons.cut, 'قص', 'HOTKEY:ctrl+x'), _quickBtn(Icons.undo, 'تراجع', 'HOTKEY:ctrl+z'),
                        ],
                      ),
                    ),
                  FloatingActionButton(
                    mini: true, backgroundColor: _isQuickBarOpen ? const Color(0xFF222533) : const Color(0xFFB829EA),
                    onPressed: () => setState(() => _isQuickBarOpen = !_isQuickBarOpen), child: Icon(_isQuickBarOpen ? Icons.close : Icons.bolt, color: Colors.white),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _quickBtn(IconData icon, String tooltip, String cmd) {
    return IconButton(icon: Icon(icon, color: Colors.white70, size: 22), tooltip: tooltip, onPressed: () { sendCommand(cmd); HapticFeedback.lightImpact(); });
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
                const Text("إدارة الاتصال", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
                const SizedBox(height: 15),
                Text(connectionStatus, textAlign: TextAlign.center, style: TextStyle(color: statusColor, fontWeight: FontWeight.bold, fontSize: 14)),
                const SizedBox(height: 20),
                
                // أزرار التحكم الصريح (اختيارك الذكي)
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: (isConnected && currentActiveMode == "wifi") ? null : startWifiMode,
                        icon: const Icon(Icons.wifi, color: Colors.white),
                        label: const Text('Wi-Fi', style: TextStyle(fontSize: 16)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: currentActiveMode == "wifi" ? Colors.green : const Color(0xFF222533),
                          foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))
                        ),
                      ),
                    ),
                    const SizedBox(width: 15),
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: (isConnected && currentActiveMode == "usb") ? null : startUsbMode,
                        icon: const Icon(Icons.usb, color: Colors.white),
                        label: const Text('USB', style: TextStyle(fontSize: 16)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: currentActiveMode == "usb" ? const Color(0xFFB829EA) : const Color(0xFF222533),
                          foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))
                        ),
                      ),
                    ),
                  ],
                ),
                if (isConnected) ...[
                  const SizedBox(height: 15),
                  ElevatedButton.icon(
                    onPressed: manualDisconnect,
                    icon: const Icon(Icons.power_settings_new, color: Colors.white),
                    label: const Text('قطع الاتصال', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 10)),
                  ),
                ]
              ],
            ),
          ),
          const SizedBox(height: 25),
          Container(
            padding: const EdgeInsets.all(20), decoration: BoxDecoration(color: const Color(0xFF15161E), borderRadius: BorderRadius.circular(15), border: Border.all(color: const Color(0xFFB829EA).withOpacity(0.3))),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Center(child: Text("إعدادات الأداء", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white))), const SizedBox(height: 20),
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [const Text("سرعة الماوس:", style: TextStyle(color: Colors.white70, fontSize: 16)), Text(mouseSpeed.toStringAsFixed(1), style: const TextStyle(color: Color(0xFFB829EA), fontWeight: FontWeight.bold, fontSize: 16)),]),
                Slider(value: mouseSpeed, min: 1.0, max: 10.0, divisions: 18, activeColor: const Color(0xFFB829EA), onChanged: (value) { setState(() { mouseSpeed = value; }); }, onChangeEnd: (value) { sendCommand("SET_SENSITIVITY:$value"); }),
                const SizedBox(height: 15),
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [const Text("جودة بث الشاشة:", style: TextStyle(color: Colors.white70, fontSize: 16)), Text("${streamQuality.toInt()}%", style: const TextStyle(color: Color(0xFFB829EA), fontWeight: FontWeight.bold, fontSize: 16)),]),
                Slider(value: streamQuality, min: 50.0, max: 100.0, divisions: 10, activeColor: const Color(0xFFB829EA), onChanged: (value) { setState(() { streamQuality = value; }); }, onChangeEnd: (value) { sendCommand("SET_QUALITY:$value"); }),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMediaScreen() {
    return GridView.count(
      crossAxisCount: 3, childAspectRatio: 1.2, padding: const EdgeInsets.all(15), mainAxisSpacing: 15, crossAxisSpacing: 15, 
      children: [
        _buildMediaBtn('كتم الصوت', Icons.volume_off, 'VOL_MUTE'), _buildMediaBtn('إيقاف/تشغيل', Icons.play_arrow, 'MEDIA_PLAY_PAUSE'), _buildContinuousMediaBtn('رفع الصوت', Icons.volume_up, 'VOL_UP'), 
        _buildMediaBtn('المقطع السابق', Icons.skip_previous, 'MEDIA_PREV'), _buildMediaBtn('المقطع التالي', Icons.skip_next, 'MEDIA_NEXT'), _buildContinuousMediaBtn('خفض الصوت', Icons.volume_down, 'VOL_DOWN')
      ]
    );
  }

  Widget _buildMediaBtn(String t, IconData i, String c) { return GestureDetector(onTap: () { sendCommand(c); HapticFeedback.lightImpact(); }, child: Container(decoration: BoxDecoration(color: const Color(0xFF15161E), borderRadius: BorderRadius.circular(15)), child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(i, size: 28, color: const Color(0xFFB829EA)), const SizedBox(height: 8), Text(t, style: const TextStyle(fontSize: 12), textAlign: TextAlign.center)]))); }
  Widget _buildContinuousMediaBtn(String t, IconData i, String c) { return GestureDetector(onTapDown: (_) { sendCommand(c); HapticFeedback.lightImpact(); _volumeTimer = Timer.periodic(const Duration(milliseconds: 150), (timer) { sendCommand(c); }); }, onTapUp: (_) => _volumeTimer?.cancel(), onTapCancel: () => _volumeTimer?.cancel(), child: Container(decoration: BoxDecoration(color: const Color(0xFF15161E), borderRadius: BorderRadius.circular(15)), child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(i, size: 28, color: const Color(0xFFB829EA)), const SizedBox(height: 8), Text(t, style: const TextStyle(fontSize: 12), textAlign: TextAlign.center)]))); }

  Widget _buildMouseScreen() {
    return Column(
      children: [
        Expanded(child: _buildGestureArea(child: Container(margin: const EdgeInsets.all(20), decoration: BoxDecoration(border: Border.all(color: const Color(0xFFB829EA), width: 2), borderRadius: BorderRadius.circular(20), color: const Color(0xFF15161E)), child: const Center(child: Text('إصبع واحد للتحريك\nإصبعين للتمرير (سكرول)\nلمسة واحدة للنقر\nضغطة مطولة مع السحب للتحديد', textAlign: TextAlign.center, style: TextStyle(color: Colors.white70, fontSize: 16)))))),
        Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [_mouseBtn('يسار', 'M_L_DOWN', 'M_L_UP'), _mouseBtn('يمين', 'M_R_DOWN', 'M_R_UP')]), const SizedBox(height: 80), 
      ],
    );
  }
  Widget _mouseBtn(String t, String down, String up) { return GestureDetector(onTapDown: (_) => sendCommand(down), onTapUp: (_) => sendCommand(up), child: Container(padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 20), decoration: BoxDecoration(color: const Color(0xFF15161E), borderRadius: BorderRadius.circular(10)), child: Text(t, style: const TextStyle(fontSize: 16)))); }
}