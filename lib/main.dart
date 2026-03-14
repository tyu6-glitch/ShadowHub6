import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';

void main() {
  runApp(const ShadowHubApp());
}

class ShadowHubApp extends StatelessWidget {
  const ShadowHubApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ShadowHub',
      theme: ThemeData.dark(),
      debugShowCheckedModeBanner: false,
      home: const StreamScreen(),
    );
  }
}

class StreamScreen extends StatefulWidget {
  const StreamScreen({super.key});

  @override
  State<StreamScreen> createState() => _StreamScreenState();
}

class _StreamScreenState extends State<StreamScreen> {
  Socket? activeSocket;
  ServerSocket? serverSocket;
  bool isConnected = false;
  String statusMessage = "في انتظار الاتصال...";

  // متغير لتحديث الصورة في الواجهة فوراً
  ValueNotifier<Uint8List?> currentFrame = ValueNotifier(null);

  // مخزن مؤقت (Buffer) لمعالجة تدفق الفيديو
  List<int> dataBuffer = [];
  int expectedFrameLength = 0;
  bool isHandshakeDone = false;

  final TextEditingController ipController = TextEditingController();

  @override
  void initState() {
    super.initState();
    // عند فتح التطبيق، نشغل سيرفر الـ USB تلقائياً لينتظر الكمبيوتر
    startUsbServer();
  }

  // ==========================================
  // 1. نظام الـ USB (الآيباد ينتظر الكمبيوتر يهاجمه)
  // ==========================================
  Future<void> startUsbServer() async {
    try {
      serverSocket = await ServerSocket.bind('127.0.0.1', 8080);
      setState(() => statusMessage = "سيرفر USB جاهز.. ننتظر الكمبيوتر");
      
      serverSocket!.listen((Socket client) {
        if (activeSocket != null) {
          client.close(); // نرفض أي اتصال ثاني إذا كنا شابكين
          return;
        }
        setupConnection(client, "USB");
      });
    } catch (e) {
      setState(() => statusMessage = "خطأ في سيرفر USB: $e");
    }
  }

  // ==========================================
  // 2. نظام الواي فاي (الآيباد يهاجم الكمبيوتر)
  // ==========================================
  Future<void> connectWifi() async {
    String ip = ipController.text.trim();
    if (ip.isEmpty) return;

    setState(() => statusMessage = "جاري الاتصال بالكمبيوتر عبر الواي فاي...");
    try {
      Socket client = await Socket.connect(ip, 8080, timeout: const Duration(seconds: 3));
      setupConnection(client, "Wi-Fi");
    } catch (e) {
      setState(() => statusMessage = "فشل الاتصال بالواي فاي! تأكد من الـ IP.");
    }
  }

  // ==========================================
  // 3. معالج الاتصال الموحد (السر كله هنا)
  // ==========================================
  void setupConnection(Socket socket, String type) {
    activeSocket = socket;
    activeSocket!.setOption(SocketOption.tcpNoDelay, true); // لتقليل البنق
    
    isHandshakeDone = false;
    dataBuffer.clear();
    expectedFrameLength = 0;

    activeSocket!.listen((Uint8List data) {
      // 1. مرحلة المصافحة السرية
      if (!isHandshakeDone) {
        String msg = utf8.decode(data, allowMalformed: true);
        if (msg.contains("PC_READY")) {
          activeSocket!.write("IPAD_READY"); // نرد على الكمبيوتر عشان يشغل الشاشة
          isHandshakeDone = true;
          setState(() {
            isConnected = true;
            statusMessage = "متصل بنجاح عبر $type 🚀";
          });
        }
        return;
      }

      // 2. مرحلة معالجة تدفق الفيديو (Raw Stream)
      dataBuffer.addAll(data);

      while (true) {
        // إذا ما عندنا حجم الصورة لسه، نقرأ أول 4 بايت
        if (expectedFrameLength == 0) {
          if (dataBuffer.length >= 4) {
            var lengthBytes = Uint8List.fromList(dataBuffer.sublist(0, 4));
            var byteData = ByteData.sublistView(lengthBytes);
            expectedFrameLength = byteData.getUint32(0, Endian.big);
            dataBuffer.removeRange(0, 4);
          } else {
            break; // ننتظر بيانات أكثر من الشبكة
          }
        }

        // إذا عرفنا الحجم، ووصلت الصورة كاملة
        if (expectedFrameLength > 0 && dataBuffer.length >= expectedFrameLength) {
          var frameData = Uint8List.fromList(dataBuffer.sublist(0, expectedFrameLength));
          currentFrame.value = frameData; // تحديث الشاشة
          
          dataBuffer.removeRange(0, expectedFrameLength);
          expectedFrameLength = 0; // نصفر عشان نقرأ الصورة اللي بعدها
        } else {
          break; // ننتظر باقي أجزاء الصورة
        }
      }
    }, onDone: disconnect, onError: (e) => disconnect());
  }

