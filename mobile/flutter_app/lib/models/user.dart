class User {
  final String id;
  final String nickname;
  final String? avatarUrl;
  final String? phone;
  final String? email;
  final DateTime? createdAt;
  final DateTime? lastLoginAt;
  final List<FamilyMemberInfo> families;

  User({
    required this.id,
    required this.nickname,
    this.avatarUrl,
    this.phone,
    this.email,
    this.createdAt,
    this.lastLoginAt,
    this.families = const [],
  });

  factory User.fromJson(Map<String, dynamic> json) {
    return User(
      id: json['id'] as String,
      nickname: json['nickname'] as String,
      avatarUrl: json['avatar_url'] as String?,
      phone: json['phone'] as String?,
      email: json['email'] as String?,
      createdAt: json['created_at'] != null
          ? DateTime.parse(json['created_at'] as String)
          : null,
      lastLoginAt: json['last_login_at'] != null
          ? DateTime.parse(json['last_login_at'] as String)
          : null,
      families: (json['families'] as List?)
              ?.map((f) => FamilyMemberInfo.fromJson(f as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'nickname': nickname,
      'avatar_url': avatarUrl,
      'phone': phone,
      'email': email,
      'created_at': createdAt?.toIso8601String(),
      'last_login_at': lastLoginAt?.toIso8601String(),
      'families': families.map((f) => f.toJson()).toList(),
    };
  }
}

class FamilyMemberInfo {
  final String familyId;
  final String familyName;
  final String role;
  final DateTime joinedAt;

  FamilyMemberInfo({
    required this.familyId,
    required this.familyName,
    required this.role,
    required this.joinedAt,
  });

  factory FamilyMemberInfo.fromJson(Map<String, dynamic> json) {
    return FamilyMemberInfo(
      familyId: json['family_id'] as String,
      familyName: json['family_name'] as String,
      role: json['role'] as String,
      joinedAt: DateTime.parse(json['joined_at'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'family_id': familyId,
      'family_name': familyName,
      'role': role,
      'joined_at': joinedAt.toIso8601String(),
    };
  }
}
