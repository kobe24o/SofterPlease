import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'local/bundled_model_installer.dart';
import 'local/conversation_models.dart';
import 'local/daily_advice.dart';
import 'local/local_session_store.dart';
import 'local/local_speech_analysis.dart';
import 'local/llm_review_queue.dart';
import 'local/model_pack.dart';
import 'update/android_update_bridge.dart';
import 'update/update_manifest.dart';
import 'update/update_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SofterPleaseApp());
}

final class _SharedPreferencesStorage implements LocalStringStorage {
  const _SharedPreferencesStorage(this.preferences);

  final SharedPreferences preferences;

  @override
  Future<String?> read(String key) async => preferences.getString(key);

  @override
  Future<void> write(String key, String value) async {
    await preferences.setString(key, value);
  }
}

final class _FlutterSecureTextStorage implements SecureTextStorage {
  const _FlutterSecureTextStorage(this.storage);

  final FlutterSecureStorage storage;

  @override
  Future<void> delete(String key) => storage.delete(key: key);

  @override
  Future<String?> read(String key) => storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      storage.write(key: key, value: value);
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
          seedColor: const Color(0xff2d6a57),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xfff7f8f5),
        cardTheme: const CardThemeData(
          elevation: 0,
          margin: EdgeInsets.zero,
          color: Colors.white,
        ),
      ),
      home: const _HomePage(),
    );
  }
}

class _HomePage extends StatefulWidget {
  const _HomePage();

  @override
  State<_HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<_HomePage> {
  static const _dailyAdviceKeyPrefix = 'local_daily_advice_v1_';
  final _recorder = AudioRecorder();
  final _player = AudioPlayer();
  final _analyzer = LocalSpeechAnalyzer();
  final _secureStorage = const FlutterSecureStorage();
  final _baseUrlController = TextEditingController();
  final _modelController = TextEditingController();
  final _apiKeyController = TextEditingController();
  late final LlmReviewQueue _reviewQueue;
  Timer? _recordingTimer;

  SharedPreferences? _preferences;
  LocalModelPack? _modelPack;
  List<LocalSessionSummary> _conversations = const [];
  List<SpeakerProfile> _profiles = const [];
  LlmSettings _llmSettings = const LlmSettings();
  UpdateCheckResult? _updateResult;
  PackageInfo? _packageInfo;
  String? _recordPath;
  String? _dailyAdvice;
  String _statusText = '正在准备本地模型…';
  int _tabIndex = 0;
  int _recordingSeconds = 0;
  bool _loading = true;
  bool _isRecording = false;
  bool _isAnalyzing = false;
  bool _isGeneratingAdvice = false;
  bool _isCheckingUpdate = false;
  bool _hasStoredApiKey = false;
  bool _obscureApiKey = true;

  @override
  void initState() {
    super.initState();
    _reviewQueue = LlmReviewQueue(
      loadAll: _loadAllConversations,
      save: _saveConversation,
      generate: _generateConversationReview,
    );
    unawaited(_loadLocalState());
  }

  @override
  void dispose() {
    _recordingTimer?.cancel();
    _reviewQueue.dispose();
    _recorder.dispose();
    _player.dispose();
    _baseUrlController.dispose();
    _modelController.dispose();
    _apiKeyController.dispose();
    super.dispose();
  }

  Future<void> _loadLocalState() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final storage = _SharedPreferencesStorage(preferences);
      final sessions = await LocalSessionStore(storage).loadAll();
      final profiles = await LocalSpeakerStore(storage).loadAll();
      final adviceSettings = AdviceSettingsStore(
        storage,
        _FlutterSecureTextStorage(_secureStorage),
      );
      final settings = await adviceSettings.loadSettings();
      final apiKey = await adviceSettings.readApiKey().timeout(
            const Duration(seconds: 2),
            onTimeout: () => null,
          );
      final packageInfo = await PackageInfo.fromPlatform().timeout(
        const Duration(seconds: 2),
        onTimeout: () => PackageInfo(
          appName: 'SofterPlease',
          packageName: 'com.softerplease.app',
          version: '2.3.1',
          buildNumber: '16',
        ),
      );
      final todayAdvice =
          preferences.getString(_dailyAdviceStorageKey(DateTime.now()));
      if (mounted) {
        setState(() {
          _preferences = preferences;
          _conversations = sessions;
          _profiles = profiles;
          _llmSettings = settings;
          _baseUrlController.text = settings.baseUrl;
          _modelController.text = settings.model;
          _hasStoredApiKey = apiKey?.isNotEmpty == true;
          _packageInfo = packageInfo;
          _dailyAdvice = todayAdvice;
          _statusText = '本地数据已就绪，正在安装离线模型…';
        });
      }
      unawaited(_installLocalModels());
      if (apiKey?.isNotEmpty == true) unawaited(_reviewQueue.resume());
    } catch (error) {
      if (mounted) {
        setState(() {
          _statusText = '本地初始化失败：${_message(error)}';
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _installLocalModels() async {
    try {
      final documents = await getApplicationDocumentsDirectory();
      final pack = await BundledModelInstaller.installIfNeeded(documents);
      if (mounted) {
        setState(() {
          _modelPack = pack;
          _statusText = pack.isInstalled
              ? '离线语音模型已就绪：录音、转写、情绪与声纹均在手机完成。'
              : '离线语音模型尚未就绪；录音仍会保存在本机。';
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() => _statusText = '模型准备失败：${_message(error)}');
      }
    }
  }

  Future<void> _startRecording() async {
    if (_isAnalyzing) return;
    if (!await _recorder.hasPermission()) {
      _showSnack('请允许麦克风权限后再录音');
      return;
    }
    if (!await _recorder.isEncoderSupported(AudioEncoder.wav)) {
      _showSnack('当前设备不支持 WAV 录音');
      return;
    }
    try {
      final root = await getApplicationDocumentsDirectory();
      final directory =
          Directory('${root.path}${Platform.pathSeparator}recordings');
      await directory.create(recursive: true);
      final path = '${directory.path}${Platform.pathSeparator}'
          'conversation_${DateTime.now().millisecondsSinceEpoch}.wav';
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 16000,
          numChannels: 1,
        ),
        path: path,
      );
      if (!mounted) return;
      setState(() {
        _recordPath = path;
        _isRecording = true;
        _recordingSeconds = 0;
        _statusText = '正在本机录音；不会上传到 SofterPlease 服务端。';
      });
      _recordingTimer?.cancel();
      _recordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted && _isRecording) setState(() => _recordingSeconds++);
      });
    } catch (error) {
      _showSnack('开始录音失败：${_message(error)}');
    }
  }

