import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; 
import 'package:webview_flutter/webview_flutter.dart';
import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' show join;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await DatabaseHelper.instance.initDatabase();
  runApp(const HumanAnalyticsApp());
}

class HumanAnalyticsApp extends StatelessWidget {
  const HumanAnalyticsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'HAE Core',
      theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      home: const MainNavigationScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

// ---- YEREL VERİTABANI ----
class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;

  DatabaseHelper._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await initDatabase();
    return _database!;
  }

  Future<Database> initDatabase() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'hae_telemetry_v2.db');

    return await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE telemetry_logs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            video_id TEXT,
            dwell_time_ms INTEGER,
            duration_sec REAL,
            loop_count REAL,
            platform TEXT,
            timestamp INTEGER
          )
        ''');
      },
    );
  }

  Future<void> insertLog(Map<String, dynamic> log) async {
    final db = await instance.database;
    await db.insert('telemetry_logs', {
      'video_id': log['video_id'],
      'dwell_time_ms': log['metrics']['dwell_time_ms'],
      'duration_sec': log['metrics']['duration_sec'],
      'loop_count': log['metrics']['loop_count'],
      'platform': log['platform'],
      'timestamp': log['timestamp'],
    });
  }

  Future<List<Map<String, dynamic>>> fetchAllLogs() async {
    final db = await instance.database;
    return await db.query('telemetry_logs', orderBy: 'timestamp DESC');
  }
}

// ---- ANA EKRAN ----
class MainNavigationScreen extends StatefulWidget {
  const MainNavigationScreen({super.key});

  @override
  State<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

class _MainNavigationScreenState extends State<MainNavigationScreen> {
  int _currentIndex = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _currentIndex == 0 ? const HaeBrowserScreen() : const AnalyticsDashboardScreen(),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) {
          setState(() {
            _currentIndex = index;
          });
        },
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.play_circle_fill), label: 'Shorts'),
          BottomNavigationBarItem(icon: Icon(Icons.insights), label: 'Derin Analiz'),
        ],
      ),
    );
  }
}

// ---- YOUTUBE WEBVIEW EKRANI ----
class HaeBrowserScreen extends StatefulWidget {
  const HaeBrowserScreen({super.key});

  @override
  State<HaeBrowserScreen> createState() => _HaeBrowserScreenState();
}

class _HaeBrowserScreenState extends State<HaeBrowserScreen> {
  late final WebViewController _controller;

  // JS Ajanı (NaN Hatalarına karşı güçlendirildi)
  final String telemetryScript = '''
    (function() {
      let currentVideoId = "";
      let startTime = Date.now();

      function checkActiveVideo() {
        let url = window.location.href;
        if (!url.includes('/shorts/')) return;
        
        let id = url.split('/shorts/')[1].split('?')[0];
        
        const videos = document.querySelectorAll('video');
        videos.forEach(video => {
          if (video.currentTime > 0 && !video.paused && !video.ended) {
            if (id !== currentVideoId) {
              if (currentVideoId !== "") {
                let dwellTime = Date.now() - startTime;
                let duration = video.duration;
                
                // Güvenlik yaması: duration henüz yüklenmediyse NaN döner, bunu engelliyoruz.
                if (isNaN(duration) || duration === Infinity) {
                  duration = 0;
                }

                let loops = duration > 0 ? (dwellTime / (duration * 1000)) : 0;
                
                let payload = {
                  session_id: "auto-session",
                  timestamp: Date.now(),
                  platform: "youtube_shorts",
                  video_id: currentVideoId,
                  metrics: { 
                    dwell_time_ms: dwellTime,
                    duration_sec: duration,
                    loop_count: parseFloat(loops.toFixed(2))
                  }
                };
                if (window.AnalyticsBridge) {
                  window.AnalyticsBridge.postMessage(JSON.stringify(payload));
                }
              }
              currentVideoId = id;
              startTime = Date.now();
            }
          }
        });
      }
      setInterval(checkActiveVideo, 500);
    })();
  ''';

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (String url) {
            // Yükleme ekranı yok, direkt scripti basıyoruz.
            _controller.runJavaScript(telemetryScript);
          },
        ),
      )
      ..addJavaScriptChannel(
        'AnalyticsBridge',
        onMessageReceived: (JavaScriptMessage message) async {
          try {
            final data = jsonDecode(message.message);
            await DatabaseHelper.instance.insertLog(data);
            
            if (mounted) {
              double loops = (data['metrics']['loop_count'] as num).toDouble();
              String msg = loops > 1.0 ? "Başa Sardı! (${loops.toStringAsFixed(1)}x)" : "Kaydedildi";
              
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text("$msg - ID: ${data['video_id']}"),
                  duration: const Duration(milliseconds: 600),
                  behavior: SnackBarBehavior.floating,
                  backgroundColor: loops > 1.0 ? Colors.green : Colors.deepPurple,
                ),
              );
            }
          } catch (e) {
            print("Veri hatası: $e");
          }
        },
      )
      ..loadRequest(Uri.parse('https://m.youtube.com/shorts/'));
  }

  @override
  Widget build(BuildContext context) {
    // Stack ve Loading Indicator TAMAMEN silindi. Saf tarayıcı.
    return SafeArea(
      child: WebViewWidget(controller: _controller),
    );
  }
}

// ---- CANLI ANALİZ VE GEMİNİ EXPORT EKRANI ----
class AnalyticsDashboardScreen extends StatefulWidget {
  const AnalyticsDashboardScreen({super.key});

  @override
  State<AnalyticsDashboardScreen> createState() => _AnalyticsDashboardScreenState();
}

class _AnalyticsDashboardScreenState extends State<AnalyticsDashboardScreen> {
  List<Map<String, dynamic>> _logs = [];
  int totalVideos = 0;
  int skipCount = 0;
  int loopCount = 0;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final logs = await DatabaseHelper.instance.fetchAllLogs();
    
    int skips = 0;
    int loops = 0;
    
    for (var log in logs) {
      double lCount = (log['loop_count'] as num?)?.toDouble() ?? 0.0;
      if (lCount > 0 && lCount < 0.3) skips++; 
      if (lCount > 1.0) loops++; 
    }

    if (mounted) {
      setState(() {
        _logs = logs;
        totalVideos = logs.length;
        skipCount = skips;
        loopCount = loops;
      });
    }
  }

  void _exportToGemini() {
    if (_logs.isEmpty) return;

    List<Map<String, dynamic>> compactLogs = _logs.map((e) => {
      "video_url": "https://youtube.com/shorts/${e['video_id']}",
      "dwell_time_sec": (e['dwell_time_ms'] / 1000).toStringAsFixed(1),
      "loop_count": (e['loop_count'] as num).toStringAsFixed(2),
    }).toList();

    String prompt = '''
