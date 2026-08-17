import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'local/local_session_store.dart';
import 'local/model_pack.dart';
import 'update/android_update_bridge.dart';
import 'update/update_manifest.dart';
import 'update/update_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SofterPleaseApp());
}

final class _SharedPreferencesStorage implements LocalStringStorage {
  const _SharedPreferencesStorage(this._preferences);

  final SharedPreferences _preferences;

  @override
  Future<String?> read(String key) async => _preferences.getString(key);

  @override
  Future<void> write(String key, String value) async {
    await _preferences.setString(key, value);
  }
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
  final _familyMemberNameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _emailController = TextEditingController();
  final _transcriptController = TextEditingController();
  final _llmBaseUrlController =
      TextEditingController(text: 'https://api.openai.com/v1');
  final _llmModelController = TextEditingController(text: 'gpt-4o-mini');
  final _llmApiKeyController = TextEditingController();
  final _recorder = AudioRecorder();
  final _audioPlayer = AudioPlayer();
  final _secureStorage = const FlutterSecureStorage();
  late final Dio _dio;
  Future<String?>? _tokenRefreshFuture;
  Timer? _recordingTimer;

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
  bool _isLocalOnlySession = false;
  bool _isAnalyzing = false;
  bool _isGeneratingAdvice = false;
  bool _isTestingLlm = false;
  bool _isCheckingUpdate = false;
  bool _obscureApiKey = true;
  int _recordingSeconds = 0;
  int _maxRecordingSeconds = 600;
  double _modelSegmentSeconds = 25;
  EmotionResult? _latestResult;
  FamilyStats? _familyStats;
  DailyReport? _dailyReport;
  RangeReport? _rangeReport;
  String? _lastAudioDebug;
  String? _familyAdvice;
  String? _playingSegmentId;
  final List<EmotionResult> _history = [];
  List<ConversationSegmentResult> _segments = [];
  List<FamilyRole> _familyRoles = [];
  List<SpeakerStats> _speakerStats = [];
  List<LocalSessionSummary> _localSessions = [];
  LocalModelPack? _localModelPack;

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
    _familyMemberNameController.dispose();
    _phoneController.dispose();
    _emailController.dispose();
    _transcriptController.dispose();
    _llmBaseUrlController.dispose();
    _llmModelController.dispose();
    _llmApiKeyController.dispose();
    _recordingTimer?.cancel();
    _audioPlayer.dispose();
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
    _llmBaseUrlController.text =
        prefs.getString('llm_base_url') ?? 'https://api.openai.com/v1';
    _llmModelController.text = prefs.getString('llm_model') ?? 'gpt-4o-mini';
    _llmApiKeyController.text =
        await _secureStorage.read(key: 'llm_api_key') ?? '';

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
    await _loadLocalSessions();
    await _loadLocalModelPack();

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
    final response =
        await authDio.post('/v1/auth/login', data: {'user_id': userId});
    final data = response.data as Map<String, dynamic>;
    await _applyLogin(data);
    return _token;
  }

  Future<void> _saveBaseUrl() async {
    final baseUrl =
        _apiBaseUrlController.text.trim().replaceAll(RegExp(r'/+$'), '');
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
      final login =
          await _dio.post('/v1/auth/login', data: {'user_id': userId});
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
      await _loadFamilyRoles(showError: false);
      await _loadLatestAdvice(showError: false);
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
      final audio = data['audio'] as Map<String, dynamic>?;
      _maxRecordingSeconds =
          (audio?['max_recording_seconds'] as num?)?.toInt() ?? 600;
      _modelSegmentSeconds =
          (audio?['max_model_segment_seconds'] as num?)?.toDouble() ?? 25;
      if (mounted) setState(() {});
    } catch (error) {
      if (showError) _showSnack('读取模型状态失败：${_formatError(error)}');
    }
  }

  Future<void> _checkForUpdate() async {
    if (_isCheckingUpdate) return;
    setState(() => _isCheckingUpdate = true);
    try {
      final package = await PackageInfo.fromPlatform();
      final build = int.tryParse(package.buildNumber) ?? 0;
      final result = await UpdateService().check(currentBuildNumber: build);
      if (!mounted) return;
      final manifest = result.manifest;
      if (manifest == null) {
        _showSnack(result.error ?? '已经是最新版本');
        return;
      }
      await _showUpdateDialog(manifest);
    } catch (error) {
      _showSnack('检查更新失败：${_formatError(error)}');
    } finally {
      if (mounted) setState(() => _isCheckingUpdate = false);
    }
  }

  Future<void> _showUpdateDialog(UpdateManifest manifest) async {
    final download = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('发现新版本 ${manifest.version}'),
        content: Text(manifest.notes.isEmpty ? '已准备好安全更新。' : manifest.notes),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('稍后')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('下载更新')),
        ],
      ),
    );
    if (download != true || !mounted) return;
    setState(() => _isCheckingUpdate = true);
    try {
      final file = await UpdateService().download(manifest);
      await AndroidUpdateBridge.install(file, manifest);
    } catch (error) {
      _showSnack('安装更新失败：${_formatError(error)}');
    } finally {
      if (mounted) setState(() => _isCheckingUpdate = false);
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
        _dio.get('/v1/reports/daily/$_familyId',
            queryParameters: {'date': today}),
        _dio.get(
          '/v1/reports/family/$_familyId/range',
          queryParameters: {
            'start': '${_dateStamp(start)}T00:00:00',
            'end': '${_dateStamp(end)}T23:59:59',
          },
        ),
        _dio.get(
          '/v1/families/$_familyId/speaker-stats',
          queryParameters: {
            'days': 30,
            'timezone_offset_minutes': DateTime.now().timeZoneOffset.inMinutes,
          },
        ),
      ]);

      _familyStats =
          FamilyStats.fromJson(responses[0].data as Map<String, dynamic>);
      _dailyReport =
          DailyReport.fromJson(responses[1].data as Map<String, dynamic>);
      _rangeReport =
          RangeReport.fromJson(responses[2].data as Map<String, dynamic>);
      _speakerStats = (responses[3].data['speakers'] as List? ?? [])
          .map((item) => SpeakerStats.fromJson(item as Map<String, dynamic>))
          .toList();
      if (mounted) setState(() {});
    } catch (error) {
      if (showError) _showSnack('刷新统计失败：${_formatError(error)}');
    }
  }

  Future<void> _loadFamilyRoles({bool showError = true}) async {
    if (_familyId == null) return;
    try {
      final response = await _dio.get('/v1/families/$_familyId');
      final members = (response.data['members'] as List? ?? []);
      _familyRoles = members
          .map((item) => FamilyRole.fromJson(item as Map<String, dynamic>))
          .toList();
      if (mounted) setState(() {});
    } catch (error) {
      if (showError) _showSnack('读取家庭成员失败：${_formatError(error)}');
    }
  }

  Future<void> _addLocalFamilyMember() async {
    if (_familyId == null) {
      _showSnack('请先连接家庭');
      return;
    }
    final name = _familyMemberNameController.text.trim();
    if (name.isEmpty) {
      _showSnack('请输入家庭成员名称');
      return;
    }
    try {
      await _dio.post(
        '/v1/families/$_familyId/local-members',
        data: {'display_name': name},
      );
      _familyMemberNameController.clear();
      await Future.wait([
        _loadFamilyRoles(showError: false),
        _refreshStats(showError: false),
      ]);
      _showSnack('已添加家庭成员：$name');
    } catch (error) {
      _showSnack('添加家庭成员失败：${_formatError(error)}');
    }
  }

  Future<void> _clearSpeakerData(String scope) async {
    if (_familyId == null) return;
    final clearAll = scope == 'all';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(clearAll ? '清除全部说话人数据' : '清除说话人语音数据'),
        content: Text(clearAll
            ? '会清除所有逐句记录的说话人归属和已学习声纹，但保留文字、情绪和音频记录。'
            : '会清除已学习的声纹和自动说话人身份，保留已手动归属到家庭成员的记录。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('清除')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _dio.delete(
        '/v1/families/$_familyId/speaker-data',
        queryParameters: {'scope': scope},
      );
      if (clearAll) {
        setState(() {
          _segments = _segments
              .map((segment) => segment.copyWith(
                    speakerId: 'unknown',
                    speakerName: '未归属',
                    roleConfirmed: false,
                  ))
              .toList();
        });
      }
      await _refreshStats(showError: false);
      await _loadSystemInfo(showError: false);
      _showSnack(clearAll ? '已清除全部说话人数据' : '已清除说话人语音数据');
    } catch (error) {
      _showSnack('清除失败：${_formatError(error)}');
    }
  }

  Future<void> _saveLlmSettings({bool showConfirmation = true}) async {
    final baseUrl =
        _llmBaseUrlController.text.trim().replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.tryParse(baseUrl);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      _showSnack('请输入完整的大模型 Base URL');
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('llm_base_url', baseUrl);
    await prefs.setString('llm_model', _llmModelController.text.trim());
    await _secureStorage.write(
        key: 'llm_api_key', value: _llmApiKeyController.text.trim());
    _llmBaseUrlController.text = baseUrl;
    if (showConfirmation) {
      _showSnack('大模型配置已加密保存在本机');
    }
  }

  Future<void> _loadLatestAdvice({bool showError = false}) async {
    if (_familyId == null) return;
    try {
      final response = await _dio.get('/v1/advice/$_familyId');
      _familyAdvice = response.data['content'] as String?;
      if (mounted) setState(() {});
    } catch (error) {
      if (showError) _showSnack('读取建议失败：${_formatError(error)}');
    }
  }

  Future<void> _generateAdvice() async {
    if (!_isLoggedIn) {
      setState(() => _tabIndex = 2);
      _showSnack('请先连接服务器并登录');
      return;
    }
    final model = _llmModelController.text.trim();
    final baseUrl = _llmBaseUrlController.text.trim();
    if (model.isEmpty || baseUrl.isEmpty) {
      setState(() => _tabIndex = 2);
      _showSnack('请先在“我的”中配置大模型');
      return;
    }
    setState(() => _isGeneratingAdvice = true);
    try {
      await _saveLlmSettings(showConfirmation: false);
      final response = await _dio.post('/v1/advice/generate', data: {
        'family_id': _familyId,
        'timezone_offset_minutes': DateTime.now().timeZoneOffset.inMinutes,
        'provider': 'openai-compatible',
        'base_url': baseUrl,
        'model': model,
        'api_key': _llmApiKeyController.text.trim(),
      });
      _familyAdvice = response.data['content'] as String?;
      if (mounted) setState(() {});
    } catch (error) {
      _showSnack('生成建议失败：${_formatError(error)}');
    } finally {
      if (mounted) setState(() => _isGeneratingAdvice = false);
    }
  }

  Future<void> _testLlmConnection() async {
    final model = _llmModelController.text.trim();
    final baseUrl = _llmBaseUrlController.text.trim();
    if (!_isLoggedIn) {
      _showSnack('请先注册并登录');
      return;
    }
    if (model.isEmpty || baseUrl.isEmpty) {
      _showSnack('请填写 Base URL 和模型名称');
      return;
    }
    setState(() => _isTestingLlm = true);
    try {
      await _saveLlmSettings(showConfirmation: false);
      final response = await _dio.post('/v1/advice/test-connection', data: {
        'base_url': baseUrl,
        'model': model,
        'api_key': _llmApiKeyController.text.trim(),
      });
      _showSnack('大模型连接成功：${response.data['message']}');
    } catch (error) {
      _showSnack('大模型连接失败：${_formatError(error)}');
    } finally {
      if (mounted) setState(() => _isTestingLlm = false);
    }
  }

  Future<void> _renameSpeaker(SpeakerStats speaker) async {
    final controller = TextEditingController(text: speaker.displayName);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重命名说话人'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 64,
          decoration: const InputDecoration(
              labelText: '显示名称', border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('保存')),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty || _familyId == null) return;
    try {
      await _dio.patch(
        '/v1/families/$_familyId/speakers/${speaker.speakerId}',
        data: {'display_name': name},
      );
      await _refreshStats(showError: false);
      _showSnack('已重命名，后续相同音色会继续归到“$name”');
    } catch (error) {
      _showSnack('重命名失败：${_formatError(error)}');
    }
  }

  Future<void> _showSpeakerRecords(SpeakerStats speaker, SpeakerDay day) async {
    if (_familyId == null) return;
    try {
      final response = await _dio.get(
        '/v1/families/$_familyId/speaker-records',
        queryParameters: {
          'speaker_id': speaker.speakerId,
          'date': day.date,
          'timezone_offset_minutes': DateTime.now().timeZoneOffset.inMinutes,
        },
      );
      final records = (response.data['items'] as List? ?? [])
          .map((item) =>
              ConversationSegmentResult.fromJson(item as Map<String, dynamic>))
          .toList();
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (context) => _SpeakerRecordsSheet(
          speakerName: speaker.displayName,
          day: day,
          records: records,
          familyRoles: _familyRoles,
          playingSegmentId: _playingSegmentId,
          onPlay: _playSegment,
          onConfirm: _confirmSpeaker,
        ),
      );
    } catch (error) {
      _showSnack('读取说话记录失败：${_formatError(error)}');
    }
  }

  Future<void> _endBackendSession() async {
    if (_sessionId == null) return;
    if (_isLocalOnlySession) {
      setState(() {
        _sessionId = null;
        _isLocalOnlySession = false;
      });
      return;
    }
    try {
      await _dio.post('/v1/sessions/end', data: {'session_id': _sessionId});
    } catch (_) {
      // 结束失败不影响本地退出会话。
    }
    setState(() {
      _sessionId = null;
      _latestResult = null;
      _history.clear();
      _isLocalOnlySession = false;
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
      final root = await getApplicationDocumentsDirectory();
      final dir = Directory('${root.path}${Platform.pathSeparator}recordings');
      await dir.create(recursive: true);
      final path =
          '${dir.path}${Platform.pathSeparator}softerplease_${DateTime.now().millisecondsSinceEpoch}.wav';
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
        _recordingSeconds = 0;
        _lastAudioDebug = '录音中：${_shortPath(path)}';
      });
      _recordingTimer?.cancel();
      _recordingTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!mounted || !_isRecording) return;
        setState(() => _recordingSeconds++);
        if (_recordingSeconds >= _maxRecordingSeconds) _stopAndAnalyze();
      });
    } catch (error) {
      _showSnack('开始录音失败：${_formatError(error)}');
    }
  }

  Future<void> _stopAndAnalyze() async {
    _recordingTimer?.cancel();
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
        _lastAudioDebug =
            '本次录音：${audioSeconds.toStringAsFixed(2)} 秒，${(audioBytes / 1024).toStringAsFixed(1)} KB，16kHz mono WAV，${_shortPath(path)}';
      });

      if (_isLocalOnlySession) {
        await _saveLocalSession(
          path: path,
          durationSeconds: audioSeconds.round(),
        );
        setState(() {
          _lastAudioDebug = '录音已仅保存在本机；端侧语音识别接入后将在此离线分析。';
        });
        return;
      }

      final formData = FormData.fromMap({
        'audio':
            await MultipartFile.fromFile(path, filename: 'conversation.wav'),
      });
      final response = await _dio.post('/v1/sessions/$_sessionId/analyze-long',
          data: formData);
      final segmentData = (response.data['segments'] as List? ?? []);
      final segments = segmentData
          .map((item) =>
              ConversationSegmentResult.fromJson(item as Map<String, dynamic>))
          .toList();
      final result = segments.isEmpty ? null : segments.last.emotion;
      setState(() {
        _latestResult = result;
        _segments = segments;
        if (result != null) {
          _history.insert(0, result);
          if (_history.length > 12) _history.removeLast();
        }
        _lastAudioDebug =
            '已按 VAD 切分 ${segments.length} 句；单句模型上限 ${_modelSegmentSeconds.toStringAsFixed(0)} 秒';
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

  Future<void> _startLocalSession() async {
    setState(() {
      _sessionId = 'local_${DateTime.now().millisecondsSinceEpoch}';
      _isLocalOnlySession = true;
      _lastAudioDebug = '离线会话已开始：录音仅保存在本机。';
    });
  }

  Future<void> _saveLocalSession({
    required String path,
    required int durationSeconds,
  }) async {
    final preferences = await SharedPreferences.getInstance();
    final store = LocalSessionStore(_SharedPreferencesStorage(preferences));
    await store.save(LocalSessionSummary(
      id: _sessionId ?? 'local_${DateTime.now().millisecondsSinceEpoch}',
      createdAt: DateTime.now().toUtc().toIso8601String(),
      audioPath: path,
      durationSeconds: durationSeconds,
      transcript: '',
      emotionValue: 0,
    ));
    await _loadLocalSessions();
  }

  Future<void> _loadLocalSessions() async {
    final preferences = await SharedPreferences.getInstance();
    final store = LocalSessionStore(_SharedPreferencesStorage(preferences));
    final sessions = await store.loadAll();
    if (mounted) setState(() => _localSessions = sessions);
  }

  Future<void> _loadLocalModelPack() async {
    final documents = await getApplicationDocumentsDirectory();
    final pack = await LocalModelPack.inspect(documents);
    if (mounted) setState(() => _localModelPack = pack);
  }

  Future<void> _playLocalSession(LocalSessionSummary session) async {
    final file = File(session.audioPath);
    if (!await file.exists()) {
      _showSnack('本地录音文件已不存在');
      return;
    }
    try {
      await _audioPlayer.stop();
      await _audioPlayer.play(DeviceFileSource(file.path));
    } catch (error) {
      _showSnack('播放失败：${_formatError(error)}');
    }
  }

  Future<void> _playSegment(ConversationSegmentResult segment) async {
    try {
      setState(() => _playingSegmentId = segment.id);
      final response = await _dio.get<List<int>>(
        segment.audioUrl,
        options: Options(responseType: ResponseType.bytes),
      );
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/segment_${segment.id}.wav');
      await file.writeAsBytes(response.data ?? []);
      await _audioPlayer.stop();
      await _audioPlayer.play(DeviceFileSource(file.path));
      await _audioPlayer.onPlayerComplete.first;
    } catch (error) {
      _showSnack('播放失败：${_formatError(error)}');
    } finally {
      if (mounted) setState(() => _playingSegmentId = null);
    }
  }

  Future<void> _confirmSpeaker(
      ConversationSegmentResult segment, String userId) async {
    try {
      final response = await _dio.post(
        '/v1/conversation-segments/${segment.id}/confirm-speaker',
        data: {'user_id': userId},
      );
      final items = (response.data['items'] as List? ?? []);
      setState(() {
        _segments = items
            .map((item) => ConversationSegmentResult.fromJson(
                item as Map<String, dynamic>))
            .toList();
      });
      await _refreshStats(showError: false);
      _showSnack('已学习该音色，并归类 ${response.data['updated_count']} 句');
    } catch (error) {
      _showSnack('确认角色失败：${_formatError(error)}');
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
    await prefs.remove('token');
    await prefs.remove('user_id');
    await prefs.remove('nickname');
    await prefs.remove('family_id');
    await prefs.remove('family_name');
    if (apiBaseUrl.isNotEmpty) {
      await prefs.setString('api_base_url', apiBaseUrl);
    }
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
      _segments.clear();
      _familyRoles.clear();
      _speakerStats.clear();
      _familyAdvice = null;
    });
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  String _formatError(Object error) {
    if (error is DioException) {
      final data = error.response?.data;
      if (data is Map && data['detail'] != null) {
        return data['detail'].toString();
      }
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

  String _formatDuration(int seconds) {
    final minutes = (seconds ~/ 60).toString().padLeft(2, '0');
    final remainder = (seconds % 60).toString().padLeft(2, '0');
    return '$minutes:$remainder';
  }

  @override
  Widget build(BuildContext context) {
    final pages = [_buildMonitor(), _buildStats(), _buildProfile()];

    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset('assets/branding/softerplease-logo.png',
                width: 34, height: 34),
            const SizedBox(width: 9),
            const Text('SofterPlease'),
          ],
        ),
        actions: [
          IconButton(
            onPressed: () async {
              await _loadLocalSessions();
              await _loadLocalModelPack();
            },
            tooltip: '刷新本地数据',
            icon: const Icon(Icons.sync),
          ),
        ],
      ),
      body: SafeArea(
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : pages[_tabIndex],
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
          recordingSeconds: _recordingSeconds,
        ),
        const SizedBox(height: 16),
        _InfoPanel(
          title: '本地录音会话',
          body:
              '录音保留在手机；模型包就绪后，VAD、转写、情绪标签与说话人归属均在本机处理。最长 ${(_maxRecordingSeconds / 60).toStringAsFixed(0)} 分钟。',
          actionLabel: _sessionId == null ? '开始本地会话后录音' : '已准备好',
          onAction: _sessionId == null ? _startLocalSession : () {},
        ),
        const SizedBox(height: 16),
        if (_sessionId == null)
          FilledButton.icon(
            onPressed: _startLocalSession,
            icon: const Icon(Icons.play_arrow),
            label: const Text('开始本地会话'),
          )
        else
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _isAnalyzing ? null : _toggleRecording,
                  icon: Icon(_isRecording ? Icons.stop : Icons.mic),
                  label: Text(_isRecording
                      ? '停止并保存 ${_formatDuration(_recordingSeconds)}'
                      : '开始录音'),
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
        _LocalModelPackPanel(pack: _localModelPack),
        if (_segments.isNotEmpty) ...[
          const SizedBox(height: 20),
          Text('逐句记录',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          for (final segment in _segments)
            _SegmentCard(
              segment: segment,
              familyRoles: _familyRoles,
              isPlaying: _playingSegmentId == segment.id,
              onPlay: () => _playSegment(segment),
              onConfirm: (userId) => _confirmSpeaker(segment, userId),
            ),
        ],
        const SizedBox(height: 20),
        if (_history.isNotEmpty)
          Text('最近分析', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        for (final item in _history) _HistoryTile(result: item),
        if (_localSessions.isNotEmpty) ...[
          const SizedBox(height: 20),
          Text('本地离线录音',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          for (final session in _localSessions)
            Card(
              child: ListTile(
                leading: const Icon(Icons.phone_android_outlined),
                title: Text(session.transcript.isEmpty
                    ? (session.analysisState == 'awaiting_model'
                        ? '等待安装本地模型包'
                        : '本地录音')
                    : session.transcript),
                subtitle: Text(
                    '${session.durationSeconds} 秒 · ${session.createdAt}${session.speakerLabel.isEmpty ? '' : ' · ${session.speakerLabel}'}'),
                trailing: IconButton(
                  tooltip: '播放',
                  icon: const Icon(Icons.play_arrow),
                  onPressed: () => _playLocalSession(session),
                ),
              ),
            ),
        ],
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
          else ...[
            _StatsPanel(
              familyStats: _familyStats,
              dailyReport: _dailyReport,
              rangeReport: _rangeReport,
              onRefresh: () => _refreshStats(),
            ),
            const SizedBox(height: 16),
            _SpeakerStatsPanel(
              speakers: _speakerStats,
              onRename: _renameSpeaker,
              onOpenDay: _showSpeakerRecords,
              onClearVoice: () => _clearSpeakerData('voice'),
              onClearAll: () => _clearSpeakerData('all'),
            ),
            const SizedBox(height: 16),
            _AdvicePanel(
              content: _familyAdvice,
              isLoading: _isGeneratingAdvice,
              onGenerate: _generateAdvice,
            ),
          ],
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
              Text('可选服务器连接',
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700)),
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
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('关于',
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              const Text('SofterPlease · 家庭情绪语音助手'),
              const SizedBox(height: 4),
              const Text('版本信息以当前安装包为准；更新包经签名清单、哈希与 Android 包身份校验后安装。'),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _isCheckingUpdate ? null : _checkForUpdate,
                icon: _isCheckingUpdate
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.system_update_outlined),
                label: Text(_isCheckingUpdate ? '正在检查' : '检查更新'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _LocalModelPackPanel(pack: _localModelPack),
        const SizedBox(height: 16),
        _Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('家庭建议模型',
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text('兼容 OpenAI Chat Completions；Key 仅加密保存在本机，调用时临时发送。',
                  style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 12),
              TextField(
                controller: _llmBaseUrlController,
                decoration: const InputDecoration(
                    labelText: 'Base URL',
                    prefixIcon: Icon(Icons.dns_outlined),
                    border: OutlineInputBorder()),
                keyboardType: TextInputType.url,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _llmModelController,
                decoration: const InputDecoration(
                    labelText: '模型名称',
                    prefixIcon: Icon(Icons.smart_toy_outlined),
                    border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _llmApiKeyController,
                obscureText: _obscureApiKey,
                decoration: InputDecoration(
                  labelText: 'API Key',
                  prefixIcon: const Icon(Icons.key_outlined),
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    tooltip: _obscureApiKey ? '显示 Key' : '隐藏 Key',
                    onPressed: () =>
                        setState(() => _obscureApiKey = !_obscureApiKey),
                    icon: Icon(_obscureApiKey
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _isTestingLlm ? null : _testLlmConnection,
                      icon: _isTestingLlm
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.network_check_outlined),
                      label: Text(_isTestingLlm ? '测试中' : '测试连接'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _saveLlmSettings,
                      icon: const Icon(Icons.save_outlined),
                      label: const Text('保存配置'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('账号',
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700)),
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
        if (_isLoggedIn) ...[
          const SizedBox(height: 16),
          _Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('家庭成员',
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                for (final role in _familyRoles)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.person_outline),
                    title: Text(role.displayName),
                    subtitle: Text(role.userId),
                  ),
                const SizedBox(height: 8),
                TextField(
                  controller: _familyMemberNameController,
                  decoration: const InputDecoration(
                    labelText: '新增家庭成员',
                    prefixIcon: Icon(Icons.group_add_outlined),
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _addLocalFamilyMember,
                  icon: const Icon(Icons.add),
                  label: const Text('添加成员'),
                ),
              ],
            ),
          ),
        ],
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
    required this.recordingSeconds,
  });

  final String familyName;
  final String nickname;
  final String? sessionId;
  final EmotionResult? result;
  final bool isRecording;
  final bool isAnalyzing;
  final String? audioDebug;
  final int recordingSeconds;

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
                    Text(familyName,
                        style: Theme.of(context)
                            .textTheme
                            .titleLarge
                            ?.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    Text(nickname,
                        style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
              _StateChip(
                text: isRecording
                    ? '录音 ${_duration(recordingSeconds)}'
                    : isAnalyzing
                        ? '分析中'
                        : sessionId == null
                            ? '未开始'
                            : '会话中',
                color: isRecording
                    ? const Color(0xFFD9534F)
                    : const Color(0xFF2E7D64),
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
                  Text('$value',
                      style: TextStyle(
                          fontSize: 42,
                          color: color,
                          fontWeight: FontWeight.w800)),
                  Text(label,
                      style:
                          TextStyle(color: color, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 18),
          if (currentResult == null)
            const Text('开始录音后可自然对话，系统会自动切句、转写、识别情绪和区分说话人。')
          else ...[
            _MetricRow(
                label: '效价 Valence',
                value: currentResult.valence.toStringAsFixed(3)),
            _MetricRow(
                label: '愤怒/紧张参考值',
                value: currentResult.angerScore.toStringAsFixed(3)),
            _MetricRow(
                label: '置信度',
                value: currentResult.confidence.toStringAsFixed(3)),
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
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Colors.black54),
            ),
          ],
        ],
      ),
    );
  }

  String _duration(int seconds) {
    return '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
  }
}

class _LocalModelPackPanel extends StatelessWidget {
  const _LocalModelPackPanel({required this.pack});

  final LocalModelPack? pack;

  @override
  Widget build(BuildContext context) {
    final isInstalled = pack?.isInstalled == true;
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isInstalled ? Icons.verified_outlined : Icons.download_outlined,
                color: isInstalled
                    ? const Color(0xFF2E7D64)
                    : Colors.orange.shade800,
              ),
              const SizedBox(width: 8),
              Text('本地语音模型',
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 8),
          Text(pack?.message ?? '正在检查本地模型包…'),
          const SizedBox(height: 8),
          Text(
            isInstalled
                ? 'SenseVoice · Ten-VAD · 说话人模型将只在本机运行。'
                : '模型安装后，录音不会上传；未安装时仍可安全保存录音。',
            style: Theme.of(context).textTheme.bodySmall,
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
          _SectionHeader(
              title: '统计信息', actionIcon: Icons.refresh, onAction: onRefresh),
          _MetricGrid(items: [
            _MetricItem(
                '今日均值', ((today?.avgAngerScore ?? 0) * 100).toStringAsFixed(1)),
            _MetricItem('今日分析', '${today?.emotionEventCount ?? 0}'),
            _MetricItem('总会话', '${family?.totalSessions ?? 0}'),
            _MetricItem('成员', '${family?.memberCount ?? 0}'),
          ]),
          const SizedBox(height: 12),
          _MetricRow(
              label: '今日最高值',
              value: ((today?.maxAngerScore ?? 0) * 100).toStringAsFixed(1)),
          _MetricRow(
              label: '反馈接受率',
              value:
                  '${((today?.feedbackAcceptedRate ?? 0) * 100).toStringAsFixed(0)}%'),
          _MetricRow(
              label: '趋势',
              value: _trendLabel(today?.trendDirection ??
                  family?.improvementTrend ??
                  'stable')),
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

class _AdvicePanel extends StatelessWidget {
  const _AdvicePanel(
      {required this.content,
      required this.isLoading,
      required this.onGenerate});

  final String? content;
  final bool isLoading;
  final VoidCallback onGenerate;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.auto_awesome_outlined, color: Color(0xFF2E7D64)),
              const SizedBox(width: 8),
              Expanded(
                  child: Text('家庭沟通建议',
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700))),
              FilledButton.icon(
                onPressed: isLoading ? null : onGenerate,
                icon: isLoading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.auto_awesome),
                label: Text(isLoading ? '分析中' : '获取建议'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (content == null)
            const Text(
              '基于今天每位说话人的对话、情绪和近两周变化，分别生成可执行的家庭沟通与亲子成长建议。',
              style: TextStyle(height: 1.6, color: Colors.black54),
            )
          else
            MarkdownBody(
              data: content!,
              selectable: true,
              styleSheet: MarkdownStyleSheet(
                h1: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(fontWeight: FontWeight.w800),
                h2: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w800),
                h3: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(fontWeight: FontWeight.w700),
                p: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(height: 1.6),
                listBullet: Theme.of(context).textTheme.bodyMedium,
                blockquoteDecoration: const BoxDecoration(
                  color: Color(0xFFF1F5F2),
                  border: Border(
                      left: BorderSide(color: Color(0xFF2E7D64), width: 3)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SpeakerStatsPanel extends StatelessWidget {
  const _SpeakerStatsPanel(
      {required this.speakers,
      required this.onRename,
      required this.onOpenDay,
      required this.onClearVoice,
      required this.onClearAll});

  final List<SpeakerStats> speakers;
  final ValueChanged<SpeakerStats> onRename;
  final void Function(SpeakerStats speaker, SpeakerDay day) onOpenDay;
  final VoidCallback onClearVoice;
  final VoidCallback onClearAll;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('说话人详情',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700)),
          Align(
            alignment: Alignment.centerRight,
            child: PopupMenuButton<String>(
              tooltip: '清除说话人数据',
              icon: const Icon(Icons.delete_sweep_outlined),
              onSelected: (value) {
                if (value == 'voice') {
                  onClearVoice();
                } else if (value == 'all') {
                  onClearAll();
                }
              },
              itemBuilder: (context) => const [
                PopupMenuItem(value: 'voice', child: Text('清除语音数据')),
                PopupMenuItem(value: 'all', child: Text('清除全部数据')),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Text('点击日期可回听音频并查看文本与模型结果',
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 12),
          if (speakers.isEmpty)
            const Text('暂无已识别的说话人数据')
          else
            for (var index = 0; index < speakers.length; index++) ...[
              _SpeakerSummary(
                speaker: speakers[index],
                onRename: () => onRename(speakers[index]),
                onOpenDay: (day) => onOpenDay(speakers[index], day),
              ),
              if (index != speakers.length - 1) const Divider(height: 28),
            ],
        ],
      ),
    );
  }
}

class _SpeakerSummary extends StatelessWidget {
  const _SpeakerSummary(
      {required this.speaker, required this.onRename, required this.onOpenDay});

  final SpeakerStats speaker;
  final VoidCallback onRename;
  final ValueChanged<SpeakerDay> onOpenDay;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            CircleAvatar(
              backgroundColor: const Color(0xFFE1EEE8),
              child: Text(speaker.displayName.characters.first,
                  style: const TextStyle(
                      color: Color(0xFF2E7D64), fontWeight: FontWeight.w800)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(speaker.displayName,
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  Text('${speaker.utteranceCount} 句 · ID ${speaker.speakerId}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
            IconButton(
                onPressed: onRename,
                tooltip: '重命名说话人',
                icon: const Icon(Icons.edit_outlined)),
          ],
        ),
        const SizedBox(height: 10),
        for (final day in speaker.daily.take(14))
          _SpeakerDayRow(day: day, onTap: () => onOpenDay(day)),
      ],
    );
  }
}

class _SpeakerDayRow extends StatelessWidget {
  const _SpeakerDayRow({required this.day, required this.onTap});

  final SpeakerDay day;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scoreColor = day.emotionScore > 0
        ? const Color(0xFF16845B)
        : day.emotionScore < 0
            ? const Color(0xFFC43D3D)
            : const Color(0xFF607D8B);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 4),
        child: Row(
          children: [
            SizedBox(
                width: 58,
                child: Text(
                    day.date.length >= 10 ? day.date.substring(5) : day.date)),
            Expanded(
              child: Text(
                '正 ${day.positive}  中 ${day.neutral}  负 ${day.negative}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            Container(
              constraints: const BoxConstraints(minWidth: 38),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                  color: scoreColor.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(6)),
              child: Text(
                day.emotionScore > 0
                    ? '+${day.emotionScore}'
                    : '${day.emotionScore}',
                textAlign: TextAlign.center,
                style:
                    TextStyle(color: scoreColor, fontWeight: FontWeight.w800),
              ),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right, size: 20),
          ],
        ),
      ),
    );
  }
}

