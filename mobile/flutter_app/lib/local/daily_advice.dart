import 'dart:convert';

import 'package:dio/dio.dart';

import 'local_session_store.dart';

abstract interface class LlmPromptRequest {
  String get transcript;
  List<Map<String, String>> messages();
}

final class DailyAdviceRequest implements LlmPromptRequest {
  const DailyAdviceRequest._({
    required this.day,
    required this.transcript,
    required this.conversationIds,
  });

  final DateTime day;
  @override
  final String transcript;
  final List<String> conversationIds;

  factory DailyAdviceRequest.forDay(
    DateTime day,
    Iterable<LocalSessionSummary> conversations,
  ) {
    final normalizedDay = DateTime(day.year, day.month, day.day);
    final selected = conversations.where((conversation) {
      final created = DateTime.tryParse(conversation.createdAt)?.toLocal();
      return created != null &&
          created.year == normalizedDay.year &&
          created.month == normalizedDay.month &&
          created.day == normalizedDay.day;
    }).toList(growable: false);
    final lines = <String>[];
    for (final conversation in selected) {
      if (conversation.utterances.isEmpty) {
        if (conversation.transcript.trim().isNotEmpty) {
          lines.add('${conversation.speakerLabel.ifEmpty('未知说话人')}：'
              '${conversation.transcript.trim()}');
        }
        continue;
      }
      for (final utterance in conversation.utterances) {
        if (utterance.transcript.trim().isEmpty) continue;
        lines.add('${utterance.speakerLabel.ifEmpty('未知说话人')}：'
            '${utterance.transcript.trim()}');
      }
    }
    return DailyAdviceRequest._(
      day: normalizedDay,
      transcript: lines.join('\n'),
      conversationIds: selected.map((item) => item.id).toList(growable: false),
    );
  }

  @override
  List<Map<String, String>> messages() => [
        {
          'role': 'system',
          'content': '你是一位重视尊重、倾听和非暴力沟通的家庭沟通教练。'
              '请根据当天对话，给出简短、具体、不过度诊断的中文建议。'
              '不要复述隐私内容，不要把情绪标签当作医学结论。'
              '请用简洁、手机友好的 Markdown 输出。',
        },
        {
          'role': 'user',
          'content': '以下是今天在本机整理的对话：\n$transcript',
        },
      ];
}

final class ConversationReviewRequest implements LlmPromptRequest {
  const ConversationReviewRequest._(this.transcript);

  @override
  final String transcript;

  factory ConversationReviewRequest.forConversation(
    LocalSessionSummary conversation,
  ) {
    final lines = conversation.utterances.isEmpty
        ? [
            '${conversation.speakerLabel.ifEmpty('未知说话人')}：'
                '${conversation.transcript.trim()}',
          ]
        : conversation.utterances
            .where((item) => item.transcript.trim().isNotEmpty)
            .map((item) => '${item.speakerLabel.ifEmpty('未知说话人')}：'
                '${item.transcript.trim()}')
            .toList(growable: false);
    return ConversationReviewRequest._(lines.join('\n'));
  }

  @override
  List<Map<String, String>> messages() => [
        {
          'role': 'system',
          'content': '你是家庭沟通教练。请只根据给出的文字判断表达风险，'
              '不要诊断人格或心理疾病，也不要把它当作语音情绪结论。'
              '用简洁、手机友好的 Markdown 输出，严格包含：'
              '“## 表达风险”“## 依据”“## 更温和的说法”三个小节。'
              '表达风险只能是低、中、高之一；没有风险时也要说明。',
        },
        {
          'role': 'user',
          'content': '请复核这一段本地转写：\n$transcript',
        },
      ];
}

