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
  static const String _defaultBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://192.168.1.10:8000',
  );

  final _apiBaseUrlController = TextEditingController(text: _defaultBaseUrl);
  final _nicknameController = TextEditingController(text: '家庭成员');
  final _phoneController = TextEditingController();
  final _emailController = TextEditingController();
  final _transcriptController = TextEditingController();
  final _recorder = AudioRecorder();
  late final Dio _dio;
  Future<String?>? _tokenRefreshFuture;

  int _tabIndex = 0;
  String? _token;
  String? _userId;
  String? _nickname;
  String? _familyId;
  String? _familyName;
  String? _sessionId;
  String? _recordPath;
  bool _isLoading = true;
  bool _isRecording = false;
  bool _isAnalyzing = false;
  bool _isModelLoading = false;
  EmotionResult? _latestResult;
  FamilyStats? _familyStats;
  DailyReport? _dailyReport;
  RangeReport? _rangeReport;
  Map<String, dynamic>? _modelStatus;
  String? _lastAudioDebug;
  final List<EmotionResult> _history = [];

  bool get _isLoggedIn => _token != null && _familyId != null;

  @override
  void initState() {
    super.initState();
    _dio = Dio(
      BaseOptions(
        baseUrl: _defaultBaseUrl,
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(minutes: 10),
      ),
    );
    _configureAuthInterceptor();
    _restoreSession();
  }

  @override
  void dispose() {
    _apiBaseUrlController.dispose();
    _nicknameController.dispose();
    _phoneController.dispose();
    _emailController.dispose();
    _transcriptController.dispose();
    _recorder.dispose();
    super.dispose();
  }

  Future<void> _restoreSession() async {
    final prefs = await SharedPreferences.getInstance();
    final apiBaseUrl = prefs.getString('api_base_url') ?? _defaultBaseUrl;
    final token = prefs.getString('token');
    final userId = prefs.getString('user_id');
    final nickname = prefs.getString('nickname');
    final familyId = prefs.getString('family_id');
    final familyName = prefs.getString('family_name');

    _apiBaseUrlController.text = apiBaseUrl;
    _dio.options.baseUrl = apiBaseUrl;

    if (token != null && userId != null) {
      _token = token;
      _userId = userId;
      _nickname = nickname;
      _familyId = familyId;
      _familyName = familyName;
      _setAuthHeader(token);
      await _syncUserFromServer(showError: false);
    }
    await _loadSystemInfo(showError: false);

    if (mounted) {
      setState(() => _isLoading = false);
    }
  }

  void _setAuthHeader(String token) {
    _dio.options.headers['Authorization'] = 'Bearer $token';
  }

  void _configureAuthInterceptor() {
    _dio.interceptors.add(
      InterceptorsWrapper(
        onError: (error, handler) async {
          final request = error.requestOptions;
          final shouldRefresh = error.response?.statusCode == 401 &&
              request.path != '/v1/auth/login' &&
              request.extra['authRetried'] != true;

          if (!shouldRefresh) {
            handler.next(error);
            return;
          }

          try {
            final token = await _refreshAccessToken();
            if (token == null) {
              handler.next(error);
              return;
            }

            request.extra['authRetried'] = true;
            request.headers['Authorization'] = 'Bearer $token';
            final response = await _dio.fetch<dynamic>(request);
            handler.resolve(response);
          } catch (_) {
            handler.next(error);
          }
        },
      ),
    );
  }

  Future<String?> _refreshAccessToken() {
    final activeRefresh = _tokenRefreshFuture;
    if (activeRefresh != null) return activeRefresh;

    final refresh = _performTokenRefresh();
    _tokenRefreshFuture = refresh;
    return refresh.whenComplete(() {
      _tokenRefreshFuture = null;
    });
  }

  Future<String?> _performTokenRefresh() async {
    final prefs = await SharedPreferences.getInstance();
    final userId = _userId ?? prefs.getString('user_id');
    if (userId == null || userId.isEmpty) return null;

    final authDio = Dio(
      BaseOptions(
        baseUrl: _dio.options.baseUrl,
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 30),
      ),
    );
    final response = await authDio.post('/v1/auth/login', data: {'user_id': userId});
    final data = response.data as Map<String, dynamic>;
    await _applyLogin(data);
    return _token;
  }

  Future<void> _saveBaseUrl() async {
    final baseUrl = _apiBaseUrlController.text.trim().replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.tryParse(baseUrl);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw const FormatException('请输入完整后端地址，例如 http://192.168.1.10:8000');
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw const FormatException('后端地址必须以 http:// 或 https:// 开头');
    }

    _apiBaseUrlController.text = baseUrl;
    _dio.options.baseUrl = baseUrl;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('api_base_url', baseUrl);
  }

  Future<void> _connectServer() async {
    setState(() => _isLoading = true);
    try {
      await _saveBaseUrl();
      await _loadSystemInfo(showError: true);
      _showSnack('服务器已连接');
    } catch (error) {
      _showSnack('连接失败：${_formatError(error)}');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _registerAndLogin() async {
    final nickname = _nicknameController.text.trim();
    if (nickname.isEmpty) {
      _showSnack('请输入昵称');
      return;
    }

    setState(() => _isLoading = true);
    try {
      await _saveBaseUrl();
      final payload = <String, dynamic>{'nickname': nickname};
      final phone = _phoneController.text.trim();
      final email = _emailController.text.trim();
      if (phone.isNotEmpty) payload['phone'] = phone;
      if (email.isNotEmpty) payload['email'] = email;

      final create = await _dio.post('/v1/users', data: payload);
      final userId = create.data['user_id'] as String;
      final login = await _dio.post('/v1/auth/login', data: {'user_id': userId});
      await _applyLogin(login.data as Map<String, dynamic>);
      await _syncUserFromServer(showError: false);
      setState(() => _tabIndex = 0);
    } catch (error) {
      _showSnack('注册或登录失败：${_formatError(error)}');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _applyLogin(Map<String, dynamic> loginData) async {
    final token = loginData['access_token'] as String;
    final user = loginData['user'] as Map<String, dynamic>;
    _token = token;
    _setAuthHeader(token);
    await _applyUser(user);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('token', token);
    await prefs.setString('user_id', _userId!);
  }

  Future<void> _applyUser(Map<String, dynamic> user) async {
    final families = (user['families'] as List?) ?? [];
    if (families.isEmpty) {
      throw StateError('后端没有返回家庭信息');
    }

    final firstFamily = families.first as Map<String, dynamic>;
    _userId = user['id'] as String;
    _nickname = user['nickname'] as String?;
    _familyId = firstFamily['family_id'] as String;
    _familyName = firstFamily['family_name'] as String;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('user_id', _userId!);
    await prefs.setString('family_id', _familyId!);
    await prefs.setString('family_name', _familyName!);
    if (_nickname != null) await prefs.setString('nickname', _nickname!);
  }

  Future<void> _syncUserFromServer({bool showError = true}) async {
    if (_token == null) return;
    try {
      final response = await _dio.get('/v1/users/me');
      await _applyUser(response.data as Map<String, dynamic>);
      await _refreshStats(showError: false);
      await _loadSystemInfo(showError: false);
      if (mounted) setState(() {});
    } catch (error) {
      if (showError) _showSnack('同步用户信息失败：${_formatError(error)}');
    }
  }

  Future<void> _loadSystemInfo({bool showError = true}) async {
    try {
      final response = await _dio.get('/v1/system/info');
      final data = response.data as Map<String, dynamic>;
      _modelStatus = data['emotion_model'] as Map<String, dynamic>?;
      if (mounted) setState(() {});
    } catch (error) {
      if (showError) _showSnack('读取模型状态失败：${_formatError(error)}');
    }
  }

  Future<void> _preloadModel() async {
    setState(() => _isModelLoading = true);
    try {
      await _saveBaseUrl();
      final response = await _dio.post('/v1/system/emotion-model/load');
      final data = response.data as Map<String, dynamic>;
      _modelStatus = data['emotion_model'] as Map<String, dynamic>?;
      _showSnack(data['loaded'] == true ? '模型已加载' : '模型未加载，请查看状态错误');
    } catch (error) {
      _showSnack('预加载模型失败：${_formatError(error)}');
    } finally {
      if (mounted) setState(() => _isModelLoading = false);
    }
  }

  Future<void> _refreshStats({bool showError = true}) async {
    if (_familyId == null) return;
    try {
      final today = _dateStamp(DateTime.now());
      final end = DateTime.now();
      final start = end.subtract(const Duration(days: 6));
      final responses = await Future.wait([
        _dio.get('/v1/families/$_familyId/stats'),
        _dio.get('/v1/reports/daily/$_familyId', queryParameters: {'date': today}),
        _dio.get(
          '/v1/reports/family/$_familyId/range',
          queryParameters: {
            'start': '${_dateStamp(start)}T00:00:00',
            'end': '${_dateStamp(end)}T23:59:59',
          },
        ),
      ]);

      _familyStats = FamilyStats.fromJson(responses[0].data as Map<String, dynamic>);
      _dailyReport = DailyReport.fromJson(responses[1].data as Map<String, dynamic>);
      _rangeReport = RangeReport.fromJson(responses[2].data as Map<String, dynamic>);
      if (mounted) setState(() {});
    } catch (error) {
      if (showError) _showSnack('刷新统计失败：${_formatError(error)}');
    }
  }

  Future<void> _startBackendSession() async {
    if (!_isLoggedIn) {
      _showSnack('请先在“我的”页面连接服务器并注册');
      setState(() => _tabIndex = 2);
      return;
    }
    setState(() => _isLoading = true);
    try {
      final response = await _dio.post('/v1/sessions/start', data: {
        'family_id': _familyId,
        'device_id': 'android-${DateTime.now().millisecondsSinceEpoch}',
        'device_type': 'android',
      });
      setState(() => _sessionId = response.data['session_id'] as String);
      await _refreshStats(showError: false);
    } catch (error) {
      _showSnack('开始会话失败：${_formatError(error)}');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _endBackendSession() async {
    if (_sessionId == null) return;
    try {
      await _dio.post('/v1/sessions/end', data: {'session_id': _sessionId});
    } catch (_) {
      // 结束失败不影响本地退出会话。
    }
    setState(() {
      _sessionId = null;
      _latestResult = null;
      _history.clear();
    });
    await _refreshStats(showError: false);
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

    final supportsWav = await _recorder.isEncoderSupported(AudioEncoder.wav);
    if (!supportsWav) {
      _showSnack('当前设备不支持 WAV 录音编码');
      return;
    }

    try {
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
        _lastAudioDebug = '录音中：${_shortPath(path)}';
      });
    } catch (error) {
      _showSnack('开始录音失败：${_formatError(error)}');
    }
  }

  Future<void> _stopAndAnalyze() async {
    String? stoppedPath;
    try {
      stoppedPath = await _recorder.stop();
    } catch (error) {
      setState(() => _isRecording = false);
      _showSnack('停止录音失败：${_formatError(error)}');
      return;
    }

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

      final audioFile = File(path);
      final audioBytes = audioFile.lengthSync();
      if (audioBytes < 1024) {
        throw StateError('录音文件过小（$audioBytes bytes），请检查麦克风权限或输入设备');
      }

      final audioSeconds = _estimateWavSeconds(audioBytes);
      setState(() {
        _lastAudioDebug = '本次录音：${audioSeconds.toStringAsFixed(2)} 秒，${(audioBytes / 1024).toStringAsFixed(1)} KB，16kHz mono WAV，${_shortPath(path)}';
      });

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
        if (_history.length > 12) _history.removeLast();
      });
      await _refreshStats(showError: false);
      await _loadSystemInfo(showError: false);
    } catch (error) {
      setState(() {
        _lastAudioDebug = '录音/分析异常：${_formatError(error)}';
      });
      _showSnack('分析失败：${_formatError(error)}');
    } finally {
      if (mounted) setState(() => _isAnalyzing = false);
    }
  }

  double _estimateWavSeconds(int bytes) {
    const headerBytes = 44;
    const bytesPerSecond = 16000 * 2;
    final payloadBytes = bytes > headerBytes ? bytes - headerBytes : 0;
    return payloadBytes / bytesPerSecond;
  }

  String _shortPath(String path) {
    final normalized = path.replaceAll('\\', '/');
    final parts = normalized.split('/');
    if (parts.length <= 2) return normalized;
    return '${parts[parts.length - 2]}/${parts.last}';
  }

  Future<void> _logout() async {
    final prefs = await SharedPreferences.getInstance();
    final apiBaseUrl = _apiBaseUrlController.text.trim();
    await prefs.clear();
    if (apiBaseUrl.isNotEmpty) await prefs.setString('api_base_url', apiBaseUrl);
    _dio.options.headers.remove('Authorization');
    setState(() {
      _token = null;
      _userId = null;
      _nickname = null;
      _familyId = null;
      _familyName = null;
      _sessionId = null;
      _latestResult = null;
      _familyStats = null;
      _dailyReport = null;
      _rangeReport = null;
      _history.clear();
    });
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  String _formatError(Object error) {
    if (error is DioException) {
      final data = error.response?.data;
      if (data is Map && data['detail'] != null) return data['detail'].toString();
      return error.message ?? error.type.name;
    }
    return error.toString();
  }

  String _dateStamp(DateTime value) {
    final y = value.year.toString().padLeft(4, '0');
    final m = value.month.toString().padLeft(2, '0');
    final d = value.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  @override
  Widget build(BuildContext context) {
    final pages = [_buildMonitor(), _buildStats(), _buildProfile()];

    return Scaffold(
      appBar: AppBar(
        title: const Text('SofterPlease'),
        actions: [
          IconButton(
            onPressed: () async {
              await _loadSystemInfo(showError: false);
              await _syncUserFromServer(showError: false);
              await _refreshStats(showError: false);
            },
            tooltip: '刷新',
            icon: const Icon(Icons.sync),
          ),
        ],
      ),
      body: SafeArea(
        child: _isLoading ? const Center(child: CircularProgressIndicator()) : pages[_tabIndex],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tabIndex,
        onDestinationSelected: (index) => setState(() => _tabIndex = index),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.mic), label: '监测'),
          NavigationDestination(icon: Icon(Icons.bar_chart), label: '统计'),
          NavigationDestination(icon: Icon(Icons.person), label: '我的'),
        ],
      ),
    );
  }

  Widget _buildMonitor() {
    final result = _latestResult;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _StatusPanel(
          familyName: _familyName ?? '未连接家庭',
          nickname: _nickname ?? '游客模式',
          sessionId: _sessionId,
          result: result,
          isRecording: _isRecording,
          isAnalyzing: _isAnalyzing,
          audioDebug: _lastAudioDebug,
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
            label: Text(_isLoggedIn ? '开始会话' : '去我的页面连接服务器'),
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
        const SizedBox(height: 16),
        _ModelPanel(
          status: _modelStatus,
          latestBackend: result?.modelBackend,
          isLoading: _isModelLoading,
          onRefresh: () => _loadSystemInfo(),
          onPreload: _preloadModel,
        ),
        const SizedBox(height: 20),
        if (_history.isNotEmpty) Text('最近分析', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        for (final item in _history) _HistoryTile(result: item),
      ],
    );
  }

  Widget _buildStats() {
    return RefreshIndicator(
      onRefresh: () => _refreshStats(),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (!_isLoggedIn)
            _InfoPanel(
              title: '统计将在连接后同步',
              body: '你可以先浏览界面。连接服务器并注册后，这里会显示和 Web 端一致的家庭统计、今日数据和 7 天趋势。',
              actionLabel: '去我的页面',
              onAction: () => setState(() => _tabIndex = 2),
            )
          else
            _StatsPanel(
              familyStats: _familyStats,
              dailyReport: _dailyReport,
              rangeReport: _rangeReport,
              onRefresh: () => _refreshStats(),
            ),
        ],
      ),
    );
  }

  Widget _buildProfile() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('服务器', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 12),
              TextField(
                controller: _apiBaseUrlController,
                decoration: const InputDecoration(
                  labelText: '后端地址',
                  prefixIcon: Icon(Icons.cloud_queue),
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.url,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _connectServer,
                      icon: const Icon(Icons.link),
                      label: const Text('连接服务器'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _preloadModel,
                      icon: const Icon(Icons.memory),
                      label: Text(_isModelLoading ? '加载中' : '预加载模型'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _ModelPanel(
          status: _modelStatus,
          latestBackend: _latestResult?.modelBackend,
          isLoading: _isModelLoading,
          onRefresh: () => _loadSystemInfo(),
          onPreload: _preloadModel,
        ),
        const SizedBox(height: 16),
        _Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('账号', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 12),
              if (_isLoggedIn) ...[
                _MetricRow(label: '昵称', value: _nickname ?? '--'),
                _MetricRow(label: '家庭', value: _familyName ?? '--'),
                _MetricRow(label: '用户 ID', value: _userId ?? '--'),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _logout,
                  icon: const Icon(Icons.logout),
                  label: const Text('退出登录'),
                ),
              ] else ...[
                TextField(
                  controller: _nicknameController,
                  decoration: const InputDecoration(
                    labelText: '昵称',
                    prefixIcon: Icon(Icons.person_outline),
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _phoneController,
                  decoration: const InputDecoration(
                    labelText: '手机号（可选）',
                    prefixIcon: Icon(Icons.phone_outlined),
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.phone,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _emailController,
                  decoration: const InputDecoration(
                    labelText: '邮箱（可选）',
                    prefixIcon: Icon(Icons.mail_outline),
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.emailAddress,
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _registerAndLogin,
                  icon: const Icon(Icons.arrow_forward),
                  label: const Text('注册并登录'),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _StatusPanel extends StatelessWidget {
  const _StatusPanel({
    required this.familyName,
    required this.nickname,
    required this.sessionId,
    required this.result,
    required this.isRecording,
    required this.isAnalyzing,
    required this.audioDebug,
  });

  final String familyName;
  final String nickname;
  final String? sessionId;
  final EmotionResult? result;
  final bool isRecording;
  final bool isAnalyzing;
  final String? audioDebug;

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

    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(familyName, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    Text(nickname, style: Theme.of(context).textTheme.bodySmall),
                  ],
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
                  Text('$value', style: TextStyle(fontSize: 42, color: color, fontWeight: FontWeight.w800)),
                  Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 18),
          if (currentResult == null)
            const Text('连接服务器后开始会话，录一段 2-8 秒语音，后端会返回 -1 / 0 / 1 情绪值。')
          else ...[
            _MetricRow(label: '效价 Valence', value: currentResult.valence.toStringAsFixed(3)),
            _MetricRow(label: '愤怒/紧张参考值', value: currentResult.angerScore.toStringAsFixed(3)),
            _MetricRow(label: '置信度', value: currentResult.confidence.toStringAsFixed(3)),
            _MetricRow(label: '本次模型', value: currentResult.modelBackend),
            if (currentResult.transcript.isNotEmpty)
              _MetricRow(label: '识别文本', value: currentResult.transcript),
            if (currentResult.topLabels.isNotEmpty)
              Text(
                'Top: ${currentResult.topLabels.entries.take(3).map((e) => '${e.key} ${e.value.toStringAsFixed(2)}').join(' / ')}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
          ],
          if (audioDebug != null) ...[
            const SizedBox(height: 12),
            Text(
              audioDebug!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.black54),
            ),
          ],
        ],
      ),
    );
  }
}

class _ModelPanel extends StatelessWidget {
  const _ModelPanel({
    required this.status,
    required this.latestBackend,
    required this.isLoading,
    required this.onRefresh,
    required this.onPreload,
  });

  final Map<String, dynamic>? status;
  final String? latestBackend;
  final bool isLoading;
  final VoidCallback onRefresh;
  final VoidCallback onPreload;

  @override
  Widget build(BuildContext context) {
    final backend = status?['backend']?.toString() ?? '--';
    var loaded = false;
    if (backend == 'sensevoice') {
      loaded = status?['sensevoice_loaded'] == true;
    } else if (backend == 'caire') {
      loaded = status?['caire_loaded'] == true;
    } else if (backend == 'rule') {
      loaded = true;
    }
    final device = status?['device']?.toString() ?? '--';
    final cuda = status?['torch_cuda_available'] == true ? '可用' : '不可用';
    String? error;
    String? modelId;
    if (backend == 'sensevoice') {
      error = status?['sensevoice_load_error']?.toString();
      modelId = status?['sensevoice_model_id']?.toString();
    } else if (backend == 'caire') {
      error = status?['caire_load_error']?.toString();
      modelId = status?['caire_model_id']?.toString();
    }

    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionHeader(title: '模型状态', actionIcon: Icons.refresh, onAction: onRefresh),
          _MetricRow(label: '后端', value: backend),
          _MetricRow(label: '模型', value: modelId ?? '--'),
          _MetricRow(label: '设备', value: device),
          _MetricRow(label: 'CUDA', value: cuda),
          _MetricRow(label: '状态', value: loaded ? '已加载' : '未加载'),
          if (latestBackend != null) _MetricRow(label: '最近推理', value: latestBackend!),
          if (error != null && error.isNotEmpty)
            Text(error, maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Color(0xFFD9534F))),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: isLoading ? null : onPreload,
            icon: isLoading
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.memory),
            label: Text(isLoading ? '加载中' : '预加载模型'),
          ),
        ],
      ),
    );
  }
}