Sen uzman bir davranışsal psikolog ve veri bilimcisin. Aşağıda sana kendi YouTube Shorts tüketim seansımın ham telemetri verilerini veriyorum. Bu verilerde "dwell_time_sec" videoda geçirdiğim süreyi, "loop_count" ise videoyu kaç kez başa sardığımı (1.0 = tam izlendi, 2.0 = iki kez izlendi vb.) gösteriyor.

Senden istediğim:
1. Linklerdeki YouTube Shorts videolarının içeriğine ve temalarına bak.
2. Benim dopamin döngümü analiz et. Hangi tür videolarda sabırsızım (loop_count < 0.5) ve sıkılıp geçmişim? Hangi tür videolara bağımlılık geliştirip (loop_count > 1.0) başa sarmışım?
3. Bana odak sürem ve dijital zaaflarım hakkında detaylı bilimsel bir profil çıkar.

İşte Verilerim:
${jsonEncode(compactLogs)}
''';

    Clipboard.setData(ClipboardData(text: prompt)).then((_) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("✨ Veriler Gemini için kopyalandı! Panoya yapıştırabilirsiniz."),
          backgroundColor: Colors.deepPurpleAccent,
          duration: Duration(seconds: 4),
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text("Bilişsel Haritanız", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                IconButton(icon: const Icon(Icons.refresh), onPressed: _loadData),
              ],
            ),
            const SizedBox(height: 16),
            
            Row(
              children: [
                Expanded(child: _buildStatCard("Toplam Video", "$totalVideos", Colors.blue)),
                const SizedBox(width: 8),
                Expanded(child: _buildStatCard("Hızlı Red", "$skipCount", Colors.redAccent)),
                const SizedBox(width: 8),
                Expanded(child: _buildStatCard("Hipnoz (Loop)", "$loopCount", Colors.green)),
              ],
            ),
            
            const SizedBox(height: 16),
            
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _exportToGemini,
                icon: const Icon(Icons.auto_awesome),
                label: const Text("Gemini ile Psikolojik Profilimi Çıkar"),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.deepPurple,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))
                ),
              ),
            ),
            
            const SizedBox(height: 16),
            const Text("Etkileşim Geçmişi", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const Divider(),
            Expanded(
              child: _logs.isEmpty 
                  ? const Center(child: Text("Veri yok. Lütfen Shorts'ta birkaç video kaydırın."))
                  : ListView.builder(
                      itemCount: _logs.length,
                      itemBuilder: (context, index) {
                        final log = _logs[index];
                        final loops = (log['loop_count'] as num?)?.toDouble() ?? 0.0;
                        final dwell = (log['dwell_time_ms'] as num) / 1000;
                        
                        return ListTile(
                          leading: Icon(
                            loops < 0.3 ? Icons.fast_forward : (loops > 1.0 ? Icons.repeat_on : Icons.play_arrow),
                            color: loops < 0.3 ? Colors.red : (loops > 1.0 ? Colors.green : Colors.grey),
                          ),
                          title: Text("Video ID: ${log['video_id']}"),
                          subtitle: Text("Süre: ${dwell.toStringAsFixed(1)}sn | Loop: ${loops.toStringAsFixed(2)}x"),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatCard(String title, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.2),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.5)),
      ),
      child: Column(
        children: [
          Text(value, style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: color)),
          const SizedBox(height: 4),
          Text(title, style: const TextStyle(fontSize: 11), textAlign: TextAlign.center),
        ],
      ),
    );
  }
}