  Future<void> _stopAndAnalyze() async {
    _recordingTimer?.cancel();
    try {
      final stopped = await _recorder.stop();
      final path = stopped ?? _recordPath;
      if (path == null || !await File(path).exists()) {
        throw StateError('本地录音文件不存在');
      }
      if (mounted) {
        setState(() {
          _isRecording = false;
          _isAnalyzing = true;
          _recordPath = path;
          _statusText = '正在由手机本地模型切分、转写并识别声纹…';
        });
      }
      final duration = _estimateWavDuration(await File(path).length());
      final pack = _modelPack;
      if (pack?.isInstalled != true) {
        await _saveConversation(
          _summaryFor(path, duration.round()),
        );
        if (mounted) setState(() => _statusText = '录音已本地保存，模型就绪后可在对话页重新分析。');
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 16));
      final analysis =
          await _analyzer.analyze(audioPath: path, modelPack: pack!);
      final utterances = _assignKnownSpeakers(analysis.utterances);
      final conversation = _summaryFor(
        path,
        duration.round(),
        transcript: analysis.transcript,
        emotionValue: analysis.emotionValue,
        emotionLabel: analysis.emotionLabel,
        speakerLabel: analysis.speakerLabel,
        analysisState: 'completed',
        utterances: utterances,
      );
      await _saveConversation(conversation);
      unawaited(_enqueueReviewIfConfigured(conversation));
      if (mounted) {
        setState(() {
          _statusText = '本地分析完成：${analysis.speechSegmentCount} 段语音，'
              '${analysis.speakerLabel}。可在对话页纠正说话人。';
        });
      }
    } catch (error) {
      _showSnack('本地分析失败：${_message(error)}');
      if (mounted) setState(() => _statusText = '分析未完成；录音文件仍保存在本机。');
    } finally {
      if (mounted) setState(() => _isAnalyzing = false);
    }
  }

  LocalSessionSummary _summaryFor(
    String path,
    int duration, {
    String transcript = '',
    int emotionValue = 0,
    String emotionLabel = '',
    String speakerLabel = '',
    String analysisState = 'awaiting_model',
    List<LocalUtterance> utterances = const [],
  }) =>
      LocalSessionSummary(
        id: 'local_${DateTime.now().millisecondsSinceEpoch}',
        createdAt: DateTime.now().toUtc().toIso8601String(),
        audioPath: path,
        durationSeconds: duration,
        transcript: transcript,
        emotionValue: emotionValue,
        analysisState: analysisState,
        emotionLabel: emotionLabel,
        speakerLabel: speakerLabel,
        utterances: utterances,
      );

  List<LocalUtterance> _assignKnownSpeakers(List<LocalUtterance> utterances) {
    const matcher = SpeakerMatcher();
    return utterances.map((utterance) {
      final match = matcher.match(utterance.embedding, _profiles);
      return match == null
          ? utterance
          : utterance.copyWith(
              speakerId: match.profile.id,
              speakerLabel: match.profile.name,
            );
    }).toList(growable: false);
  }

  Future<void> _saveConversation(LocalSessionSummary conversation) async {
    final preferences = _preferences ?? await SharedPreferences.getInstance();
    await LocalSessionStore(_SharedPreferencesStorage(preferences))
        .save(conversation);
    final saved = await _loadAllConversations();
    if (mounted) setState(() => _conversations = saved);
  }

  Future<List<LocalSessionSummary>> _loadAllConversations() async {
    final preferences = _preferences ?? await SharedPreferences.getInstance();
    return LocalSessionStore(_SharedPreferencesStorage(preferences)).loadAll();
  }

  Future<void> _enqueueReviewIfConfigured(
    LocalSessionSummary conversation,
  ) async {
    final preferences = _preferences ?? await SharedPreferences.getInstance();
    final settingsStore = AdviceSettingsStore(
      _SharedPreferencesStorage(preferences),
      _FlutterSecureTextStorage(_secureStorage),
    );
    final key = await settingsStore.readApiKey();
    if (key?.trim().isEmpty ?? true) return;
    await _reviewQueue.enqueue(conversation);
  }

  Future<String> _generateConversationReview(
    LocalSessionSummary conversation,
  ) async {
    final preferences = _preferences ?? await SharedPreferences.getInstance();
    final settingsStore = AdviceSettingsStore(
      _SharedPreferencesStorage(preferences),
      _FlutterSecureTextStorage(_secureStorage),
    );
    final key = await settingsStore.readApiKey();
    return OpenAiCompatibleAdviceClient().generate(
      request: ConversationReviewRequest.forConversation(conversation),
      settings: _llmSettings,
      apiKey: key ?? '',
    );
  }

  Future<void> _reanalyze(LocalSessionSummary conversation) async {
    final pack = _modelPack;
    if (pack?.isInstalled != true) {
      _showSnack('本地模型尚未就绪，请稍后重试');
      return;
    }
    if (!await File(conversation.audioPath).exists()) {
      _showSnack('这条本地录音文件已不存在');
      return;
    }
    setState(() {
      _isAnalyzing = true;
      _statusText = '正在重新进行本地分析…';
    });
    try {
      final analysis = await _analyzer.analyze(
        audioPath: conversation.audioPath,
        modelPack: pack!,
      );
      final reanalyzed = conversation.copyWith(
        transcript: analysis.transcript,
        emotionValue: analysis.emotionValue,
        emotionLabel: analysis.emotionLabel,
        speakerLabel: analysis.speakerLabel,
        analysisState: 'completed',
        utterances: _assignKnownSpeakers(analysis.utterances),
        clearLlmReview: true,
      );
      await _saveConversation(reanalyzed);
      unawaited(_enqueueReviewIfConfigured(reanalyzed));
      if (mounted) setState(() => _statusText = '重新本地分析完成。');
    } catch (error) {
      _showSnack('重新分析失败：${_message(error)}');
    } finally {
      if (mounted) setState(() => _isAnalyzing = false);
    }
  }

  Future<void> _play(LocalSessionSummary conversation) async {
    if (!await File(conversation.audioPath).exists()) {
      _showSnack('这条本地录音文件已不存在');
      return;
    }
    try {
      await _player.stop();
      await _player.play(DeviceFileSource(conversation.audioPath));
    } catch (error) {
      _showSnack('播放失败：${_message(error)}');
    }
  }

  Future<void> _deleteConversations(
    List<LocalSessionSummary> conversations, {
    required String title,
  }) async {
    if (conversations.isEmpty) {
      _showSnack('没有符合条件的本地录音');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content:
            Text('将删除 ${conversations.length} 条本地录音及其转写、声纹和大模型复核结果。此操作无法恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final deletedIds = <String>[];
    for (final conversation in conversations) {
      try {
        final file = File(conversation.audioPath);
        if (await file.exists()) await file.delete();
        deletedIds.add(conversation.id);
      } catch (_) {
        // Keep the metadata when the user-visible recording could not be removed.
      }
    }
    if (deletedIds.isNotEmpty) {
      final preferences = _preferences ?? await SharedPreferences.getInstance();
      await LocalSessionStore(_SharedPreferencesStorage(preferences))
          .deleteByIds(deletedIds);
      final remaining = await _loadAllConversations();
      if (mounted) setState(() => _conversations = remaining);
    }
    _showSnack('已删除 ${deletedIds.length} 条本地录音。');
  }

  Future<void> _deleteByRetention(_RetentionDelete selection) async {
    final now = DateTime.now();
    final cutoff = switch (selection) {
      _RetentionDelete.thirtyDays => now.subtract(const Duration(days: 30)),
      _RetentionDelete.halfYear => DateTime(now.year, now.month - 6, now.day),
      _RetentionDelete.oneYear => DateTime(now.year - 1, now.month, now.day),
      _RetentionDelete.all => null,
    };
    final targets = cutoff == null
        ? _conversations
        : _conversations.where((conversation) {
            final createdAt = DateTime.tryParse(conversation.createdAt);
            return createdAt != null && createdAt.isBefore(cutoff);
          }).toList(growable: false);
    final title = switch (selection) {
      _RetentionDelete.thirtyDays => '删除 30 天前的录音',
      _RetentionDelete.halfYear => '删除半年前的录音',
      _RetentionDelete.oneYear => '删除一年前的录音',
      _RetentionDelete.all => '删除全部本地录音',
    };
    await _deleteConversations(targets, title: title);
  }

  Future<void> _correctSpeaker(
    LocalSessionSummary conversation,
    LocalUtterance utterance,
    SpeakerProfile profile,
  ) async {
    final sample = utterance.embedding;
    if (sample == null || sample.isEmpty) {
      _showSnack('该片段没有可用声纹，无法用于学习');
      return;
    }
    final preferences = _preferences ?? await SharedPreferences.getInstance();
    final updatedProfile = profile.withSample(sample, DateTime.now());
    await LocalSpeakerStore(_SharedPreferencesStorage(preferences))
        .save(updatedProfile);
    final updatedUtterances = conversation.utterances
        .map((item) => item.id == utterance.id
            ? item.copyWith(
                speakerId: updatedProfile.id,
                speakerLabel: updatedProfile.name,
              )
            : item)
        .toList(growable: false);
    await _saveConversation(
        conversation.copyWith(utterances: updatedUtterances));
    final profiles =
        await LocalSpeakerStore(_SharedPreferencesStorage(preferences))
            .loadAll();
    if (mounted) {
      setState(() {
        _profiles = profiles;
        _statusText = '已更正为“${updatedProfile.name}”，本地声纹特征已自动更新。';
      });
    }
  }

  Future<void> _showCorrectionSheet(
    LocalSessionSummary conversation,
    LocalUtterance utterance,
  ) async {
    final nameController = TextEditingController();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          20,
          20,
          MediaQuery.viewInsetsOf(sheetContext).bottom + 20,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('纠正说话人', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 6),
            Text('“${utterance.transcript}”会在本机归入所选成员，并更新该成员的本地声纹特征。'),
            const SizedBox(height: 12),
            for (final profile in _profiles)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.person_outline),
                title: Text(profile.name),
                subtitle: Text('${profile.sampleCount} 个本地声纹样本'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  unawaited(_correctSpeaker(conversation, utterance, profile));
                },
              ),
            const Divider(),
            TextField(
              controller: nameController,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                labelText: '新成员姓名',
                hintText: '例如：妈妈',
              ),
              onSubmitted: (_) => _createProfileFromCorrection(
                sheetContext,
                conversation,
                utterance,
                nameController.text,
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () => _createProfileFromCorrection(
                sheetContext,
                conversation,
                utterance,
                nameController.text,
              ),
              icon: const Icon(Icons.person_add_alt_1),
              label: const Text('创建并学习本地声纹'),
            ),
          ],
        ),
      ),
    );
    nameController.dispose();
  }

  Future<void> _createProfileFromCorrection(
    BuildContext sheetContext,
    LocalSessionSummary conversation,
    LocalUtterance utterance,
    String name,
  ) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    final embedding = utterance.embedding;
    if (embedding == null || embedding.isEmpty) {
      _showSnack('该片段没有可用声纹，无法创建成员');
      return;
    }
    Navigator.pop(sheetContext);
    final profile = SpeakerProfile(
      id: 'speaker_${DateTime.now().millisecondsSinceEpoch}',
      name: trimmed,
      centroid: embedding,
      sampleCount: 0,
      updatedAt: DateTime.now().toUtc().toIso8601String(),
    );
    await _correctSpeaker(conversation, utterance, profile);
  }

  Future<void> _saveLlmSettings() async {
    final baseUrl = _baseUrlController.text.trim();
    final model = _modelController.text.trim();
    if (!baseUrl.startsWith('https://') || model.isEmpty) {
      _showSnack('请填写 HTTPS 模型地址和模型名');
      return;
    }
    final settings = LlmSettings(baseUrl: baseUrl, model: model);
    final preferences = _preferences ?? await SharedPreferences.getInstance();
    await AdviceSettingsStore(
      _SharedPreferencesStorage(preferences),
      _FlutterSecureTextStorage(_secureStorage),
    ).save(settings, _apiKeyController.text);
    if (mounted) {
      setState(() {
        _llmSettings = settings;
        _hasStoredApiKey =
            _apiKeyController.text.trim().isNotEmpty || _hasStoredApiKey;
        _apiKeyController.clear();
      });
    }
    if (_hasStoredApiKey) unawaited(_reviewQueue.resume());
    _showSnack('模型设置已保存在本机；Key 已进入系统安全存储。');
  }

  Future<void> _generateDailyAdvice() async {
    if (_isGeneratingAdvice) return;
    final preferences = _preferences ?? await SharedPreferences.getInstance();
    final settingsStore = AdviceSettingsStore(
      _SharedPreferencesStorage(preferences),
      _FlutterSecureTextStorage(_secureStorage),
    );
    final apiKey = await settingsStore.readApiKey();
    final request = DailyAdviceRequest.forDay(DateTime.now(), _conversations);
    setState(() => _isGeneratingAdvice = true);
    try {
      final content = await OpenAiCompatibleAdviceClient().generate(
        request: request,
        settings: _llmSettings,
        apiKey: apiKey ?? '',
      );
      await preferences.setString(
          _dailyAdviceStorageKey(DateTime.now()), content);
      if (mounted) setState(() => _dailyAdvice = content);
    } catch (error) {
      _showSnack(_message(error));
    } finally {
      if (mounted) setState(() => _isGeneratingAdvice = false);
    }
  }

  Future<void> _checkForUpdate() async {
    final info = _packageInfo;
    if (info == null || _isCheckingUpdate) return;
    setState(() => _isCheckingUpdate = true);
    try {
      final result = await UpdateService().check(
        currentBuildNumber: int.tryParse(info.buildNumber) ?? 0,
      );
      if (mounted) setState(() => _updateResult = result);
    } finally {
      if (mounted) setState(() => _isCheckingUpdate = false);
    }
  }

  Future<void> _installUpdate(UpdateManifest manifest) async {
    try {
      _showSnack('正在下载并校验更新包…');
      final file = await UpdateService().download(manifest);
      await AndroidUpdateBridge.install(file, manifest);
    } catch (error) {
      _showSnack('更新失败：${_message(error)}');
    }
  }

  String _dailyAdviceStorageKey(DateTime day) =>
      '$_dailyAdviceKeyPrefix${day.year.toString().padLeft(4, '0')}${day.month.toString().padLeft(2, '0')}${day.day.toString().padLeft(2, '0')}';

  double _estimateWavDuration(int bytes) {
    final payload = bytes > 44 ? bytes - 44 : 0;
    return payload / (16000 * 2);
  }

  String _formatDuration(int seconds) =>
      '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';

  String _formatDate(String value) {
    final date = DateTime.tryParse(value)?.toLocal();
    if (date == null) return '本地记录';
    return '${date.month}月${date.day}日 ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }

  String _message(Object error) =>
      error.toString().replaceFirst('Bad state: ', '');

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final pages = [_recordPage(), _conversationPage(), _familyPage()];
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 18,
        title: const Text('SofterPlease'),
        actions: [
          IconButton(
            tooltip: '刷新本地状态',
            onPressed: _loading ? null : _loadLocalState,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(child: pages[_tabIndex]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tabIndex,
        onDestinationSelected: (index) => setState(() => _tabIndex = index),
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.mic_none),
              selectedIcon: Icon(Icons.mic),
              label: '记录'),
          NavigationDestination(
              icon: Icon(Icons.forum_outlined),
              selectedIcon: Icon(Icons.forum),
              label: '对话'),
          NavigationDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home),
              label: '家庭'),
        ],
      ),
    );
  }

  Widget _recordPage() => ListView(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 32),
        children: [
          Text('今天，慢一点说。', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          const Text('所有录音与声纹仅保存在本机；不会连接 SofterPlease 服务端。'),
          const SizedBox(height: 18),
          _SectionCard(
            child: Column(
              children: [
                Icon(
                  _isRecording ? Icons.graphic_eq : Icons.mic_none,
                  size: 54,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(height: 10),
                Text(
                  _isRecording
                      ? _formatDuration(_recordingSeconds)
                      : _isAnalyzing
                          ? '正在本地分析'
                          : '准备记录',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 6),
                Text(_statusText, textAlign: TextAlign.center),
                const SizedBox(height: 18),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(52)),
                  onPressed: _isAnalyzing
                      ? null
                      : _isRecording
                          ? _stopAndAnalyze
                          : _startRecording,
                  icon: Icon(
                      _isRecording ? Icons.stop_circle_outlined : Icons.mic),
                  label: Text(_isRecording ? '停止并在本机分析' : '开始本地录音'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _SectionCard(
            child: Row(
              children: [
                Icon(_modelPack?.isInstalled == true
                    ? Icons.offline_pin
                    : Icons.downloading_outlined),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(_modelPack?.isInstalled == true
                      ? '离线模型已安装：VAD、转写、情绪和声纹识别均可在手机上运行。'
                      : '正在准备随安装包附带的离线模型；录音会先安全地保存在手机。'),
                ),
              ],
            ),
          ),
        ],
      );

  Widget _conversationPage() => ListView(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 32),
        children: [
          Row(
            children: [
              Expanded(
                child: Text('本地对话',
                    style: Theme.of(context).textTheme.headlineSmall),
              ),
              PopupMenuButton<_RetentionDelete>(
                tooltip: '清理本地录音',
                onSelected: (selection) =>
                    unawaited(_deleteByRetention(selection)),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.delete_sweep_outlined, size: 18),
                      SizedBox(width: 4),
                      Text('清理录音'),
                    ],
                  ),
                ),
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: _RetentionDelete.thirtyDays,
                    child: Text('删除 30 天前的录音'),
                  ),
                  PopupMenuItem(
                    value: _RetentionDelete.halfYear,
                    child: Text('删除半年前的录音'),
                  ),
                  PopupMenuItem(
                    value: _RetentionDelete.oneYear,
                    child: Text('删除一年前的录音'),
                  ),
                  PopupMenuDivider(),
                  PopupMenuItem(
                    value: _RetentionDelete.all,
                    child: Text('删除全部录音'),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text('点开记录即可查看每句话、情绪标签，并纠正说话人。'),
          const SizedBox(height: 16),
          if (_conversations.isEmpty)
            const _EmptyState(icon: Icons.forum_outlined, text: '还没有本地对话记录。')
          else
            for (final conversation in _conversations) ...[
              _SectionCard(
                child: InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: () => _showConversationDetails(conversation),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                                child: Text(_formatDate(conversation.createdAt),
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium)),
                            _EmotionChip(
                                label: conversation.emotionLabel.isEmpty
                                    ? '待分析'
                                    : conversation.emotionLabel),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          conversation.transcript.isEmpty
                              ? '录音已保存，等待本地模型分析。'
                              : conversation.transcript,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Text(
                                '${_formatDuration(conversation.durationSeconds)} · ${conversation.utterances.length} 段'),
                            const Spacer(),
                            IconButton(
                                onPressed: () => _play(conversation),
                                icon: const Icon(Icons.play_arrow_outlined),
                                tooltip: '播放本地录音'),
                            IconButton(
                                onPressed: _isAnalyzing
                                    ? null
                                    : () => _reanalyze(conversation),
                                icon: const Icon(Icons.auto_awesome),
                                tooltip: '重新本地分析'),
                            IconButton(
                                onPressed: () => _deleteConversations(
                                      [conversation],
                                      title: '删除这条录音',
                                    ),
                                icon: const Icon(Icons.delete_outline),
                                tooltip: '删除本地录音'),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],
        ],
      );

  Future<void> _showConversationDetails(LocalSessionSummary conversation) =>
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (sheetContext) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.82,
          builder: (_, controller) => ListView(
            controller: controller,
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 36),
            children: [
              Text(_formatDate(conversation.createdAt),
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 6),
              const Text('声音情绪在本机完成；大模型复核会自动串行发送转写文本。点击每句可纠正说话人。'),
              const SizedBox(height: 16),
              if (conversation.llmReview != null) ...[
                _LlmReviewPanel(review: conversation.llmReview!),
                const SizedBox(height: 12),
              ],
              if (conversation.utterances.isEmpty)
                const _EmptyState(
                    icon: Icons.auto_awesome, text: '暂无逐段结果，可返回后重新本地分析。')
              else
                for (final utterance in conversation.utterances) ...[
                  _SectionCard(
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 4),
                      leading: CircleAvatar(
                          child: Text(utterance.speakerLabel.characters.first)),
                      title: Text(utterance.speakerLabel),
                      subtitle: Text(
                          '${utterance.transcript}\n${utterance.emotionLabel} · ${_formatDuration(utterance.startMilliseconds ~/ 1000)}'),
                      isThreeLine: true,
                      trailing: const Icon(Icons.edit_outlined),
                      onTap: () =>
                          _showCorrectionSheet(conversation, utterance),
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
            ],
          ),
        ),
      );

  Widget _familyPage() => ListView(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 32),
        children: [
          Text('家庭', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 6),
          const Text('成员声纹在本机持续学习；新对话会按顺序自动发送转写文本做表达风险复核。'),
          const SizedBox(height: 16),
          _SectionCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('本地成员',
                    style: TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 10),
                if (_profiles.isEmpty)
                  const Text('在“对话”中纠正任意一句说话人，即可创建成员并学习本地声纹。')
                else
                  for (final profile in _profiles)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.person_outline),
                      title: Text(profile.name),
                      subtitle: Text(
                          '${profile.sampleCount} 个本地声纹样本 · 最近更新 ${_formatDate(profile.updatedAt)}'),
                    ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _SectionCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('今日家庭沟通建议',
                    style: TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                const Text('仅当你点击生成时，才会把今天的本地转写发送给下方配置的模型服务。'),
                const SizedBox(height: 12),
                if (_dailyAdvice != null)
                  MarkdownBody(
                    data: _dailyAdvice!,
                    selectable: true,
                    styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)),
                  )
                else
                  const Text('今天尚未生成建议。'),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _isGeneratingAdvice ? null : _generateDailyAdvice,
                  icon: const Icon(Icons.auto_awesome),
                  label: Text(_isGeneratingAdvice ? '正在生成…' : '生成今日建议'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _SectionCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('你的大模型设置',
                    style: TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 10),
                TextField(
                    controller: _baseUrlController,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                        labelText: 'HTTPS Base URL',
                        hintText: 'https://apihub.agnes-ai.com/v1')),
                const SizedBox(height: 10),
                TextField(
                    controller: _modelController,
                    decoration: const InputDecoration(
                        labelText: '模型名', hintText: 'agnes-2.5-flash')),
                const SizedBox(height: 10),
                TextField(
                  controller: _apiKeyController,
                  obscureText: _obscureApiKey,
                  decoration: InputDecoration(
                    labelText:
                        _hasStoredApiKey ? 'API Key（已安全保存；留空不变）' : 'API Key',
                    suffixIcon: IconButton(
                        onPressed: () =>
                            setState(() => _obscureApiKey = !_obscureApiKey),
                        icon: Icon(_obscureApiKey
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined)),
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                    onPressed: _saveLlmSettings,
                    icon: const Icon(Icons.lock_outline),
                    label: const Text('仅保存到本机')),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _SectionCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('关于 · ${_packageInfo?.version ?? '—'}',
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                const Text('Android 离线优先版本。自动更新会校验签名、版本和 APK 哈希。'),
                const SizedBox(height: 10),
                if (_updateResult?.hasUpdate == true)
                  FilledButton.icon(
                      onPressed: () => _installUpdate(_updateResult!.manifest!),
                      icon: const Icon(Icons.system_update_alt),
                      label: Text('更新至 ${_updateResult!.manifest!.version}'))
                else
                  OutlinedButton.icon(
                      onPressed: _isCheckingUpdate ? null : _checkForUpdate,
                      icon: const Icon(Icons.system_update_alt),
                      label: Text(_isCheckingUpdate ? '正在检查…' : '检查应用更新')),
                if (_updateResult?.error != null)
                  Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(_updateResult!.error!,
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.error))),
              ],
            ),
          ),
        ],
      );
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(padding: const EdgeInsets.all(16), child: child),
      );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 52),
        child: Column(
          children: [
            Icon(icon, size: 44),
            const SizedBox(height: 12),
            Text(text)
          ],
        ),
      );
}