class _StatsPanel extends StatelessWidget {
  const _StatsPanel({
    required this.familyStats,
    required this.dailyReport,
    required this.rangeReport,
    required this.onRefresh,
  });

  final FamilyStats? familyStats;
  final DailyReport? dailyReport;
  final RangeReport? rangeReport;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final family = familyStats;
    final today = dailyReport;
    final range = rangeReport;

    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionHeader(title: '统计信息', actionIcon: Icons.refresh, onAction: onRefresh),
          _MetricGrid(items: [
            _MetricItem('今日均值', ((today?.avgAngerScore ?? 0) * 100).toStringAsFixed(1)),
            _MetricItem('今日分析', '${today?.emotionEventCount ?? 0}'),
            _MetricItem('总会话', '${family?.totalSessions ?? 0}'),
            _MetricItem('成员', '${family?.memberCount ?? 0}'),
          ]),
          const SizedBox(height: 12),
          _MetricRow(label: '今日最高值', value: ((today?.maxAngerScore ?? 0) * 100).toStringAsFixed(1)),
          _MetricRow(label: '反馈接受率', value: '${((today?.feedbackAcceptedRate ?? 0) * 100).toStringAsFixed(0)}%'),
          _MetricRow(label: '趋势', value: _trendLabel(today?.trendDirection ?? family?.improvementTrend ?? 'stable')),
          const SizedBox(height: 8),
          if (range == null || range.days.isEmpty)
            Text('暂无 7 天趋势数据', style: Theme.of(context).textTheme.bodySmall)
          else
            for (final day in range.days) _TrendBar(day: day),
        ],
      ),
    );
  }

  String _trendLabel(String value) {
    return switch (value) {
      'improving' => '改善',
      'worsening' => '升高',
      _ => '稳定',
    };
  }
}

