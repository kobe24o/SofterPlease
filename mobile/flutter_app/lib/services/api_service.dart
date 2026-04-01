import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../models/user.dart';
import '../models/family.dart';
import '../models/session.dart';
import '../models/emotion.dart';
import '../models/goal.dart';

class ApiService {
  static final ApiService _instance = ApiService._internal();
  factory ApiService() => _instance;
  ApiService._internal();

  late Dio _dio;
  String? _token;

  // API基础URL - 根据环境配置
  static const String baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://localhost:8000',
  );

  void initialize() {
    _dio = Dio(BaseOptions(
      baseUrl: baseUrl,
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(seconds: 30),
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      },
    ));

    // 添加拦截器
    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        if (_token != null) {
          options.headers['Authorization'] = 'Bearer $_token';
        }
        if (kDebugMode) {
          print('Request: ${options.method} ${options.path}');
        }
        return handler.next(options);
      },
      onResponse: (response, handler) {
        if (kDebugMode) {
          print('Response: ${response.statusCode}');
        }
        return handler.next(response);
      },
      onError: (error, handler) {
        if (kDebugMode) {
          print('Error: ${error.response?.statusCode} - ${error.message}');
        }
        return handler.next(error);
      },
    ));
  }

  void setToken(String? token) {
    _token = token;
  }

  // ========== 用户相关 ==========

  Future<User> createUser(String nickname, {String? phone, String? email}) async {
    final response = await _dio.post('/v1/users', data: {
      'nickname': nickname,
      'phone': phone,
      'email': email,
    });
    return User(
      id: response.data['user_id'],
      nickname: nickname,
    );
  }

  Future<AuthResponse> login(String userId) async {
    final response = await _dio.post('/v1/auth/login', data: {
      'user_id': userId,
    });
    return AuthResponse.fromJson(response.data);
  }

  Future<User> getMe() async {
    final response = await _dio.get('/v1/users/me');
    return User.fromJson(response.data);
  }

  // ========== 家庭相关 ==========

  Future<Family> createFamily(String name) async {
    final response = await _dio.post('/v1/families', data: {
      'name': name,
    });
    return Family(
      id: response.data['family_id'],
      name: name,
      inviteCode: response.data['invite_code'],
    );
  }

  Future<Family> joinFamily(String inviteCode) async {
    final response = await _dio.post('/v1/families/join', data: {
      'invite_code': inviteCode,
    });
    return Family(
      id: response.data['family_id'],
      name: response.data['family_name'],
    );
  }

  Future<Family> getFamily(String familyId) async {
    final response = await _dio.get('/v1/families/$familyId');
    return Family.fromJson(response.data);
  }

  Future<void> addFamilyMember(String familyId, String userId, {String role = 'member'}) async {
    await _dio.post('/v1/families/$familyId/members', data: {
      'user_id': userId,
      'role': role,
    });
  }

  // ========== 会话相关 ==========

  Future<Session> startSession(String familyId, String deviceId, {String deviceType = 'mobile'}) async {
    final response = await _dio.post('/v1/sessions/start', data: {
      'family_id': familyId,
      'device_id': deviceId,
      'device_type': deviceType,
    });
    return Session.fromJson(response.data);
  }

  Future<void> pauseSession(String sessionId) async {
    await _dio.post('/v1/sessions/$sessionId/pause');
  }

  Future<void> resumeSession(String sessionId) async {
    await _dio.post('/v1/sessions/$sessionId/resume');
  }

  Future<void> endSession(String sessionId) async {
    await _dio.post('/v1/sessions/end', data: {
      'session_id': sessionId,
    });
  }

  Future<Session> getSession(String sessionId) async {
    final response = await _dio.get('/v1/sessions/$sessionId');
    return Session.fromJson(response.data);
  }

  // ========== 情绪分析相关 ==========

  Future<EmotionAnalysisResult> analyzeEmotion(
    String sessionId, {
    required List<int> audioData,
    String transcript = '',
    String speakerId = 'unknown',
  }) async {
    final formData = FormData.fromMap({
      'audio': MultipartFile.fromBytes(audioData, filename: 'audio.wav'),
      'transcript': transcript,
      'speaker_id': speakerId,
    });

    final response = await _dio.post(
      '/v1/sessions/$sessionId/analyze',
      data: formData,
    );

    return EmotionAnalysisResult.fromJson(response.data);
  }

  Future<void> postFeedbackAction(String feedbackToken, String action) async {
    await _dio.post('/v1/feedback/actions', data: {
      'feedback_token': feedbackToken,
      'action': action,
    });
  }

  // ========== 报告相关 ==========

  Future<DailyReport> getDailyReport(String familyId, String date) async {
    final response = await _dio.get('/v1/reports/daily/$familyId?date=$date');
    return DailyReport.fromJson(response.data);
  }

  Future<TimeSeriesReport> getTimeSeriesReport(String sessionId) async {
    final response = await _dio.get('/v1/reports/timeseries/$sessionId');
    return TimeSeriesReport.fromJson(response.data);
  }

  Future<FamilyRangeReport> getFamilyRangeReport(
    String familyId,
    String start,
    String end,
  ) async {
    final response = await _dio.get(
      '/v1/reports/family/$familyId/range?start=$start&end=$end',
    );
    return FamilyRangeReport.fromJson(response.data);
  }

  // ========== 目标相关 ==========

  Future<Goal> createGoal(String familyId, Goal goal) async {
    final response = await _dio.post(
      '/v1/goals?family_id=$familyId',
      data: goal.toJson(),
    );
    return Goal(
      id: response.data['goal_id'],
      userId: '',
      familyId: familyId,
      goalType: goal.goalType,
      title: goal.title,
      description: goal.description,
      targetValue: goal.targetValue,
      unit: goal.unit,
      startDate: goal.startDate,
      endDate: goal.endDate,
    );
  }

  Future<List<Goal>> getGoals(String familyId) async {
    final response = await _dio.get('/v1/goals?family_id=$familyId');
    return (response.data['goals'] as List)
        .map((g) => Goal.fromJson(g))
        .toList();
  }

  // ========== 埋点相关 ==========

  Future<void> trackEvent(String eventName, {Map<String, dynamic>? properties}) async {
    await _dio.post('/v1/analytics/events', data: {
      'event_name': eventName,
      'properties': properties ?? {},
    });
  }

  // ========== 健康检查 ==========

  Future<bool> healthCheck() async {
    try {
      final response = await _dio.get('/health');
      return response.data['status'] == 'ok';
    } catch (e) {
      return false;
    }
  }
}

// 认证响应
class AuthResponse {
  final String accessToken;
  final int expiresIn;
  final User user;

  AuthResponse({
    required this.accessToken,
    required this.expiresIn,
    required this.user,
  });

  factory AuthResponse.fromJson(Map<String, dynamic> json) {
    return AuthResponse(
      accessToken: json['access_token'],
      expiresIn: json['expires_in'],
      user: User.fromJson(json['user']),
    );
  }
}