class _LlmReviewPanel extends StatelessWidget {
  const _LlmReviewPanel({required this.review});

  final LlmReview review;

  @override
  Widget build(BuildContext context) {
    final status = switch (review.status) {
      LlmReview.completed => '大模型复核完成',
      LlmReview.retryWaiting => '复核失败，正在退避重试',
      _ => '正在排队等待大模型复核',
    };
    return _SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.auto_awesome_outlined),
              const SizedBox(width: 8),
              Expanded(
                child: Text(status,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (review.content != null)
            MarkdownBody(
              data: review.content!,
              selectable: true,
              styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)),
            )
          else
            Text(review.lastError == null
                ? '请求将按顺序发送，避免超过模型服务限流。'
                : '上次失败：${review.lastError}'),
        ],
      ),
    );
  }
}

class _EmotionChip extends StatelessWidget {
  const _EmotionChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final color = switch (label) {
      '积极' => Colors.green.shade700,
      '消极' => Colors.orange.shade800,
      _ => Colors.blueGrey.shade700,
    };
    return Chip(
      label: Text(label),
      labelStyle: TextStyle(color: color, fontSize: 12),
      side: BorderSide.none,
      backgroundColor: color.withValues(alpha: 0.1),
    );
  }
}

enum _RetentionDelete { thirtyDays, halfYear, oneYear, all }