class _InfoPanel extends StatelessWidget {
  const _InfoPanel({required this.title, required this.body, required this.actionLabel, required this.onAction});

  final String title;
  final String body;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Text(body),
          const SizedBox(height: 12),
          OutlinedButton.icon(onPressed: onAction, icon: const Icon(Icons.person), label: Text(actionLabel)),
        ],
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 16, offset: const Offset(0, 8)),
        ],
      ),
      child: child,
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.actionIcon, required this.onAction});

  final String title;
  final IconData actionIcon;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700))),
        IconButton(onPressed: onAction, tooltip: title, icon: Icon(actionIcon)),
      ],
    );
  }
}

class _MetricGrid extends StatelessWidget {
  const _MetricGrid({required this.items});

  final List<_MetricItem> items;

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisCount: 2,
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      childAspectRatio: 2.3,
      children: [
        for (final item in items)
          DecoratedBox(
            decoration: BoxDecoration(color: const Color(0xFFF1F5F2), borderRadius: BorderRadius.circular(8)),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(item.label, style: Theme.of(context).textTheme.bodySmall),
                  Text(item.value, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _MetricItem {
  const _MetricItem(this.label, this.value);

  final String label;
  final String value;
}

class _TrendBar extends StatelessWidget {
  const _TrendBar({required this.day});

  final RangeDay day;

  @override
  Widget build(BuildContext context) {
    final value = day.avgAngerScore.clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          SizedBox(width: 54, child: Text(day.date.length >= 7 ? day.date.substring(5) : day.date, style: Theme.of(context).textTheme.bodySmall)),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(99),
              child: LinearProgressIndicator(
                value: value,
                minHeight: 10,
                backgroundColor: const Color(0xFFE6ECE8),
                color: value >= 0.7 ? const Color(0xFFD9534F) : const Color(0xFF2E7D64),
              ),
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(width: 42, child: Text((value * 100).toStringAsFixed(0), textAlign: TextAlign.end)),
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
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(999)),
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
        subtitle: Text('愤怒强度 ${result.emotionLevel} · ${result.modelBackend}'),
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
    required this.transcript,
  });

  final double angerScore;
  final String emotionLevel;
  final int emotionValue;
  final double valence;
  final double confidence;
  final String modelBackend;
  final Map<String, double> topLabels;
  final String transcript;

  factory EmotionResult.fromJson(Map<String, dynamic> json) {
    final dimensions = (json['emotion_dimensions'] as Map<String, dynamic>? ?? {});
    final raw = (json['raw_emotions'] as Map<String, dynamic>? ?? {})
        .map((key, value) => MapEntry(key, value is num ? value.toDouble() : 0.0));
    final sorted = raw.entries.toList()..sort((a, b) => b.value.compareTo(a.value));

    return EmotionResult(
      angerScore: (json['anger_score'] as num).toDouble(),
      emotionLevel: json['emotion_level'] as String,
      emotionValue: (json['emotion_value'] as num?)?.toInt() ?? 0,
      valence: (dimensions['valence'] as num?)?.toDouble() ?? 0.0,
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0.0,
      modelBackend: json['model_backend'] as String? ?? 'unknown',
      topLabels: Map.fromEntries(sorted.take(5)),
      transcript: json['transcript'] as String? ?? '',
    );
  }
}

class FamilyStats {
  const FamilyStats({
    required this.memberCount,
    required this.totalSessions,
    required this.avgAngerScore,
    required this.improvementTrend,
  });

  final int memberCount;
  final int totalSessions;
  final double avgAngerScore;
  final String improvementTrend;

  factory FamilyStats.fromJson(Map<String, dynamic> json) {
    return FamilyStats(
      memberCount: (json['member_count'] as num?)?.toInt() ?? 0,
      totalSessions: (json['total_sessions'] as num?)?.toInt() ?? 0,
      avgAngerScore: (json['avg_anger_score'] as num?)?.toDouble() ?? 0.0,
      improvementTrend: json['improvement_trend'] as String? ?? 'stable',
    );
  }
}

class DailyReport {
  const DailyReport({
    required this.emotionEventCount,
    required this.avgAngerScore,
    required this.maxAngerScore,
    required this.feedbackAcceptedRate,
    required this.trendDirection,
  });

  final int emotionEventCount;
  final double avgAngerScore;
  final double maxAngerScore;
  final double feedbackAcceptedRate;
  final String trendDirection;

  factory DailyReport.fromJson(Map<String, dynamic> json) {
    return DailyReport(
      emotionEventCount: (json['emotion_event_count'] as num?)?.toInt() ?? 0,
      avgAngerScore: (json['avg_anger_score'] as num?)?.toDouble() ?? 0.0,
      maxAngerScore: (json['max_anger_score'] as num?)?.toDouble() ?? 0.0,
      feedbackAcceptedRate: (json['feedback_accepted_rate'] as num?)?.toDouble() ?? 0.0,
      trendDirection: json['trend_direction'] as String? ?? 'stable',
    );
  }
}

class RangeReport {
  const RangeReport({required this.days});

  final List<RangeDay> days;

  factory RangeReport.fromJson(Map<String, dynamic> json) {
    final days = (json['daily_data'] as List? ?? [])
        .map((item) => RangeDay.fromJson(item as Map<String, dynamic>))
        .toList();
    return RangeReport(days: days);
  }
}

class RangeDay {
  const RangeDay({
    required this.date,
    required this.eventCount,
    required this.avgAngerScore,
    required this.highEmotionCount,
  });

  final String date;
  final int eventCount;
  final double avgAngerScore;
  final int highEmotionCount;

  factory RangeDay.fromJson(Map<String, dynamic> json) {
    return RangeDay(
      date: json['date'] as String? ?? '',
      eventCount: (json['event_count'] as num?)?.toInt() ?? 0,
      avgAngerScore: (json['avg_anger_score'] as num?)?.toDouble() ?? 0.0,
      highEmotionCount: (json['high_emotion_count'] as num?)?.toInt() ?? 0,
    );
  }
}
