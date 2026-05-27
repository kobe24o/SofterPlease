import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SofterPleaseApp());
}

class SofterPleaseApp extends StatelessWidget {
  const SofterPleaseApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SofterPlease',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2E7D64),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF6F7F4),
      ),
      home: const MonitorPage(),
    );
  }
}

class MonitorPage extends StatefulWidget {
  const MonitorPage({super.key});

  @override
  State<MonitorPage> createState() => _MonitorPageState();
}

class _MonitorPageState extends State<MonitorPage> {
  static const String _baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://10.0.2.2:8000',
  );

  final _nicknameController = TextEditingController(text: '家庭成员');
  final _transcriptController = TextEditingController();
  final _recorder = AudioRecorder();
  late final Dio _dio;

  String? _token;
  String? _userId;
  String? _familyId;
  String? _familyName;
  String? _sessionId;
  String? _recordPath;
  bool _isLoading = true;
  bool _isRecording = false;
  bool _isAnalyzing = false;
  EmotionResult? _latestResult;
  final List<EmotionResult> _history = [];

  @override
  void initState() {
    super.initState();
    _dio = Dio(
      BaseOptions(
        baseUrl: _baseUrl,
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 60),
      ),
    );
    _restoreSession();
  }

  @override
  void dispose() {
    _nicknameController.dispose();
    _transcriptController.dispose();
    _recorder.dispose();
    super.dispose();
  }

  Future<void> _restoreSession() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('token');
    final userId = prefs.getString('user_id');
    final familyId = prefs.getString('family_id');
    final familyName = prefs.getString('family_name');

    if (token != null && userId != null && familyId != null) {
      _token = token;
      _userId = userId;
      _familyId = familyId;
      _familyName = familyName ?? '我的家庭';
      _setAuthHeader(token);
    }

    setState(() => _isLoading = false);
  }

  void _setAuthHeader(String token) {
    _dio.options.headers['Authorization'] = 'Bearer $token';
  }

  Future<void> _createUserAndLogin() async {
    final nickname = _nicknameController.text.trim();
    if (nickname.isEmpty) {
      _showSnack('请输入昵称');
      return;
    }

    setState(() => _isLoading = true);
    try {
      final create = await _dio.post('/v1/users', data: {'nickname': nickname});
      final userId = create.data['user_id'] as String;
      final login = await _dio.post('/v1/auth/login', data: {'user_id': userId});
      final token = login.data['access_token'] as String;
      final families = (login.data['user']['families'] as List?) ?? [];
      if (families.isEmpty) {
        throw StateError('后端没有返回家庭信息');
      }

      final firstFamily = families.first as Map<String, dynamic>;
      _token = token;
      _userId = userId;
      _familyId = firstFamily['family_id'] as String;
      _familyName = firstFamily['family_name'] as String;
      _setAuthHeader(token);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('token', token);
      await prefs.setString('user_id', userId);
      await prefs.setString('family_id', _familyId!);
      await prefs.setString('family_name', _familyName!);
    } catch (error) {
      _showSnack('登录失败：$error');
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _startBackendSession() async {
    if (_familyId == null) return;
    setState(() => _isLoading = true);
    try {
      final response = await _dio.post('/v1/sessions/start', data: {
        'family_id': _familyId,
        'device_id': 'android-${DateTime.now().millisecondsSinceEpoch}',
        'device_type': 'android',
      });
      setState(() => _sessionId = response.data['session_id'] as String);
    } catch (error) {
      _showSnack('开始会话失败：$error');
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _endBackendSession() async {
    if (_sessionId == null) return;
    try {
      await _dio.post('/v1/sessions/end', data: {'session_id': _sessionId});
    } catch (_) {
      // 结束会话失败不影响本地退出。
    }
    setState(() {
      _sessionId = null;
      _latestResult = null;
      _history.clear();
    });
  }

  Future<void> _toggleRecording() async {
    if (_sessionId == null) {
      _showSnack('请先开始会话');
      return;
    }

    if (_isRecording) {
      await _stopAndAnalyze();
    } else {
      await _startRecording();
    }
  }

  Future<void> _startRecording() async {
    final hasPermission = await _recorder.hasPermission();
    if (!hasPermission) {
      _showSnack('需要麦克风权限');
      return;
    }

    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/softerplease_${DateTime.now().millisecondsSinceEpoch}.wav';
    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: 16000,
        numChannels: 1,
      ),
      path: path,
    );

    setState(() {
      _recordPath = path;
      _isRecording = true;
    });
  }

  Future<void> _stopAndAnalyze() async {
    final stoppedPath = await _recorder.stop();
    setState(() {
      _isRecording = false;
      _isAnalyzing = true;
      _recordPath = stoppedPath ?? _recordPath;
    });

    try {
      final path = _recordPath;
      if (path == null || !File(path).existsSync()) {
        throw StateError('录音文件不存在');
      }

      final formData = FormData.fromMap({
        'audio': await MultipartFile.fromFile(path, filename: 'segment.wav'),
        'transcript': _transcriptController.text.trim(),
        'speaker_id': _userId ?? 'android-user',
      });
      final response = await _dio.post('/v1/sessions/$_sessionId/analyze', data: formData);
      final result = EmotionResult.fromJson(response.data as Map<String, dynamic>);
      setState(() {
        _latestResult = result;
        _history.insert(0, result);
        if (_history.length > 12) {
          _history.removeLast();
        }
      });
    } catch (error) {
      _showSnack('分析失败：$error');
    } finally {
      if (mounted) {
        setState(() => _isAnalyzing = false);
      }
    }
  }

  Future<void> _logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    _dio.options.headers.remove('Authorization');
    setState(() {
      _token = null;
      _userId = null;
      _familyId = null;
      _familyName = null;
      _sessionId = null;
      _latestResult = null;
      _history.clear();
    });
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('SofterPlease'),
        actions: [
          if (_token != null)
            IconButton(
              onPressed: _logout,
              tooltip: '退出',
              icon: const Icon(Icons.logout),
            ),
        ],
      ),
      body: SafeArea(
        child: _token == null ? _buildLogin() : _buildMonitor(),
      ),
    );
  }

  Widget _buildLogin() {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const SizedBox(height: 48),
        const Icon(Icons.favorite, size: 72, color: Color(0xFF2E7D64)),
        const SizedBox(height: 16),
        const Text(
          '让家庭沟通更温柔',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 32),
        TextField(
          controller: _nicknameController,
          decoration: const InputDecoration(
            labelText: '昵称',
            prefixIcon: Icon(Icons.person_outline),
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _createUserAndLogin,
          icon: const Icon(Icons.arrow_forward),
          label: const Text('创建并进入'),
        ),
        const SizedBox(height: 16),
        Text(
          '后端地址：$_baseUrl',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  Widget _buildMonitor() {
    final result = _latestResult;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _StatusPanel(
          familyName: _familyName ?? '我的家庭',
          sessionId: _sessionId,
          result: result,
          isRecording: _isRecording,
          isAnalyzing: _isAnalyzing,
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _transcriptController,
          decoration: const InputDecoration(
            labelText: '可选转写文本',
            hintText: '例如：我们慢慢说，先别着急',
            prefixIcon: Icon(Icons.notes_outlined),
            border: OutlineInputBorder(),
          ),
          minLines: 1,
          maxLines: 3,
        ),
        const SizedBox(height: 16),
        if (_sessionId == null)
          FilledButton.icon(
            onPressed: _startBackendSession,
            icon: const Icon(Icons.play_arrow),
            label: const Text('开始会话'),
          )
        else
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _isAnalyzing ? null : _toggleRecording,
                  icon: Icon(_isRecording ? Icons.stop : Icons.mic),
                  label: Text(_isRecording ? '停止并分析' : '录一段语音'),
                ),
              ),
              const SizedBox(width: 12),
              IconButton.filledTonal(
                onPressed: _isRecording ? null : _endBackendSession,
                tooltip: '结束会话',
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        const SizedBox(height: 20),
        if (_history.isNotEmpty)
          Text('最近分析', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        for (final item in _history) _HistoryTile(result: item),
      ],
    );
  }
}

