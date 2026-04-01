import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart';

import '../models/emotion.dart';

import 'api_service.dart';

class WebSocketService {
  static final WebSocketService _instance = WebSocketService._internal();
  factory WebSocketService() => _instance;
  WebSocketService._internal();

  WebSocketChannel? _channel;
  final _messageController = StreamController<Map<String, dynamic>>.broadcast();
  final _connectionController = StreamController<bool>.broadcast();
  
  Timer? _reconnectTimer;
  Timer? _pingTimer;
  
  bool _isConnected = false;
  bool _shouldReconnect = true;
  int _reconnectAttempts = 0;
  static const int _maxReconnectAttempts = 5;
  static const Duration _reconnectDelay = Duration(seconds: 3);
  static const Duration _pingInterval = Duration(seconds: 30);

  String? _currentSessionId;
  String _baseUrl = 'ws://localhost:8000';
  bool _isInitialized = false;

  Stream<Map<String, dynamic>> get messageStream => _messageController.stream;
  Stream<bool> get connectionStream => _connectionController.stream;
  bool get isConnected => _isConnected;

  /// 初始化WebSocket服务，从ApiService获取基础URL
  void initialize() {
    if (_isInitialized) return;
    
    // 从ApiService获取基础URL并转换为WebSocket URL
    final apiBaseUrl = ApiService.baseUrl;
    setBaseUrl(apiBaseUrl);
    
    _isInitialized = true;
    
    if (kDebugMode) {
      print('WebSocketService initialized with baseUrl: $_baseUrl');
    }
  }

  void setBaseUrl(String url) {
    _baseUrl = url.replaceFirst('http', 'ws');
  }

  Future<void> connect() async {
    if (_isConnected) return;

    // 确保已初始化
    if (!_isInitialized) {
      initialize();
    }

    try {
      final wsUrl = '$_baseUrl/v1/realtime/ws';
      
      if (kDebugMode) {
        print('Connecting to WebSocket: $wsUrl');
      }

      _channel = IOWebSocketChannel.connect(
        wsUrl,
        pingInterval: _pingInterval,
      );

      _channel!.stream.listen(
        _onMessage,
        onError: _onError,
        onDone: _onDone,
      );

      _isConnected = true;
      _reconnectAttempts = 0;
      _connectionController.add(true);
      
      // 启动心跳
      _startPingTimer();

      if (kDebugMode) {
        print('WebSocket connected');
      }
    } catch (e) {
      if (kDebugMode) {
        print('WebSocket connection error: $e');
      }
      _handleReconnect();
    }
  }

  void disconnect() {
    _shouldReconnect = false;
    _cleanup();
  }

  void _cleanup() {
    _pingTimer?.cancel();
    _reconnectTimer?.cancel();
    _channel?.sink.close();
    _channel = null;
    _isConnected = false;
    _connectionController.add(false);
  }

  void _onMessage(dynamic message) {
    try {
      final data = jsonDecode(message as String);
      
      if (kDebugMode) {
        print('WebSocket message: $data');
      }

      _messageController.add(data);
    } catch (e) {
      if (kDebugMode) {
        print('Error parsing WebSocket message: $e');
      }
    }
  }

  void _onError(dynamic error) {
    if (kDebugMode) {
      print('WebSocket error: $error');
    }
    _isConnected = false;
    _connectionController.add(false);
  }

  void _onDone() {
    if (kDebugMode) {
      print('WebSocket closed');
    }
    _isConnected = false;
    _connectionController.add(false);
    
    if (_shouldReconnect) {
      _handleReconnect();
    }
  }

  void _handleReconnect() {
    if (_reconnectAttempts >= _maxReconnectAttempts) {
      if (kDebugMode) {
        print('Max reconnection attempts reached');
      }
      return;
    }

    _reconnectAttempts++;
    final delay = Duration(
      seconds: _reconnectDelay.inSeconds * pow(2, _reconnectAttempts - 1).toInt(),
    );

    if (kDebugMode) {
      print('Reconnecting in ${delay.inSeconds}s (attempt $_reconnectAttempts)');
    }

    _reconnectTimer = Timer(delay, () {
      connect();
    });
  }

  void _startPingTimer() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(_pingInterval, (_) {
      if (_isConnected) {
        send({
          'type': 'ping',
          'ts': DateTime.now().toIso8601String(),
        });
      }
    });
  }

  void send(Map<String, dynamic> message) {
    if (_isConnected && _channel != null) {
      final json = jsonEncode(message);
      _channel!.sink.add(json);
      
      if (kDebugMode) {
        print('WebSocket send: $json');
      }
    } else {
      if (kDebugMode) {
        print('Cannot send message: WebSocket not connected');
      }
    }
  }

  // ========== 业务方法 ==========

  void startSession(String sessionId) {
    _currentSessionId = sessionId;
  }

  void analyze({
    required String speakerId,
    required double angerScore,
    String transcript = '',
  }) {
    if (_currentSessionId == null) {
      if (kDebugMode) {
        print('Cannot analyze: no active session');
      }
      return;
    }

    send({
      'type': 'analyze',
      'session_id': _currentSessionId,
      'speaker_id': speakerId,
      'anger_score': angerScore,
      'transcript': transcript,
    });
  }

  void feedbackAction(String feedbackToken, String action) {
    send({
      'type': 'feedback_action',
      'feedback_token': feedbackToken,
      'action': action,
    });
  }

  void dispose() {
    disconnect();
    _messageController.close();
    _connectionController.close();
  }
}

// WebSocket消息类型
class WebSocketMessage {
  final String type;
  final Map<String, dynamic> data;

  WebSocketMessage({
    required this.type,
    required this.data,
  });

  factory WebSocketMessage.fromJson(Map<String, dynamic> json) {
    return WebSocketMessage(
      type: json['type'] as String,
      data: json,
    );
  }

  bool get isAnalysisResult => type == 'analysis_result';
  bool get isFeedbackConfirmed => type == 'feedback_action_confirmed';
  bool get isError => type == 'error';
  bool get isPong => type == 'pong';
}

// 分析结果
class AnalysisResult {
  final DateTime timestamp;
  final String sessionId;
  final String speakerId;
  final double angerScore;
  final String emotionLevel;
  final FeedbackMessage? feedback;

  AnalysisResult({
    required this.timestamp,
    required this.sessionId,
    required this.speakerId,
    required this.angerScore,
    required this.emotionLevel,
    this.feedback,
  });

  factory AnalysisResult.fromJson(Map<String, dynamic> json) {
    return AnalysisResult(
      timestamp: DateTime.parse(json['ts'] as String),
      sessionId: json['session_id'] as String,
      speakerId: json['speaker_id'] as String,
      angerScore: (json['anger_score'] as num).toDouble(),
      emotionLevel: json['emotion_level'] as String,
      feedback: json['feedback'] != null
          ? FeedbackMessage.fromJson(json['feedback'] as Map<String, dynamic>)
          : null,
    );
  }
}

// 反馈消息
class FeedbackMessage {
  final String token;
  final String level;
  final String message;
  final String strategy;
  final int durationSeconds;

  FeedbackMessage({
    required this.token,
    required this.level,
    required this.message,
    required this.strategy,
    required this.durationSeconds,
  });

  factory FeedbackMessage.fromJson(Map<String, dynamic> json) {
    return FeedbackMessage(
      token: json['token'] as String,
      level: json['level'] as String,
      message: json['message'] as String,
      strategy: json['strategy'] as String,
      durationSeconds: json['duration_seconds'] as int,
    );
  }
}
