from __future__ import annotations

from datetime import datetime, timezone
from enum import Enum as PyEnum

from sqlalchemy import (
    JSON,
    DateTime,
    Float,
    ForeignKey,
    Integer,
    String,
    Text,
    UniqueConstraint,
    Index,
)
from sqlalchemy.orm import Mapped, mapped_column, relationship

from .db import Base


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


class EmotionLevel(str, PyEnum):
    CALM = "calm"           # 平静 0-0.3
    MILD = "mild"           # 轻微 0.3-0.5
    MODERATE = "moderate"   # 中等 0.5-0.7
    HIGH = "high"           # 较高 0.7-0.85
    EXTREME = "extreme"     # 极高 0.85-1.0


class User(Base):
    __tablename__ = "users"

    id: Mapped[str] = mapped_column(String(64), primary_key=True)
    nickname: Mapped[str] = mapped_column(String(64), nullable=False)
    avatar_url: Mapped[str | None] = mapped_column(String(512), nullable=True)
    phone: Mapped[str | None] = mapped_column(String(32), nullable=True, unique=True)
    email: Mapped[str | None] = mapped_column(String(128), nullable=True, unique=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now, onupdate=utc_now)
    last_login_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    is_active: Mapped[bool] = mapped_column(default=True)

    # Relationships
    voice_profiles: Mapped[list["VoiceProfile"]] = relationship("VoiceProfile", back_populates="user", lazy="selectin")
    families: Mapped[list["FamilyMember"]] = relationship("FamilyMember", back_populates="user", lazy="selectin")


class VoiceProfile(Base):
    """声纹档案 - 用于识别说话人"""
    __tablename__ = "voice_profiles"

    id: Mapped[str] = mapped_column(String(64), primary_key=True)
    user_id: Mapped[str] = mapped_column(String(64), ForeignKey("users.id"), index=True)
    family_id: Mapped[str] = mapped_column(String(64), ForeignKey("families.id"), index=True)
    
    # 声纹特征向量 (存储为JSON数组)
    voice_embedding: Mapped[dict] = mapped_column(JSON, nullable=False)
    embedding_version: Mapped[str] = mapped_column(String(32), default="v1")
    
    # 录音样本信息
    sample_count: Mapped[int] = mapped_column(Integer, default=0)
    total_duration_ms: Mapped[int] = mapped_column(Integer, default=0)
    
    # 识别准确率统计
    recognition_accuracy: Mapped[float] = mapped_column(Float, default=0.0)
    recognition_count: Mapped[int] = mapped_column(Integer, default=0)
    
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now, onupdate=utc_now)
    is_active: Mapped[bool] = mapped_column(default=True)

    # Relationships
    user: Mapped["User"] = relationship("User", back_populates="voice_profiles")
    family: Mapped["Family"] = relationship("Family", back_populates="voice_profiles")


class Family(Base):
    __tablename__ = "families"

    id: Mapped[str] = mapped_column(String(64), primary_key=True)
    name: Mapped[str] = mapped_column(String(128), nullable=False)
    owner_user_id: Mapped[str] = mapped_column(String(64), ForeignKey("users.id"))
    invite_code: Mapped[str | None] = mapped_column(String(32), nullable=True, unique=True, index=True)
    invite_code_expires_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    
    # 家庭设置
    settings: Mapped[dict] = mapped_column(JSON, default=dict)  # 包括反馈阈值、通知设置等
    
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now, onupdate=utc_now)

    # Relationships
    members: Mapped[list["FamilyMember"]] = relationship("FamilyMember", back_populates="family", lazy="selectin")
    voice_profiles: Mapped[list["VoiceProfile"]] = relationship("VoiceProfile", back_populates="family", lazy="selectin")
    sessions: Mapped[list["Session"]] = relationship("Session", back_populates="family", lazy="selectin")