final class DailyAdviceResponse {
  static String extract(Map<String, dynamic> data) {
    final choices = data['choices'];
    if (choices is! List || choices.isEmpty || choices.first is! Map) {
      throw const FormatException('模型未返回建议内容');
    }
    final message = Map<String, dynamic>.from(choices.first as Map)['message'];
    if (message is! Map) throw const FormatException('模型未返回建议内容');
    final content = Map<String, dynamic>.from(message)['content'];
    final text = switch (content) {
      String value => value.trim(),
      List value => value
          .whereType<Map>()
          .map((item) => item['text']?.toString() ?? '')
          .join()
          .trim(),
      _ => '',
    };
    if (text.isEmpty) throw const FormatException('模型未返回建议内容');
    return text;
  }
}

final class LlmSettings {
  const LlmSettings({
    this.baseUrl = 'https://apihub.agnes-ai.com/v1',
    this.model = 'agnes-2.5-flash',
  });

  final String baseUrl;
  final String model;

  Uri get completionsUri =>
      Uri.parse('${baseUrl.replaceFirst(RegExp(r'/+$'), '')}/chat/completions');

  Map<String, String> toJson() => {'base_url': baseUrl, 'model': model};

  factory LlmSettings.fromJson(Map<String, dynamic> json) => LlmSettings(
        baseUrl: json['base_url']?.toString().trim().isNotEmpty == true
            ? json['base_url'].toString().trim()
            : 'https://apihub.agnes-ai.com/v1',
        model: json['model']?.toString().trim().isNotEmpty == true
            ? json['model'].toString().trim()
            : 'agnes-2.5-flash',
      );
}

abstract interface class SecureTextStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

final class AdviceSettingsStore {
  AdviceSettingsStore(this._storage, this._secureStorage);

  static const _settingsKey = 'local_llm_settings_v1';
  static const apiKeyStorageKey = 'local_llm_api_key_v1';
  final LocalStringStorage _storage;
  final SecureTextStorage _secureStorage;

  Future<LlmSettings> loadSettings() async {
    final raw = await _storage.read(_settingsKey);
    if (raw == null || raw.isEmpty) return const LlmSettings();
    try {
      final json = jsonDecode(raw);
      return json is Map
          ? LlmSettings.fromJson(Map<String, dynamic>.from(json))
          : const LlmSettings();
    } on FormatException {
      return const LlmSettings();
    }
  }

  Future<void> save(LlmSettings settings, String apiKey) async {
    await _storage.write(_settingsKey, jsonEncode(settings.toJson()));
    final trimmedKey = apiKey.trim();
    if (trimmedKey.isNotEmpty) {
      await _secureStorage.write(apiKeyStorageKey, trimmedKey);
    }
  }

  Future<String?> readApiKey() => _secureStorage.read(apiKeyStorageKey);
}

final class OpenAiCompatibleAdviceClient {
  OpenAiCompatibleAdviceClient({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 20),
              receiveTimeout: const Duration(seconds: 90),
            ));

  final Dio _dio;

  Future<String> generate({
    required LlmPromptRequest request,
    required LlmSettings settings,
    required String apiKey,
  }) async {
    if (request.transcript.trim().isEmpty) {
      throw StateError('当天没有可发送的本地对话');
    }
    if (apiKey.trim().isEmpty) {
      throw StateError('请先在家庭页保存自己的模型 Key');
    }
    try {
      final response = await _dio.postUri<dynamic>(
        settings.completionsUri,
        data: {
          'model': settings.model,
          'messages': request.messages(),
          'temperature': 0.4,
        },
        options: Options(
          headers: {'Authorization': 'Bearer ${apiKey.trim()}'},
          responseType: ResponseType.json,
        ),
      );
      if (response.data is! Map) throw const FormatException('模型响应格式无效');
      return DailyAdviceResponse.extract(
          Map<String, dynamic>.from(response.data as Map));
    } on DioException catch (error) {
      throw StateError('模型连接失败：${error.message ?? '请检查地址、网络和 Key'}');
    }
  }
}

extension on String {
  String ifEmpty(String fallback) => trim().isEmpty ? fallback : trim();
}