class _SpeakerRecordsSheet extends StatelessWidget {
  const _SpeakerRecordsSheet({
    required this.speakerName,
    required this.day,
    required this.records,
    required this.familyRoles,
    required this.playingSegmentId,
    required this.onPlay,
    required this.onConfirm,
  });

  final String speakerName;
  final SpeakerDay day;
  final List<ConversationSegmentResult> records;
  final List<FamilyRole> familyRoles;
  final String? playingSegmentId;
  final ValueChanged<ConversationSegmentResult> onPlay;
  final void Function(ConversationSegmentResult segment, String userId)
      onConfirm;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.86,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 12, 12),
              child: Row(
                children: [
                  Expanded(
                      child: Text('$speakerName · ${day.date}',
                          style: Theme.of(context)
                              .textTheme
                              .titleLarge
                              ?.copyWith(fontWeight: FontWeight.w800))),
                  IconButton(
                      onPressed: () => Navigator.pop(context),
                      tooltip: '关闭',
                      icon: const Icon(Icons.close)),
                ],
              ),
            ),
            Expanded(
              child: records.isEmpty
                  ? const Center(child: Text('当天暂无记录'))
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                      itemCount: records.length,
                      itemBuilder: (context, index) {
                        final record = records[index];
                        final color = record.emotion.emotionValue > 0
                            ? const Color(0xFF16845B)
                            : record.emotion.emotionValue < 0
                                ? const Color(0xFFC43D3D)
                                : const Color(0xFF607D8B);
                        return Card(
                          margin: const EdgeInsets.only(bottom: 10),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8)),
                          child: Padding(
                            padding: const EdgeInsets.all(14),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    IconButton.filledTonal(
                                        onPressed: () => onPlay(record),
                                        tooltip: '播放音频',
                                        icon: const Icon(Icons.play_arrow)),
                                    const SizedBox(width: 8),
                                    Expanded(
                                        child: Text(
                                            '${record.localTime} · ${record.timeRange}',
                                            style: const TextStyle(
                                                fontWeight: FontWeight.w700))),
                                    Text(record.emotion.emotionLabel,
                                        style: TextStyle(
                                            color: color,
                                            fontWeight: FontWeight.w800)),
                                    PopupMenuButton<String>(
                                      tooltip: '归属到家庭成员',
                                      icon: const Icon(
                                          Icons.person_search_outlined),
                                      onSelected: (userId) =>
                                          onConfirm(record, userId),
                                      itemBuilder: (context) => [
                                        for (final role in familyRoles)
                                          PopupMenuItem(
                                            value: role.userId,
                                            child: Text(role.displayName),
                                          ),
                                      ],
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Text(record.emotion.transcript.isEmpty
                                    ? '未识别到文本'
                                    : record.emotion.transcript),
                                const SizedBox(height: 8),
                                Text(
                                    '情绪值 ${record.emotion.emotionValue} · 置信度 ${record.emotion.confidence.toStringAsFixed(2)} · ${record.emotion.modelBackend}',
                                    style:
                                        Theme.of(context).textTheme.bodySmall),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SegmentCard extends StatelessWidget {
  const _SegmentCard({
    required this.segment,
    required this.familyRoles,
    required this.isPlaying,
    required this.onPlay,
    required this.onConfirm,
  });

  final ConversationSegmentResult segment;
  final List<FamilyRole> familyRoles;
  final bool isPlaying;
  final VoidCallback onPlay;
  final ValueChanged<String> onConfirm;

  @override
  Widget build(BuildContext context) {
    final color = switch (segment.emotion.emotionValue) {
      -1 => const Color(0xFFD9534F),
      1 => const Color(0xFF2E7D64),
      _ => const Color(0xFF607D8B),
    };
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                IconButton.filledTonal(
                  onPressed: isPlaying ? null : onPlay,
                  tooltip: '播放本句',
                  icon: isPlaying
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.play_arrow),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(segment.speakerName,
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                      Text(
                          '${segment.timeRange} · ${segment.emotion.emotionLabel}',
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: color)),
                    ],
                  ),
                ),
                if (segment.roleConfirmed)
                  const Tooltip(
                      message: '角色已确认',
                      child: Icon(Icons.verified_outlined,
                          color: Color(0xFF2E7D64)))
                else
                  PopupMenuButton<String>(
                    tooltip: '确认说话角色',
                    icon: const Icon(Icons.person_search_outlined),
                    onSelected: onConfirm,
                    itemBuilder: (context) => [
                      for (final role in familyRoles)
                        PopupMenuItem(
                            value: role.userId, child: Text(role.displayName)),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(segment.emotion.transcript.isEmpty
                ? '未识别到文字'
                : segment.emotion.transcript),
            const SizedBox(height: 8),
            Text(
              '情绪值 ${segment.emotion.emotionValue} · 置信度 ${segment.emotion.confidence.toStringAsFixed(2)} · ${segment.emotion.modelBackend}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoPanel extends StatelessWidget {
  const _InfoPanel(
      {required this.title,
      required this.body,
      required this.actionLabel,
      required this.onAction});

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
          Text(title,
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Text(body),
          const SizedBox(height: 12),
          OutlinedButton.icon(
              onPressed: onAction,
              icon: const Icon(Icons.person),
              label: Text(actionLabel)),
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
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 16,
              offset: const Offset(0, 8)),
        ],
      ),
      child: child,
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(
      {required this.title, required this.actionIcon, required this.onAction});

  final String title;
  final IconData actionIcon;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
            child: Text(title,
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700))),
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
            decoration: BoxDecoration(
                color: const Color(0xFFF1F5F2),
                borderRadius: BorderRadius.circular(8)),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(item.label,
                      style: Theme.of(context).textTheme.bodySmall),
                  Text(item.value,
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w800)),
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
          SizedBox(
              width: 54,
              child: Text(
                  day.date.length >= 7 ? day.date.substring(5) : day.date,
                  style: Theme.of(context).textTheme.bodySmall)),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(99),
              child: LinearProgressIndicator(
                value: value,
                minHeight: 10,
                backgroundColor: const Color(0xFFE6ECE8),
                color: value >= 0.7
                    ? const Color(0xFFD9534F)
                    : const Color(0xFF2E7D64),
              ),
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
              width: 42,
              child: Text((value * 100).toStringAsFixed(0),
                  textAlign: TextAlign.end)),
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
          borderRadius: BorderRadius.circular(999)),
      child: Text(text,
          style: TextStyle(color: color, fontWeight: FontWeight.w700)),
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

  String get emotionLabel => switch (emotionValue) {
        -1 => '负向',
        1 => '正向',
        _ => '中性',
      };

  factory EmotionResult.fromJson(Map<String, dynamic> json) {
    final dimensions =
        (json['emotion_dimensions'] as Map<String, dynamic>? ?? {});
    final raw = (json['raw_emotions'] as Map<String, dynamic>? ?? {}).map(
        (key, value) => MapEntry(key, value is num ? value.toDouble() : 0.0));
    final sorted = raw.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

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

class ConversationSegmentResult {
  const ConversationSegmentResult({
    required this.id,
    required this.speakerId,
    required this.createdAt,
    required this.startedAtMs,
    required this.endedAtMs,
    required this.audioUrl,
    required this.speakerName,
    required this.roleConfirmed,
    required this.emotion,
  });

  final String id;
  final String speakerId;
  final DateTime? createdAt;
  final int startedAtMs;
  final int endedAtMs;
  final String audioUrl;
  final String speakerName;
  final bool roleConfirmed;
  final EmotionResult emotion;

  ConversationSegmentResult copyWith({
    String? speakerId,
    String? speakerName,
    bool? roleConfirmed,
  }) {
    return ConversationSegmentResult(
      id: id,
      speakerId: speakerId ?? this.speakerId,
      createdAt: createdAt,
      startedAtMs: startedAtMs,
      endedAtMs: endedAtMs,
      audioUrl: audioUrl,
      speakerName: speakerName ?? this.speakerName,
      roleConfirmed: roleConfirmed ?? this.roleConfirmed,
      emotion: emotion,
    );
  }

  String get timeRange => '${_seconds(startedAtMs)} - ${_seconds(endedAtMs)}';
  String get localTime {
    final value = createdAt?.toLocal();
    if (value == null) return '--:--:--';
    return '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}:${value.second.toString().padLeft(2, '0')}';
  }

  static String _seconds(int milliseconds) {
    final seconds = milliseconds / 1000;
    return '${seconds.toStringAsFixed(1)}s';
  }

  factory ConversationSegmentResult.fromJson(Map<String, dynamic> json) {
    return ConversationSegmentResult(
      id: json['id'] as String,
      speakerId: json['resolved_speaker_id'] as String? ??
          json['speaker_cluster'] as String? ??
          'unknown',
      createdAt: DateTime.tryParse(json['created_at'] as String? ?? ''),
      startedAtMs: (json['started_at_ms'] as num?)?.toInt() ?? 0,
      endedAtMs: (json['ended_at_ms'] as num?)?.toInt() ?? 0,
      audioUrl: json['audio_url'] as String? ?? '',
      speakerName: json['resolved_speaker_name'] as String? ??
          json['speaker_cluster'] as String? ??
          '未知角色',
      roleConfirmed: json['role_confirmed'] == true,
      emotion: EmotionResult.fromJson(json),
    );
  }
}

class SpeakerStats {
  const SpeakerStats({
    required this.speakerId,
    required this.displayName,
    required this.utteranceCount,
    required this.emotionScore,
    required this.daily,
  });

  final String speakerId;
  final String displayName;
  final int utteranceCount;
  final int emotionScore;
  final List<SpeakerDay> daily;

  factory SpeakerStats.fromJson(Map<String, dynamic> json) {
    return SpeakerStats(
      speakerId: json['speaker_id'] as String,
      displayName:
          json['display_name'] as String? ?? json['speaker_id'] as String,
      utteranceCount: (json['utterance_count'] as num?)?.toInt() ?? 0,
      emotionScore: (json['emotion_score'] as num?)?.toInt() ?? 0,
      daily: (json['daily'] as List? ?? [])
          .map((item) => SpeakerDay.fromJson(item as Map<String, dynamic>))
          .toList(),
    );
  }
}

class SpeakerDay {
  const SpeakerDay({
    required this.date,
    required this.utteranceCount,
    required this.emotionScore,
    required this.positive,
    required this.neutral,
    required this.negative,
  });

  final String date;
  final int utteranceCount;
  final int emotionScore;
  final int positive;
  final int neutral;
  final int negative;

  factory SpeakerDay.fromJson(Map<String, dynamic> json) {
    final counts = json['emotion_counts'] as Map<String, dynamic>? ?? {};
    return SpeakerDay(
      date: json['date'] as String? ?? '',
      utteranceCount: (json['utterance_count'] as num?)?.toInt() ?? 0,
      emotionScore: (json['emotion_score'] as num?)?.toInt() ?? 0,
      positive: (counts['positive'] as num?)?.toInt() ?? 0,
      neutral: (counts['neutral'] as num?)?.toInt() ?? 0,
      negative: (counts['negative'] as num?)?.toInt() ?? 0,
    );
  }
}

class FamilyRole {
  const FamilyRole({required this.userId, required this.displayName});

  final String userId;
  final String displayName;

  factory FamilyRole.fromJson(Map<String, dynamic> json) {
    return FamilyRole(
      userId: json['user_id'] as String,
      displayName: json['display_name'] as String? ??
          json['nickname'] as String? ??
          '家庭成员',
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
      feedbackAcceptedRate:
          (json['feedback_accepted_rate'] as num?)?.toDouble() ?? 0.0,
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