  // ==========================================
  // 4. إرسال أوامر الماوس
  // ==========================================
  void sendCommand(String cmd) {
    if (activeSocket != null && isConnected) {
      activeSocket!.write("$cmd\n");
    }
  }

  void disconnect() {
    activeSocket?.close();
    activeSocket = null;
    setState(() {
      isConnected = false;
      currentFrame.value = null;
      statusMessage = "تم قطع الاتصال. ننتظر من جديد...";
    });
  }

  @override
  void dispose() {
    activeSocket?.close();
    serverSocket?.close();
    super.dispose();
  }

  // ==========================================
  // 5. واجهة المستخدم (UI)
  // ==========================================
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: isConnected ? buildStreamArea() : buildSetupArea(),
    );
  }

  // شاشة الاتصال
  Widget buildSetupArea() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.computer, size: 80, color: Colors.blueAccent),
            const SizedBox(height: 20),
            Text(statusMessage, style: const TextStyle(fontSize: 18)),
            const SizedBox(height: 40),
            
            const Text("للواي فاي: أدخل IP الكمبيوتر هنا", style: TextStyle(color: Colors.grey)),
            const SizedBox(height: 10),
            SizedBox(
              width: 300,
              child: TextField(
                controller: ipController,
                textAlign: TextAlign.center,
                decoration: InputDecoration(
                  hintText: "مثال: 192.168.1.5",
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: connectWifi,
              icon: const Icon(Icons.wifi),
              label: const Text("اتصال عبر الواي فاي"),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 15),
              ),
            ),
            const SizedBox(height: 40),
            const Divider(),
            const Text("أو اشبك سلك الـ USB وانتظر، سيتصل تلقائياً!", style: TextStyle(color: Colors.green)),
          ],
        ),
      ),
    );
  }

  // شاشة البث (الفيديو والماوس)
  Widget buildStreamArea() {
    return Stack(
      children: [
        // منطقة عرض الفيديو والتفاعل مع الماوس
        Positioned.fill(
          child: GestureDetector(
            onPanUpdate: (details) {
              // إرسال حركة الماوس
              sendCommand("M_MOVE:${details.delta.dx}:${details.delta.dy}");
            },
            onTap: () {
              // ضغطة يسار
              sendCommand("M_CLICK");
            },
            onSecondaryTap: () {
              // ضغطة يمين
              sendCommand("M_R_CLICK");
            },
            child: Container(
              color: Colors.black,
              child: ValueListenableBuilder<Uint8List?>(
                valueListenable: currentFrame,
                builder: (context, frameData, child) {
                  if (frameData == null) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  // عرض الصورة بدون فجوات لتجربة 60 فريم سلسة
                  return Image.memory(
                    frameData,
                    fit: BoxFit.contain,
                    gaplessPlayback: true, 
                  );
                },
              ),
            ),
          ),
        ),
        
        // زر قطع الاتصال في الزاوية
        Positioned(
          top: 40,
          right: 20,
          child: IconButton(
            icon: const Icon(Icons.exit_to_app, color: Colors.red, size: 30),
            onPressed: disconnect,
          ),
        ),
      ],
    );
  }
}