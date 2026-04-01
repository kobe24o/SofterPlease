import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import '../providers/session_provider.dart';
import '../providers/emotion_provider.dart';
import '../services/websocket_service.dart';
import '../utils/theme.dart';
import '../widgets/emotion_gauge.dart';
import '../widgets/feedback_card.dart';

class RealtimeScreen extends StatefulWidget {
  const RealtimeScreen({super.key});

  @override
  State<RealtimeScreen> createState() => _RealtimeScreenState();
}

class _RealtimeScreenState extends State<RealtimeScreen> {
  final WebSocketService _wsService = WebSocketService();
  StreamSubscription? _messageSubscription;
  
  bool _isSessionActive = false;
  double _currentAngerScore = 0.0;
  String _currentEmotionLevel = 'calm';
  FeedbackMessage? _currentFeedback;
  
  final List<Map<String, dynamic>> _history = [];

  @override
  void initState() {
    super.initState();
    _initWebSocket();
  }

  void _initWebSocket() {
    _wsService.connect();
    
    _messageSubscription = _wsService.messageStream.listen((message) {
      if (message['type'] == 'analysis_result') {
        _handleAnalysisResult(message);
      } else if (message['type'] == 'feedback_action_confirmed') {
        setState(() {
          _currentFeedback = null;
        });
      }
    });
  }

  void _handleAnalysisResult(Map<String, dynamic> data) {
    setState(() {
      _currentAngerScore = (data['anger_score'] as num).toDouble();
      _currentEmotionLevel = data['emotion_level'] as String;
      
      if (data['feedback'] != null) {
        _currentFeedback = FeedbackMessage.fromJson(
          data['feedback'] as Map<String, dynamic>,
        );
      }
      
      _history.add({
        'timestamp': DateTime.now(),
        'anger_score': _currentAngerScore,
        'emotion_level': _currentEmotionLevel,
      });
      
      // 限制历史记录数量
      if (_history.length > 50) {
        _history.removeAt(0);
      }
    });
  }

  Future<void> _startSession() async {
    final authProvider = context.read<AuthProvider>();
    final sessionProvider = context.read<SessionProvider>();
    
    if (authProvider.currentFamily == null) return;
    
    final deviceId = 'mobile-${DateTime.now().millisecondsSinceEpoch}';
    
    try {
      final session = await sessionProvider.startSession(
        authProvider.currentFamily!.id,
        deviceId,
      );
      
      _wsService.startSession(session.sessionId);
      
      setState(() {
        _isSessionActive = true;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('开始会话失败: $e')),
        );
      }
    }
  }

  Future<void> _endSession() async {
    final sessionProvider = context.read<SessionProvider>();
    
    try {
      await sessionProvider.endSession();
      
      setState(() {
        _isSessionActive = false;
        _currentAngerScore = 0.0;
        _currentEmotionLevel = 'calm';
        _currentFeedback = null;
        _history.clear();
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('结束会话失败: $e')),
        );
      }
    }
  }

  void _onFeedbackAction(String action) {
    if (_currentFeedback != null) {
      _wsService.feedbackAction(_currentFeedback!.token, action);
      
      if (action == 'accepted') {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('已采纳建议'),
            backgroundColor: AppTheme.successColor,
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    _messageSubscription?.cancel();
    _wsService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('实时监测'),
        actions: [
          if (_isSessionActive)
            Container(
              margin: EdgeInsets.only(right: 16.w),
              padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 6.h),
              decoration: BoxDecoration(
                color: Colors.red.withOpacity(0.1),
                borderRadius: BorderRadius.circular(20.r),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8.w,
                    height: 8.w,
                    decoration: const BoxDecoration(
                      color: Colors.red,
                      shape: BoxShape.circle,
                    ),
                  ),
                  SizedBox(width: 6.w),
                  Text(
                    '监测中',
                    style: TextStyle(
                      fontSize: 12.sp,
                      color: Colors.red,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.all(16.w),
          child: Column(
            children: [
              // 情绪仪表盘
              EmotionGauge(
                angerScore: _currentAngerScore,
                emotionLevel: _currentEmotionLevel,
                size: 200.w,
              ),
              SizedBox(height: 24.h),
              
              // 当前状态
              Container(
                padding: EdgeInsets.symmetric(horizontal: 24.w, vertical: 12.h),
                decoration: BoxDecoration(
                  color: AppTheme.getEmotionColor(_currentEmotionLevel).withOpacity(0.1),
                  borderRadius: BorderRadius.circular(30.r),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      AppTheme.getEmotionEmoji(_currentEmotionLevel),
                      style: TextStyle(fontSize: 24.sp),
                    ),
                    SizedBox(width: 8.w),
                    Text(
                      AppTheme.getEmotionText(_currentEmotionLevel),
                      style: TextStyle(
                        fontSize: 18.sp,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.getEmotionColor(_currentEmotionLevel),
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(height: 24.h),
              
              // 反馈卡片
              if (_currentFeedback != null)
                FeedbackCard(
                  message: _currentFeedback!,
                  onAccept: () => _onFeedbackAction('accepted'),
                  onIgnore: () => _onFeedbackAction('ignored'),
                ),
              
              const Spacer(),
              
              // 控制按钮
              if (!_isSessionActive)
                ElevatedButton.icon(
                  onPressed: _startSession,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('开始会话'),
                  style: ElevatedButton.styleFrom(
                    padding: EdgeInsets.symmetric(horizontal: 48.w, vertical: 16.h),
                    minimumSize: Size(double.infinity, 56.h),
                  ),
                )
              else
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () {
                          // 模拟发送数据（测试用）
                          _wsService.analyze(
                            speakerId: 'user_${Random().nextInt(3)}',
                            angerScore: Random().nextDouble(),
                            transcript: '测试文本',
                          );
                        },
                        icon: const Icon(Icons.send),
                        label: const Text('发送测试'),
                      ),
                    ),
                    SizedBox(width: 16.w),
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: _endSession,
                        icon: const Icon(Icons.stop),
                        label: const Text('结束会话'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.errorColor,
                        ),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}
