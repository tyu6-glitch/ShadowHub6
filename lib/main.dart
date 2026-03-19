import 'package:flutter/material.dart';
import 'dart:io';
import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_vlc_player/flutter_vlc_player.dart'; // 💡 الإضافة الوحيدة لتشغيل البث الجديد

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
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0B0C10),
        splashColor: const Color(0xFFB829EA).withOpacity(0.3),
        highlightColor: const Color(0xFFB829EA).withOpacity(0.1),
      ),
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
  Socket? socket;
  VlcPlayerController? _vlcViewController;
  bool isConnected = false;

  // دالة افتراضية للترجمة بناءً على كودك
  String t(String key) {
    if (key == "mouse_hint") return "حرك إصبعك هنا للتحكم";
    if (key == "left_click") return "يسار";
    if (key == "right_click") return "يمين";
    return key;
  }

  // 💡 التعديل هنا فقط: تشغيل السوكت للأوامر، وتشغيل VLC للفيديو
  Future<void> connectToServer(String ip) async {
    try {
      // 1. سوكت مخصص لإرسال أوامر الماوس والكيبورد بدون تأخير
      socket = await Socket.connect(ip, 8080);
      
      // 2. مشغل VLC لاستقبال بث الشاشة (H.264)
      _vlcViewController = VlcPlayerController.network(
        'tcp://$ip:8080',
        hwAcc: HwAcc.full, // تفعيل تسريع الهاردوير
        autoPlay: true,
        options: VlcPlayerOptions(
          advanced: VlcAdvancedOptions([
            VlcAdvancedOptions.networkCaching(150), // تقليل التأخير (اللاتنسي) لأقصى حد
          ]),
        ),
      );

      setState(() {
        isConnected = true;
      });

    } catch (e) {
      debugPrint("خطأ في الاتصال: $e");
    }
  }

  // دالة إرسال الأوامر (نفسها من كودك)
  void sendCommand(String cmd) {
    if (socket != null) {
      socket!.write('$cmd\n');
    }
  }

  @override
  void dispose() {
    socket?.close();
    _vlcViewController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          // 💡 تم استبدال قارئ الصور القديم بمشغل الفيديو
          Expanded(
            flex: 3,
            child: isConnected && _vlcViewController != null
                ? VlcPlayer(
                    controller: _vlcViewController!,
                    aspectRatio: 16 / 9,
                    placeholder: const Center(child: CircularProgressIndicator()),
                  )
                : const Center(child: Text("اضغط للاتصال", style: TextStyle(color: Colors.white54))),
          ),
          
          // ==========================================
          // 👇 من هنا وتحت كودك الأصلي بالضبط بدون أي مساس 👇
          // ==========================================
          Expanded(
            flex: 2,
            child: GestureDetector(
              onPanUpdate: (details) {
                sendCommand('M_MOVE:${details.delta.dx}:${details.delta.dy}');
              },
              child: Container(
                color: Colors.transparent, 
                width: double.infinity, 
                child: Center(
                  child: Text(t("mouse_hint"), textAlign: TextAlign.center, style: const TextStyle(color: Colors.white30, fontSize: 16))
                )
              )
            )
          ),
          Container(height: 1, color: Colors.white12), 
          Row(
            children: [
              Expanded(child: _mouseBtn(t("left_click"), 'M_L_DOWN', 'M_L_UP', true)),
              Container(width: 1, height: 50, color: Colors.white12), 
              Expanded(child: _mouseBtn(t("right_click"), 'M_R_DOWN', 'M_R_UP', false)),
            ]
          )
        ],
      ),
    );
  }

  // أزرار الماوس الخاصة بك
  Widget _mouseBtn(String t, String down, String up, bool isLeft) { 
    return Material(
      color: Colors.transparent, 
      borderRadius: BorderRadius.only(bottomLeft: Radius.circular(isLeft ? 15 : 0), bottomRight: Radius.circular(isLeft ? 0 : 15)),
      child: InkWell(
        borderRadius: BorderRadius.only(bottomLeft: Radius.circular(isLeft ? 15 : 0), bottomRight: Radius.circular(isLeft ? 0 : 15)),
        onTapDown: (_) { sendCommand(down); HapticFeedback.selectionClick(); }, 
        onTapUp: (_) => sendCommand(up),
        child: Container(
          height: 50,
          alignment: Alignment.center,
          child: Text(t, style: const TextStyle(color: Colors.white, fontSize: 16)),
        ),
      ),
    );
  }
}