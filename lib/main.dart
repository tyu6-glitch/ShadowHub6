import 'package:flutter/material.dart';
import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

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
  final TextEditingController _ipController = TextEditingController();

  bool isStreamDeckMode = false;
  bool isMonitorMode = false; 
  bool isWifiSelected = true; 
  bool isConnecting = false;

  String connectionStatus = "لم يتم الاتصال";
  Color statusColor = Colors.grey;
  
  // نظام الاتصال الموحد الصاروخي
  Socket? activeSocket;
  ServerSocket? serverSocket;
  bool isConnected = false;
  ValueNotifier<Uint8List?> currentFrame = ValueNotifier(null);
  List<int> dataBuffer = [];
  int expectedFrameLength = 0;
  bool isHandshakeDone = false;

  double floatingX = 20.0;
  double floatingY = 100.0;
  double savedPortraitX = 20.0;
  double savedPortraitY = 100.0;
  Offset? _lastTouchPosition;

  @override
  void initState() {
    super.initState();
    startUsbServer(); // تشغيل سيرفر الـ USB بالخلفية دائماً
  }

  @override
  void dispose() {
    activeSocket?.close();
    serverSocket?.close();
    super.dispose();
  }

  // ==========================================
  // 1. نظام الـ USB (الآيباد ينتظر الهجوم)
  // ==========================================
  Future<void> startUsbServer() async {
    try {
      serverSocket?.close();
      serverSocket = await ServerSocket.bind('127.0.0.1', 8080);
      serverSocket!.listen((Socket client) {
        if (activeSocket != null) { client.close(); return; }
        setupConnection(client, "سلك الـ USB الخارق 🚀");
      });
    } catch (e) {
      debugPrint("USB Server Error: $e");
    }
  }

  // ==========================================
  // 2. نظام الواي فاي (الآيباد يهاجم الكمبيوتر)
  // ==========================================
  Future<void> connectWifi() async {
    String ip = _ipController.text.trim();
    if (ip.isEmpty) return;

    setState(() {
      isConnecting = true;
      connectionStatus = "جاري الاتصال بالكمبيوتر...";
      statusColor = Colors.orange;
    });

    try {
      Socket client = await Socket.connect(ip, 8080, timeout: const Duration(seconds: 3));
      setupConnection(client, "الواي فاي 📶");
    } catch (e) {
      setState(() {
        isConnecting = false;
        connectionStatus = "فشل الاتصال! تأكد من الـ IP.";
        statusColor = Colors.red;
      });
    }
  }

  // ==========================================
  // 3. معالج الاتصال وتدفق الفيديو (السر كله هنا)
  // ==========================================
  void setupConnection(Socket socket, String type) {
    activeSocket = socket;
    activeSocket!.setOption(SocketOption.tcpNoDelay, true);
    
    isHandshakeDone = false;
    dataBuffer.clear();
    expectedFrameLength = 0;

    activeSocket!.listen((Uint8List data) {
      if (!isHandshakeDone) {
        String msg = utf8.decode(data, allowMalformed: true);
        if (msg.contains("PC_READY")) {
          activeSocket!.write("IPAD_READY\n");
          isHandshakeDone = true;
          if (mounted) {
            setState(() {
              isConnected = true;
              isConnecting = false;
              connectionStatus = "متصل بنجاح عبر $type";
              statusColor = Colors.green;
            });
          }
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
          if (isMonitorMode) currentFrame.value = frameData;
          dataBuffer.removeRange(0, expectedFrameLength);
          expectedFrameLength = 0; 
        } else { break; }
      }
    }, onDone: disconnect, onError: (e) => disconnect());
  }

  // ==========================================
  // 4. إرسال الأوامر الموحد
  // ==========================================
  void sendCommand(String cmd) {
    if (activeSocket != null && isConnected) {
      try { activeSocket!.write("$cmd\n"); } catch (e) {}
    }
  }

  void disconnect() {
    activeSocket?.close();
    activeSocket = null;
    if (mounted) {
      setState(() {
        isConnected = false;
        currentFrame.value = null;
        connectionStatus = "تم قطع الاتصال";
        statusColor = Colors.red;
      });
    }
  }

  void _exitFullScreenMode() {
    setState(() {
      if (isMonitorMode) { floatingX = savedPortraitX; floatingY = savedPortraitY; }
      isStreamDeckMode = false; isMonitorMode = false; _currentIndex = 4; 
    });
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
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
        backgroundColor: Colors.black,
        body: SafeArea(
          left: false, right: false, top: false, bottom: false,
          child: Stack(
            children: [
              Center(
                child: !isConnected 
                    ? const Text("الرجاء الاتصال بالكمبيوتر أولاً", style: TextStyle(color: Colors.white54, fontSize: 16))
                    : ValueListenableBuilder<Uint8List?>(
                        valueListenable: currentFrame,
                        builder: (context, frameData, child) {
                          if (frameData == null) return const Text("جاري التقاط البث...", style: TextStyle(color: Colors.white54, fontSize: 16));
                          return GestureDetector(
                            onPanUpdate: (details) => sendCommand("M_MOVE:${details.delta.dx}:${details.delta.dy}"),
                            onTap: () => sendCommand("M_CLICK"),
                            onSecondaryTap: () => sendCommand("M_R_CLICK"),
                            child: Image.memory(frameData, fit: BoxFit.contain, gaplessPlayback: true),
                          );
                        },
                      ),
              ),
              Positioned(top: 20, left: 20, child: Container(decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(50)), child: IconButton(icon: const Icon(Icons.arrow_back, color: Colors.white, size: 30), onPressed: _exitFullScreenMode))),
            ],
          ),
        ),
      );
    } else if (isStreamDeckMode) {
      activeScreen = Scaffold(
        backgroundColor: Colors.black, 
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
            } else if (index == 3) {
              setState(() { isMonitorMode = true; savedPortraitX = floatingX; savedPortraitY = floatingY; floatingX = 20.0; floatingY = 180.0; });
              SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
              SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
            } else {
              setState(() => _currentIndex = index);
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

  // ==========================================
  // الشاشات الفرعية (الإعدادات والميديا والماوس)
  // ==========================================
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
                const Text("إعدادات الاتصال (واي فاي)", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)), const SizedBox(height: 15),
                TextField(
                  controller: _ipController,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: "أدخل الـ IP الموجود في الكمبيوتر",
                    hintStyle: const TextStyle(color: Colors.grey),
                    filled: true,
                    fillColor: const Color(0xFF0B0C10),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                  ),
                ),
                const SizedBox(height: 20),
                ElevatedButton.icon(
                  onPressed: isConnecting ? null : connectWifi,
                  icon: isConnecting ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)) : const Icon(Icons.wifi, color: Colors.white),
                  label: Text(isConnecting ? 'جاري الاتصال...' : 'اتصال بالواي فاي', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFB829EA), foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 15), minimumSize: const Size(double.infinity, 55)),
                ),
                const SizedBox(height: 15),
                const Text("ملاحظة: لـ USB، فقط اشبك السلك وسيتصل تلقائياً!", style: TextStyle(color: Colors.green, fontSize: 12)),
              ],
            ),
          ),
          const SizedBox(height: 15),
          Center(child: Text(connectionStatus, textAlign: TextAlign.center, style: TextStyle(color: statusColor, fontWeight: FontWeight.bold, fontSize: 16))),
        ],
      ),
    );
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
        Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [_mouseBtn('يسار', 'M_L_DOWN', 'M_L_UP'), _mouseBtn('يمين', 'M_R_DOWN', 'M_R_UP')]),
        const SizedBox(height: 80), 
      ],
    );
  }

  Widget _mouseBtn(String t, String down, String up) {
    return GestureDetector(onTapDown: (_) => sendCommand(down), onTapUp: (_) => sendCommand(up), child: Container(padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 20), decoration: BoxDecoration(color: const Color(0xFF15161E), borderRadius: BorderRadius.circular(10)), child: Text(t)));
  }
}