class _StatusPanel extends StatelessWidget {
  const _StatusPanel({
    required this.familyName,
    required this.sessionId,
    required this.result,
    required this.isRecording,
    required this.isAnalyzing,
  });

  final String familyName;
  final String? sessionId;
  final EmotionResult? result;
  final bool isRecording;
  final bool isAnalyzing;

  @override
  Widget build(BuildContext context) {
    final currentResult = result;
    final value = currentResult?.emotionValue ?? 0;
    final color = switch (value) {
      -1 => const Color(0xFFD9534F),
      1 => const Color(0xFF2E7D64),
      _ => const Color(0xFF607D8B),
    };
    final label = switch (value) {
      -1 => '负向',
      1 => '正向',
      _ => '中性',
    };

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  familyName,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              _StateChip(
                text: isRecording
                    ? '录音中'
                    : isAnalyzing
                        ? '分析中'
                        : sessionId == null
                            ? '未开始'
                            : '会话中',
                color: isRecording ? const Color(0xFFD9534F) : const Color(0xFF2E7D64),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Center(
            child: Container(
              width: 148,
              height: 148,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color.withValues(alpha: 0.1),
                border: Border.all(color: color, width: 8),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '$value',
                    style: TextStyle(fontSize: 42, color: color, fontWeight: FontWeight.w800),
                  ),
                  Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 18),
          if (currentResult == null)
            const Text('开始会话后录一段 2-8 秒的语音，后端会使用 CAiRE 模型返回 -1 / 0 / 1 情绪值。')
          else ...[
            _MetricRow(label: '效价 Valence', value: currentResult.valence.toStringAsFixed(3)),
            _MetricRow(label: '愤怒/紧张参考值', value: currentResult.angerScore.toStringAsFixed(3)),
            _MetricRow(label: '置信度', value: currentResult.confidence.toStringAsFixed(3)),
            _MetricRow(label: '模型', value: currentResult.modelBackend),
            if (currentResult.topLabels.isNotEmpty)
              Text(
                'Top: ${currentResult.topLabels.entries.take(3).map((e) => '${e.key} ${e.value.toStringAsFixed(2)}').join(' / ')}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
          ],
        ],
      ),
    );
  }
}

