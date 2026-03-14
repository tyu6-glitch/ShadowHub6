import 'package:flutter/material.dart';
import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/services.dart';

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
  List<Map<String, String>> customApps = [];
  
  final TextEditingController _keyboardController = TextEditingController();
  final FocusNode _keyboardFocus = FocusNode();
  String _lastText = ""; 

  bool isStreamDeckMode = false;
  bool isMonitorMode = false; 
  bool isConnecting = false;

  String connectionStatus = "جاهز للاتصال - اشبك USB أو ابحث بالواي فاي";
  Color statusColor = Colors.grey;
  
  // المتغيرات الجديدة للتحكم
  double mouseSpeed = 4.0;
  double streamQuality = 75.0;

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

  @override
  void initState() {
    super.initState();
    startUsbServer(); 
  }

  @override
  void dispose() {
    activeSocket?.close();
    serverSocket?.close();
    super.dispose();
  }

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

  Future<void> connectWifiAuto() async {
    if (isConnected) return;
    setState(() { isConnecting = true; connectionStatus = "جاري البحث عن الكمبيوتر بالرادار 📡..."; statusColor = Colors.orange; });

    try {
      RawDatagramSocket udpSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      udpSocket.broadcastEnabled = true;
      udpSocket.send(utf8.encode("SHADOWHUB_IPAD"), InternetAddress("255.255.255.255"), 5555);

      udpSocket.listen((RawSocketEvent event) async {
        if (event == RawSocketEvent.read) {
          Datagram? dg = udpSocket.receive();
          if (dg != null) {
            String msg = utf8.decode(dg.data).trim();
            if (msg.startsWith("SHADOWHUB_PC:")) {
              String pcIp = msg.split(":")[1];
              udpSocket.close();
              try {
                Socket client = await Socket.connect(pcIp, 8080, timeout: const Duration(seconds: 3));
                setupConnection(client, "الواي فاي 📶");
              } catch (e) {
                 if (mounted) setState(() { isConnecting = false; connectionStatus = "فشل الاتصال!"; statusColor = Colors.red; });
              }
            }
          }
        }
      });

      await Future.delayed(const Duration(seconds: 3));
      if (!isConnected && isConnecting && mounted) {
        udpSocket.close();
        setState(() { isConnecting = false; connectionStatus = "لم يتم العثور على الكمبيوتر!"; statusColor = Colors.red; });
      }
    } catch (e) {
      if (mounted) setState(() { isConnecting = false; connectionStatus = "خطأ في الرادار!"; statusColor = Colors.red; });
    }
  }

  void setupConnection(Socket socket, String type) {
    activeSocket = socket;
    activeSocket!.setOption(SocketOption.tcpNoDelay, true);
    isHandshakeDone = false; dataBuffer.clear(); expectedFrameLength = 0;

    activeSocket!.listen((Uint8List data) {
      if (!isHandshakeDone) {
        String msg = utf8.decode(data, allowMalformed: true);
        if (msg.contains("PC_READY")) {
          activeSocket!.write("IPAD_READY\n");
          // إرسال الإعدادات الحالية فوراً بعد الاتصال
          sendCommand("SET_QUALITY:$streamQuality");
          sendCommand("SET_SENSITIVITY:$mouseSpeed");
          isHandshakeDone = true;
          if (mounted) setState(() { isConnected = true; isConnecting = false; connectionStatus = "متصل بنجاح عبر $type"; statusColor = Colors.green; });
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
    }, onDone: _handleDisconnect, onError: (e) => _handleDisconnect());
  }

  void _handleDisconnect() {
    activeSocket?.close(); activeSocket = null; isHandshakeDone = false;
    if (mounted) setState(() { isConnected = false; currentFrame.value = null; connectionStatus = "تم قطع الاتصال. جاهز للاتصال من جديد."; statusColor = Colors.grey; });
  }

  void sendCommand(String cmd) {
    if (activeSocket != null && isConnected) {
      try { activeSocket!.write("$cmd\n"); } catch (e) {}
    }
  }

  void manualDisconnect() {
    sendCommand("K_SPACE"); 
    _handleDisconnect();
  }

  void _exitFullScreenMode() {
    setState(() {
      if (isMonitorMode) { floatingX = savedPortraitX; floatingY = savedPortraitY; }
      isStreamDeckMode = false; isMonitorMode = false; _currentIndex = 4; 
    });
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  // معالج حركات الماوس المشترك (يحسن التحديد والسحب)
  Widget _buildGestureArea({required Widget child}) {
    return GestureDetector(
      onScaleUpdate: (details) {
        if (details.pointerCount == 1) {
          sendCommand("M_MOVE:${details.focalPointDelta.dx}:${details.focalPointDelta.dy}");
        } else if (details.pointerCount == 2) {
          sendCommand("M_SCROLL:${details.focalPointDelta.dy}");
        }
      },
      onTap: () { sendCommand("M_CLICK"); HapticFeedback.selectionClick(); },
      onDoubleTap: () { sendCommand("M_DCLICK"); HapticFeedback.mediumImpact(); },
      onSecondaryTap: () => sendCommand("M_R_CLICK"),
      // السحب والإفلات (Long Press and Drag)
      onLongPressStart: (details) { sendCommand("M_L_DOWN"); HapticFeedback.heavyImpact(); },
      onLongPressMoveUpdate: (details) { sendCommand("M_MOVE:${details.localOffsetFromOrigin.dx}:${details.localOffsetFromOrigin.dy}"); },
      onLongPressEnd: (details) { sendCommand("M_L_UP"); HapticFeedback.selectionClick(); },
      child: child,
    );
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
        resizeToAvoidBottomInset: false, // 🔥 هذا السطر يمنع الشاشة من التصغير عند فتح الكيبورد
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
                          return _buildGestureArea(
                            child: Image.memory(frameData, fit: BoxFit.contain, gaplessPlayback: true, width: double.infinity, height: double.infinity),
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
                itemBuilder: (context, index) { return const SizedBox(); },
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
              setState(() => isStreamDeckMode = true); SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
            } else if (index == 3) {
              setState(() { isMonitorMode = true; savedPortraitX = floatingX; savedPortraitY = floatingY; floatingX = 20.0; floatingY = 180.0; });
              SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
              SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
            } else { setState(() => _currentIndex = index); }
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

  Widget _buildSettingsScreen() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // قسم الاتصال
          Container(
            padding: const EdgeInsets.all(20), decoration: BoxDecoration(color: const Color(0xFF15161E), borderRadius: BorderRadius.circular(15), border: Border.all(color: const Color(0xFFB829EA).withOpacity(0.3))),
            child: Column(
              children: [
                const Text("إدارة الاتصال", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)), const SizedBox(height: 15),
                if (!isConnected)
                  ElevatedButton.icon(
                    onPressed: isConnecting ? null : connectWifiAuto,
                    icon: isConnecting ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)) : const Icon(Icons.radar, color: Colors.white),
                    label: Text(isConnecting ? 'جاري البحث...' : 'اتصال سريع (واي فاي)', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFB829EA), foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 15), minimumSize: const Size(double.infinity, 55)),
                  ),
                if (isConnected)
                  ElevatedButton.icon(
                    onPressed: manualDisconnect,
                    icon: const Icon(Icons.power_settings_new, color: Colors.white),
                    label: const Text('قطع الاتصال', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 15), minimumSize: const Size(double.infinity, 55)),
                  ),
                const SizedBox(height: 15),
                const Text("ملاحظة: لـ USB، فقط اشبك السلك وسيتصل تلقائياً!", style: TextStyle(color: Colors.green, fontSize: 12)),
              ],
            ),
          ),
          const SizedBox(height: 15),
          Center(child: Text(connectionStatus, textAlign: TextAlign.center, style: TextStyle(color: statusColor, fontWeight: FontWeight.bold, fontSize: 16))),
          const SizedBox(height: 25),

          // قسم الإعدادات الجديدة (سرعة الماوس وجودة البث)
          Container(
            padding: const EdgeInsets.all(20), decoration: BoxDecoration(color: const Color(0xFF15161E), borderRadius: BorderRadius.circular(15), border: Border.all(color: const Color(0xFFB829EA).withOpacity(0.3))),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Center(child: Text("إعدادات الأداء", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white))), 
                const SizedBox(height: 20),
                
                // شريط سرعة الماوس
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  const Text("سرعة الماوس:", style: TextStyle(color: Colors.white70, fontSize: 16)),
                  Text(mouseSpeed.toStringAsFixed(1), style: const TextStyle(color: Color(0xFFB829EA), fontWeight: FontWeight.bold, fontSize: 16)),
                ]),
                Slider(
                  value: mouseSpeed, min: 1.0, max: 10.0, divisions: 18, activeColor: const Color(0xFFB829EA),
                  onChanged: (value) { setState(() { mouseSpeed = value; }); },
                  onChangeEnd: (value) { sendCommand("SET_SENSITIVITY:$value"); },
                ),
                const SizedBox(height: 15),

                // شريط جودة البث
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  const Text("جودة بث الشاشة:", style: TextStyle(color: Colors.white70, fontSize: 16)),
                  Text("${streamQuality.toInt()}%", style: const TextStyle(color: Color(0xFFB829EA), fontWeight: FontWeight.bold, fontSize: 16)),
                ]),
                Slider(
                  value: streamQuality, min: 50.0, max: 100.0, divisions: 10, activeColor: const Color(0xFFB829EA),
                  onChanged: (value) { setState(() { streamQuality = value; }); },
                  onChangeEnd: (value) { sendCommand("SET_QUALITY:$value"); },
                ),
              ],
            ),
          ),
        ],
      ),
    );
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
        Expanded(
          child: _buildGestureArea(
            child: Container(margin: const EdgeInsets.all(20), decoration: BoxDecoration(border: Border.all(color: const Color(0xFFB829EA), width: 2), borderRadius: BorderRadius.circular(20), color: const Color(0xFF15161E)), child: const Center(child: Text('إصبع واحد للتحريك\nإصبعين للتمرير (سكرول)\nلمسة واحدة للنقر\nضغطة مطولة مع السحب للتحديد', textAlign: TextAlign.center, style: TextStyle(color: Colors.white70, fontSize: 16))))
          )
        ),
        Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [_mouseBtn('يسار', 'M_L_DOWN', 'M_L_UP'), _mouseBtn('يمين', 'M_R_DOWN', 'M_R_UP')]),
        const SizedBox(height: 80), 
      ],
    );
  }

  Widget _mouseBtn(String t, String down, String up) {
    return GestureDetector(onTapDown: (_) => sendCommand(down), onTapUp: (_) => sendCommand(up), child: Container(padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 20), decoration: BoxDecoration(color: const Color(0xFF15161E), borderRadius: BorderRadius.circular(10)), child: Text(t)));
  }
}