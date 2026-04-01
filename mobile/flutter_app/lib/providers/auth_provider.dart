import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/user.dart';
import '../models/family.dart';
import '../services/api_service.dart';

class AuthProvider extends ChangeNotifier {
  final ApiService _apiService = ApiService();
  
  bool _isLoading = true;
  bool _isAuthenticated = false;
  User? _user;
  Family? _currentFamily;
  String? _token;

  // Getters
  bool get isLoading => _isLoading;
  bool get isAuthenticated => _isAuthenticated;
  User? get user => _user;
  Family? get currentFamily => _currentFamily;
  String? get token => _token;

  AuthProvider() {
    _apiService.initialize();
    _checkAuthStatus();
  }

  // 检查登录状态
  Future<void> _checkAuthStatus() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedUserId = prefs.getString('user_id');
      final savedToken = prefs.getString('token');
      final savedFamilyId = prefs.getString('family_id');

      if (savedUserId != null && savedToken != null) {
        _token = savedToken;
        _apiService.setToken(savedToken);

        // 验证token并获取用户信息
        try {
          _user = await _apiService.getMe();
          _isAuthenticated = true;

          // 恢复当前家庭
          if (savedFamilyId != null && _user!.families.isNotEmpty) {
            final family = _user!.families.firstWhere(
              (f) => f.familyId == savedFamilyId,
              orElse: () => _user!.families.first,
            );
            _currentFamily = Family(
              id: family.familyId,
              name: family.familyName,
            );
          }
        } catch (e) {
          // Token无效，清除登录状态
          await logout();
        }
      }
    } catch (e) {
      if (kDebugMode) {
        print('Error checking auth status: $e');
      }
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  // 创建用户并登录
  Future<bool> createUser(String nickname, {String? phone, String? email}) async {
    try {
      _isLoading = true;
      notifyListeners();

      // 创建用户
      final newUser = await _apiService.createUser(nickname, phone: phone, email: email);
      
      // 登录获取token
      final authResponse = await _apiService.login(newUser.id);
      
      // 创建默认家庭
      final family = await _apiService.createFamily('我的家庭');

      // 保存状态
      _user = authResponse.user;
      _token = authResponse.accessToken;
      _currentFamily = family;
      _isAuthenticated = true;
      _apiService.setToken(_token);

      // 持久化
      await _saveAuthData();

      // 埋点
      await _apiService.trackEvent('user_created', {
        'nickname': nickname,
      });

      return true;
    } catch (e) {
      if (kDebugMode) {
        print('Error creating user: $e');
      }
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  // 登录
  Future<bool> login(String userId) async {
    try {
      _isLoading = true;
      notifyListeners();

      final authResponse = await _apiService.login(userId);
      
      _user = authResponse.user;
      _token = authResponse.accessToken;
      _isAuthenticated = true;
      _apiService.setToken(_token);

      // 获取用户详细信息
      _user = await _apiService.getMe();

      // 设置默认家庭
      if (_user!.families.isNotEmpty) {
        final familyMember = _user!.families.first;
        _currentFamily = Family(
          id: familyMember.familyId,
          name: familyMember.familyName,
        );
      }

      await _saveAuthData();

      await _apiService.trackEvent('user_login');

      return true;
    } catch (e) {
      if (kDebugMode) {
        print('Error logging in: $e');
      }
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  // 退出登录
  Future<void> logout() async {
    try {
      await _apiService.trackEvent('user_logout');
    } catch (e) {
      // 忽略埋点错误
    }

    _user = null;
    _token = null;
    _currentFamily = null;
    _isAuthenticated = false;
    _apiService.setToken(null);

    // 清除持久化数据
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('user_id');
    await prefs.remove('token');
    await prefs.remove('family_id');

    notifyListeners();
  }

  // 切换当前家庭
  void setCurrentFamily(Family family) async {
    _currentFamily = family;
    
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('family_id', family.id);
    
    notifyListeners();
  }

  // 加入家庭
  Future<bool> joinFamily(String inviteCode) async {
    try {
      final family = await _apiService.joinFamily(inviteCode);
      setCurrentFamily(family);
      
      // 刷新用户信息
      _user = await _apiService.getMe();
      
      await _apiService.trackEvent('family_joined', {
        'invite_code': inviteCode,
      });
      
      notifyListeners();
      return true;
    } catch (e) {
      if (kDebugMode) {
        print('Error joining family: $e');
      }
      return false;
    }
  }

  // 创建家庭
  Future<bool> createFamily(String name) async {
    try {
      final family = await _apiService.createFamily(name);
      setCurrentFamily(family);
      
      // 刷新用户信息
      _user = await _apiService.getMe();
      
      await _apiService.trackEvent('family_created', {
        'family_name': name,
      });
      
      notifyListeners();
      return true;
    } catch (e) {
      if (kDebugMode) {
        print('Error creating family: $e');
      }
      return false;
    }
  }

  // 刷新用户信息
  Future<void> refreshUser() async {
    try {
      _user = await _apiService.getMe();
      notifyListeners();
    } catch (e) {
      if (kDebugMode) {
        print('Error refreshing user: $e');
      }
    }
  }

  // 保存认证数据
  Future<void> _saveAuthData() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('user_id', _user!.id);
    await prefs.setString('token', _token!);
    if (_currentFamily != null) {
      await prefs.setString('family_id', _currentFamily!.id);
    }
  }
}