class _MetricRow extends StatelessWidget {
  const _MetricRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

class _StateChip extends StatelessWidget {
  const _StateChip({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(text, style: TextStyle(color: color, fontWeight: FontWeight.w700)),
    );
  }
}

class _HistoryTile extends StatelessWidget {
  const _HistoryTile({required this.result});

  final EmotionResult result;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: CircleAvatar(child: Text('${result.emotionValue}')),
        title: Text('Valence ${result.valence.toStringAsFixed(3)}'),
        subtitle: Text('level ${result.emotionLevel} · ${result.modelBackend}'),
        trailing: Text(result.confidence.toStringAsFixed(2)),
      ),
    );
  }
}

class EmotionResult {
  EmotionResult({
    required this.angerScore,
    required this.emotionLevel,
    required this.emotionValue,
    required this.valence,
    required this.confidence,
    required this.modelBackend,
    required this.topLabels,
  });

  final double angerScore;
  final String emotionLevel;
  final int emotionValue;
  final double valence;
  final double confidence;
  final String modelBackend;
  final Map<String, double> topLabels;

  factory EmotionResult.fromJson(Map<String, dynamic> json) {
    final dimensions = (json['emotion_dimensions'] as Map<String, dynamic>? ?? {});
    final raw = (json['raw_emotions'] as Map<String, dynamic>? ?? {})
        .map((key, value) => MapEntry(key, (value as num).toDouble()));
    final sorted = raw.entries.toList()..sort((a, b) => b.value.compareTo(a.value));

    return EmotionResult(
      angerScore: (json['anger_score'] as num).toDouble(),
      emotionLevel: json['emotion_level'] as String,
      emotionValue: (json['emotion_value'] as num?)?.toInt() ?? 0,
      valence: (dimensions['valence'] as num?)?.toDouble() ?? 0.0,
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0.0,
      modelBackend: json['model_backend'] as String? ?? 'unknown',
      topLabels: Map.fromEntries(sorted.take(5)),
    );
  }
}