class FamilyMember(Base):
    __tablename__ = "family_members"
    __table_args__ = (UniqueConstraint("family_id", "user_id", name="uq_family_user"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    family_id: Mapped[str] = mapped_column(String(64), ForeignKey("families.id"), index=True)
    user_id: Mapped[str] = mapped_column(String(64), ForeignKey("users.id"), index=True)
    role: Mapped[str] = mapped_column(String(32), default="member")  # owner, admin, member
    
    # 成员在家庭中的显示名称
    display_name: Mapped[str | None] = mapped_column(String(64), nullable=True)
    
    # 个人情绪统计
    total_sessions: Mapped[int] = mapped_column(Integer, default=0)
    total_emotion_events: Mapped[int] = mapped_column(Integer, default=0)
    avg_anger_score: Mapped[float] = mapped_column(Float, default=0.0)
    high_emotion_count: Mapped[int] = mapped_column(Integer, default=0)
    improvement_score: Mapped[float] = mapped_column(Float, default=0.0)  # 改善指数
    
    joined_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
    
    # Relationships
    family: Mapped["Family"] = relationship("Family", back_populates="members")
    user: Mapped["User"] = relationship("User", back_populates="families")


class Session(Base):
    """语音会话 - 一次连续的情绪监测会话"""
    __tablename__ = "sessions"

    id: Mapped[str] = mapped_column(String(64), primary_key=True)
    family_id: Mapped[str] = mapped_column(String(64), ForeignKey("families.id"), index=True)
    device_id: Mapped[str] = mapped_column(String(128), nullable=False, index=True)
    device_type: Mapped[str] = mapped_column(String(32), default="mobile")  # mobile, web, iot
    
    # 会话状态
    status: Mapped[str] = mapped_column(String(32), default="active")  # active, paused, ended
    
    # 时间信息
    started_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
    ended_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    duration_seconds: Mapped[int] = mapped_column(Integer, default=0)
    
    # 会话统计
    total_emotion_events: Mapped[int] = mapped_column(Integer, default=0)
    emotion_events_by_level: Mapped[dict] = mapped_column(JSON, default=dict)  # {"calm": 10, "mild": 5, ...}
    avg_anger_score: Mapped[float] = mapped_column(Float, default=0.0)
    max_anger_score: Mapped[float] = mapped_column(Float, default=0.0)
    
    # 反馈效果
    feedback_shown_count: Mapped[int] = mapped_column(Integer, default=0)
    feedback_accepted_count: Mapped[int] = mapped_column(Integer, default=0)
    
    # Relationships
    family: Mapped["Family"] = relationship("Family", back_populates="sessions")
    emotion_events: Mapped[list["EmotionEvent"]] = relationship("EmotionEvent", back_populates="session", lazy="selectin")
    feedback_events: Mapped[list["FeedbackEvent"]] = relationship("FeedbackEvent", back_populates="session", lazy="selectin")


class EmotionEvent(Base):
    """情绪事件 - 单次语音分析结果"""
    __tablename__ = "emotion_events"
    __table_args__ = (
        Index("idx_emotion_session_ts", "session_id", "ts"),
        Index("idx_emotion_speaker", "speaker_id", "ts"),
        Index("idx_emotion_family_ts", "family_id", "ts"),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    session_id: Mapped[str] = mapped_column(String(64), ForeignKey("sessions.id"), index=True)
    family_id: Mapped[str] = mapped_column(String(64), ForeignKey("families.id"), index=True)
    
    # 说话人信息
    speaker_id: Mapped[str] = mapped_column(String(64), default="unknown", index=True)
    speaker_confidence: Mapped[float] = mapped_column(Float, default=0.0)  # 声纹识别置信度
    
    # 时间戳
    ts: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
    
    # 音频信息
    audio_duration_ms: Mapped[int] = mapped_column(Integer, default=0)
    audio_sample_rate: Mapped[int] = mapped_column(Integer, default=16000)
    
    # 文本内容
    transcript: Mapped[str] = mapped_column(Text, default="")
    transcript_confidence: Mapped[float] = mapped_column(Float, default=0.0)
    language: Mapped[str] = mapped_column(String(16), default="zh")
    
    # 情绪分析结果
    anger_score: Mapped[float] = mapped_column(Float, default=0.0)  # 0-1 愤怒程度
    emotion_level: Mapped[str] = mapped_column(String(16), default="calm")  # calm, mild, moderate, high, extreme
    
    # 多维度情绪分析
    emotion_dimensions: Mapped[dict] = mapped_column(JSON, default=dict)
    # {
    #     "valence": 0.3,      # 情感效价 (负面-正面)
    #     "arousal": 0.7,      # 唤醒度 (平静-激动)
    #     "dominance": 0.5,    # 支配度 (被动-主动)
    #     "stress": 0.6,       # 压力指数
    #     "impatience": 0.4,   # 不耐烦指数
    # }
    
    # 声学特征
    acoustic_features: Mapped[dict] = mapped_column(JSON, default=dict)
    # {
    #     "pitch_mean": 150,
    #     "pitch_std": 20,
    #     "energy_mean": 0.5,
    #     "speaking_rate": 4.5,  # 语速 (字/秒)
    #     "pause_ratio": 0.2,    # 停顿比例
    # }
    
    # 原始特征向量 (用于后续模型优化)
    feature_vector: Mapped[dict | None] = mapped_column(JSON, nullable=True)
    
    # 音频存储路径 (可选)
    audio_storage_path: Mapped[str | None] = mapped_column(String(512), nullable=True)
    
    # 关联的反馈
    feedback_id: Mapped[str | None] = mapped_column(String(64), nullable=True, index=True)
    
    # Relationships
    session: Mapped["Session"] = relationship("Session", back_populates="emotion_events")
    feedback: Mapped["FeedbackEvent"] = relationship("FeedbackEvent", back_populates="emotion_event", foreign_keys="FeedbackEvent.emotion_event_id")


class FeedbackEvent(Base):
    """反馈事件 - 系统给出的干预建议"""
    __tablename__ = "feedback_events"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    token: Mapped[str] = mapped_column(String(64), unique=True, index=True)
    session_id: Mapped[str] = mapped_column(String(64), ForeignKey("sessions.id"), index=True)
    emotion_event_id: Mapped[int] = mapped_column(Integer, ForeignKey("emotion_events.id"), nullable=True)
    
    # 目标说话人
    speaker_id: Mapped[str] = mapped_column(String(64), default="unknown")
    
    # 反馈内容
    feedback_level: Mapped[str] = mapped_column(String(16), default="calm")  # calm, mild, moderate, high, extreme
    message: Mapped[str] = mapped_column(String(512), default="")
    message_type: Mapped[str] = mapped_column(String(32), default="text")  # text, audio, haptic
    
    # 反馈策略
    strategy: Mapped[str] = mapped_column(String(64), default="default")  # breathing, counting, pausing, suggestion
    
    # 时间记录
    shown_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
    acted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    
    # 用户响应
    action: Mapped[str] = mapped_column(String(32), default="shown")  # shown, accepted, ignored, dismissed
    user_response_time_ms: Mapped[int] = mapped_column(Integer, default=0)  # 用户响应时间
    
    # 反馈效果评估
    effectiveness_score: Mapped[float | None] = mapped_column(Float, nullable=True)  # 0-1 效果评分
    subsequent_anger_change: Mapped[float | None] = mapped_column(Float, nullable=True)  # 后续愤怒分数变化
    
    # Relationships
    session: Mapped["Session"] = relationship("Session", back_populates="feedback_events")
    emotion_event: Mapped["EmotionEvent"] = relationship("EmotionEvent", back_populates="feedback", foreign_keys=[emotion_event_id])


class DailyStats(Base):
    """每日统计 - 按天聚合的情绪数据"""
    __tablename__ = "daily_stats"
    __table_args__ = (UniqueConstraint("family_id", "user_id", "date", name="uq_daily_stats"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    family_id: Mapped[str] = mapped_column(String(64), ForeignKey("families.id"), index=True)
    user_id: Mapped[str | None] = mapped_column(String(64), ForeignKey("users.id"), nullable=True, index=True)
    date: Mapped[str] = mapped_column(String(10), index=True)  # YYYY-MM-DD
    
    # 会话统计
    session_count: Mapped[int] = mapped_column(Integer, default=0)
    total_duration_seconds: Mapped[int] = mapped_column(Integer, default=0)
    
    # 情绪事件统计
    emotion_event_count: Mapped[int] = mapped_column(Integer, default=0)
    emotion_events_by_level: Mapped[dict] = mapped_column(JSON, default=dict)
    
    # 愤怒分数统计
    avg_anger_score: Mapped[float] = mapped_column(Float, default=0.0)
    max_anger_score: Mapped[float] = mapped_column(Float, default=0.0)
    min_anger_score: Mapped[float] = mapped_column(Float, default=0.0)
    
    # 反馈统计
    feedback_shown_count: Mapped[int] = mapped_column(Integer, default=0)
    feedback_accepted_count: Mapped[int] = mapped_column(Integer, default=0)
    feedback_accepted_rate: Mapped[float] = mapped_column(Float, default=0.0)
    
    # 改善指标
    improvement_score: Mapped[float] = mapped_column(Float, default=0.0)
    trend_direction: Mapped[str] = mapped_column(String(16), default="stable")  # improving, worsening, stable
    
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now, onupdate=utc_now)


class WeeklyStats(Base):
    """每周统计"""
    __tablename__ = "weekly_stats"
    __table_args__ = (UniqueConstraint("family_id", "user_id", "year_week", name="uq_weekly_stats"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    family_id: Mapped[str] = mapped_column(String(64), ForeignKey("families.id"), index=True)
    user_id: Mapped[str | None] = mapped_column(String(64), ForeignKey("users.id"), nullable=True, index=True)
    year_week: Mapped[str] = mapped_column(String(7), index=True)  # YYYY-WW
    
    session_count: Mapped[int] = mapped_column(Integer, default=0)
    emotion_event_count: Mapped[int] = mapped_column(Integer, default=0)
    avg_anger_score: Mapped[float] = mapped_column(Float, default=0.0)
    
    emotion_events_by_level: Mapped[dict] = mapped_column(JSON, default=dict)
    daily_breakdown: Mapped[dict] = mapped_column(JSON, default=dict)  # 每天的统计数据
    
    improvement_score: Mapped[float] = mapped_column(Float, default=0.0)
    trend_direction: Mapped[str] = mapped_column(String(16), default="stable")
    
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now, onupdate=utc_now)


class UserGoal(Base):
    """用户目标 - 改善计划"""
    __tablename__ = "user_goals"

    id: Mapped[str] = mapped_column(String(64), primary_key=True)
    user_id: Mapped[str] = mapped_column(String(64), ForeignKey("users.id"), index=True)
    family_id: Mapped[str] = mapped_column(String(64), ForeignKey("families.id"), index=True)
    
    # 目标内容
    goal_type: Mapped[str] = mapped_column(String(64))  # reduce_anger, improve_patience, better_communication
    title: Mapped[str] = mapped_column(String(128))
    description: Mapped[str | None] = mapped_column(Text, nullable=True)
    
    # 目标指标
    target_value: Mapped[float] = mapped_column(Float)  # 目标值
    current_value: Mapped[float] = mapped_column(Float, default=0.0)
    unit: Mapped[str] = mapped_column(String(32))  # percentage, count, score
    
    # 时间范围
    start_date: Mapped[str] = mapped_column(String(10))  # YYYY-MM-DD
    end_date: Mapped[str] = mapped_column(String(10))
    
    # 状态
    status: Mapped[str] = mapped_column(String(32), default="active")  # active, completed, abandoned
    progress_percentage: Mapped[float] = mapped_column(Float, default=0.0)
    
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now, onupdate=utc_now)
    completed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)


class AnalyticsEvent(Base):
    """埋点事件 - 用于产品分析"""
    __tablename__ = "analytics_events"
    __table_args__ = (
        Index("idx_analytics_user_ts", "user_id", "ts"),
        Index("idx_analytics_event_ts", "event_name", "ts"),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    event_name: Mapped[str] = mapped_column(String(128), index=True)
    user_id: Mapped[str | None] = mapped_column(String(64), nullable=True, index=True)
    family_id: Mapped[str | None] = mapped_column(String(64), nullable=True, index=True)
    session_id: Mapped[str | None] = mapped_column(String(64), nullable=True, index=True)
    
    # 事件属性
    properties: Mapped[dict] = mapped_column(JSON, default=dict)
    
    # 设备信息
    device_type: Mapped[str | None] = mapped_column(String(32), nullable=True)
    app_version: Mapped[str | None] = mapped_column(String(32), nullable=True)
    os_version: Mapped[str | None] = mapped_column(String(64), nullable=True)
    
    # 时间
    ts: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
    client_ts: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)


class UserNotification(Base):
    """用户通知"""
    __tablename__ = "user_notifications"

    id: Mapped[str] = mapped_column(String(64), primary_key=True)
    user_id: Mapped[str] = mapped_column(String(64), ForeignKey("users.id"), index=True)
    family_id: Mapped[str | None] = mapped_column(String(64), ForeignKey("families.id"), nullable=True)
    
    # 通知内容
    title: Mapped[str] = mapped_column(String(128))
    content: Mapped[str] = mapped_column(Text)
    notification_type: Mapped[str] = mapped_column(String(64))  # emotion_alert, daily_summary, goal_achieved, system
    
    # 关联数据
    related_data: Mapped[dict] = mapped_column(JSON, default=dict)
    
    # 状态
    is_read: Mapped[bool] = mapped_column(default=False)
    is_pushed: Mapped[bool] = mapped_column(default=False)
    
    # 时间
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
    read_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    pushed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
