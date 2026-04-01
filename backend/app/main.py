from __future__ import annotations

import asyncio
import os
import uuid
from datetime import datetime, timedelta, timezone
from typing import Optional

import jwt
import numpy as np

from fastapi import Depends, FastAPI, Header, HTTPException, Query, WebSocket, WebSocketDisconnect, UploadFile, File
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field
from sqlalchemy import case, func, select, desc
from sqlalchemy.orm import Session

from .db import Base, SessionLocal, engine
from .models import (
    EmotionEvent, Family, FamilyMember, FeedbackEvent, Session as SessionModel, User,
    VoiceProfile, DailyStats, WeeklyStats, UserGoal, AnalyticsEvent, UserNotification,
    EmotionLevel
)
from .emotion_engine import EmotionAnalyzer, VoiceRecognizer, FeedbackGenerator, AudioProcessor

APP_VERSION = "2.0.0"
JWT_SECRET = os.getenv("JWT_SECRET", "dev-secret-change-me")
JWT_EXPIRE_MINUTES = int(os.getenv("JWT_EXPIRE_MINUTES", "120"))

app = FastAPI(title="SofterPlease API", version=APP_VERSION)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# 初始化情绪引擎
emotion_analyzer = EmotionAnalyzer()
voice_recognizer = VoiceRecognizer()
feedback_generator = FeedbackGenerator()
audio_processor = AudioProcessor()


# ==================== Pydantic Models ====================

class UserCreateRequest(BaseModel):
    nickname: str = Field(min_length=1)
    phone: Optional[str] = None
    email: Optional[str] = None


class UserCreateResponse(BaseModel):
    user_id: str
    nickname: str


class AuthLoginRequest(BaseModel):
    user_id: str = Field(min_length=1)


class AuthLoginResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"
    expires_in: int
    user: dict


class FamilyCreateRequest(BaseModel):
    name: str = Field(min_length=1)


class FamilyCreateResponse(BaseModel):
    family_id: str
    invite_code: str


class FamilyMemberAddRequest(BaseModel):
    user_id: str = Field(min_length=1)
    role: str = Field(default="member")
    display_name: Optional[str] = None


class JoinFamilyRequest(BaseModel):
    invite_code: str = Field(min_length=1)


class SessionStartRequest(BaseModel):
    family_id: str = Field(min_length=1)
    device_id: str = Field(min_length=1)
    device_type: str = Field(default="mobile")


class SessionStartResponse(BaseModel):
    session_id: str
    started_at: datetime
    family_id: str


class SessionEndRequest(BaseModel):
    session_id: str = Field(min_length=1)


class VoiceProfileCreateRequest(BaseModel):
    family_id: str = Field(min_length=1)


class VoiceProfileCreateResponse(BaseModel):
    profile_id: str
    status: str


class FeedbackActionRequest(BaseModel):
    feedback_token: str = Field(min_length=1)
    action: str = Field(pattern="^(accepted|ignored|dismissed)$")


class GoalCreateRequest(BaseModel):
    goal_type: str = Field(min_length=1)
    title: str = Field(min_length=1)
    description: Optional[str] = None
    target_value: float
    unit: str
    start_date: str
    end_date: str


class AnalyticsEventRequest(BaseModel):
    event_name: str = Field(min_length=1)
    properties: dict = Field(default_factory=dict)
    client_ts: Optional[datetime] = None


class EmotionAnalysisResponse(BaseModel):
    anger_score: float
    emotion_level: str
    emotion_dimensions: dict
    acoustic_features: dict
    confidence: float
    speaker_id: str
    speaker_confidence: float


class FeedbackResponse(BaseModel):
    feedback_token: str
    level: str
    message: str
    strategy: str
    duration_seconds: int


class DailyReportResponse(BaseModel):
    date: str
    session_count: int
    total_duration_seconds: int
    emotion_event_count: int
    emotion_events_by_level: dict
    avg_anger_score: float
    max_anger_score: float
    feedback_shown_count: int
    feedback_accepted_count: int
    feedback_accepted_rate: float
    improvement_score: float
    trend_direction: str


class TimeSeriesPoint(BaseModel):
    timestamp: str
    anger_score: float
    emotion_level: str
    speaker_id: str


class TimeSeriesResponse(BaseModel):
    session_id: str
    points: list[TimeSeriesPoint]


class FamilyStatsResponse(BaseModel):
    family_id: str
    member_count: int
    total_sessions: int
    avg_anger_score: float
    improvement_trend: str


# ==================== Database Helpers ====================

Base.metadata.create_all(bind=engine)


def get_db() -> Session:
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


def now_utc() -> datetime:
    return datetime.now(timezone.utc)


def issue_jwt(user_id: str) -> str:
    exp = now_utc() + timedelta(minutes=JWT_EXPIRE_MINUTES)
    payload = {"sub": user_id, "exp": exp}
    return jwt.encode(payload, JWT_SECRET, algorithm="HS256")


def get_current_user_id(
    authorization: str | None = Header(default=None),
    x_user_id: str | None = Header(default=None),
    db: Session = Depends(get_db),
) -> str:
    resolved_user_id: str | None = None

    if authorization and authorization.lower().startswith("bearer "):
        token = authorization.split(" ", 1)[1]
        try:
            payload = jwt.decode(token, JWT_SECRET, algorithms=["HS256"])
            resolved_user_id = str(payload.get("sub"))
        except jwt.PyJWTError as exc:
            raise HTTPException(status_code=401, detail="invalid token") from exc
    elif x_user_id:
        resolved_user_id = x_user_id

    if not resolved_user_id:
        raise HTTPException(status_code=401, detail="authorization required")

    user = db.get(User, resolved_user_id)
    if not user:
        raise HTTPException(status_code=401, detail="invalid user")
    
    # 更新最后登录时间
    user.last_login_at = now_utc()
    db.commit()
    
    return resolved_user_id


def ensure_family_member(db: Session, family_id: str, user_id: str) -> None:
    member = db.execute(
        select(FamilyMember).where(FamilyMember.family_id == family_id, FamilyMember.user_id == user_id)
    ).scalar_one_or_none()
    if not member:
        raise HTTPException(status_code=403, detail="not a family member")


def get_family_by_session(db: Session, session_id: str) -> str:
    session = db.get(SessionModel, session_id)
    if not session:
        raise HTTPException(status_code=404, detail="session not found")
    return session.family_id


def generate_invite_code() -> str:
    """生成邀请码"""
    import random
    import string
    return ''.join(random.choices(string.ascii_uppercase + string.digits, k=8))


# ==================== Health Check ====================

@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok", "version": APP_VERSION}


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/readyz")
def readyz(db: Session = Depends(get_db)) -> dict[str, str]:
    db.execute(select(1))
    return {"status": "ready"}


@app.get("/v1/system/info")
def system_info() -> dict[str, str]:
    return {
        "version": APP_VERSION,
        "server_time": now_utc().isoformat(),
        "features": ["emotion_analysis", "voice_recognition", "realtime_feedback"],
    }


# ==================== User APIs ====================

@app.post("/v1/users", response_model=UserCreateResponse)
def create_user(payload: UserCreateRequest, db: Session = Depends(get_db)) -> UserCreateResponse:
    user_id = str(uuid.uuid4())
    user = User(
        id=user_id,
        nickname=payload.nickname,
        phone=payload.phone,
        email=payload.email,
        created_at=now_utc(),
    )
    db.add(user)
    db.commit()
    return UserCreateResponse(user_id=user_id, nickname=payload.nickname)


@app.get("/v1/users/me")
def get_current_user(
    db: Session = Depends(get_db),
    user_id: str = Depends(get_current_user_id)
) -> dict:
    user = db.get(User, user_id)
    if not user:
        raise HTTPException(status_code=404, detail="user not found")
    
    # 获取用户家庭信息
    families = db.execute(
        select(Family, FamilyMember)
        .join(FamilyMember, Family.id == FamilyMember.family_id)
        .where(FamilyMember.user_id == user_id)
    ).all()
    
    return {
        "id": user.id,
        "nickname": user.nickname,
        "avatar_url": user.avatar_url,
        "phone": user.phone,
        "email": user.email,
        "created_at": user.created_at.isoformat(),
        "last_login_at": user.last_login_at.isoformat() if user.last_login_at else None,
        "families": [
            {
                "family_id": f.Family.id,
                "family_name": f.Family.name,
                "role": f.FamilyMember.role,
                "joined_at": f.FamilyMember.joined_at.isoformat(),
            }
            for f in families
        ],
    }


@app.post("/v1/auth/login", response_model=AuthLoginResponse)
def login(payload: AuthLoginRequest, db: Session = Depends(get_db)) -> AuthLoginResponse:
    user = db.get(User, payload.user_id)
    if not user:
        raise HTTPException(status_code=404, detail="user not found")
    
    token = issue_jwt(payload.user_id)
    
    return AuthLoginResponse(
        access_token=token,
        expires_in=JWT_EXPIRE_MINUTES * 60,
        user={
            "id": user.id,
            "nickname": user.nickname,
            "avatar_url": user.avatar_url,
        }
    )


# ==================== Family APIs ====================

@app.post("/v1/families", response_model=FamilyCreateResponse)
def create_family(
    payload: FamilyCreateRequest,
    db: Session = Depends(get_db),
    user_id: str = Depends(get_current_user_id),
) -> FamilyCreateResponse:
    family_id = str(uuid.uuid4())
    invite_code = generate_invite_code()
    
    family = Family(
        id=family_id,
        name=payload.name,
        owner_user_id=user_id,
        invite_code=invite_code,
        invite_code_expires_at=now_utc() + timedelta(days=7),
        created_at=now_utc(),
    )
    db.add(family)
    db.add(FamilyMember(family_id=family_id, user_id=user_id, role="owner"))
    db.commit()
    
    return FamilyCreateResponse(family_id=family_id, invite_code=invite_code)


@app.post("/v1/families/join")
def join_family(
    payload: JoinFamilyRequest,
    db: Session = Depends(get_db),
    user_id: str = Depends(get_current_user_id),
) -> dict:
    family = db.execute(
        select(Family).where(Family.invite_code == payload.invite_code)
    ).scalar_one_or_none()
    
    if not family:
        raise HTTPException(status_code=404, detail="invalid invite code")
    
    if family.invite_code_expires_at and family.invite_code_expires_at < now_utc():
        raise HTTPException(status_code=400, detail="invite code expired")
    
    # 检查是否已经是成员
    existing = db.execute(
        select(FamilyMember).where(
            FamilyMember.family_id == family.id,
            FamilyMember.user_id == user_id
        )
    ).scalar_one_or_none()
    
    if existing:
        raise HTTPException(status_code=400, detail="already a member")
    
    db.add(FamilyMember(family_id=family.id, user_id=user_id, role="member"))
    db.commit()
    
    return {"status": "joined", "family_id": family.id, "family_name": family.name}


@app.get("/v1/families/{family_id}")
def get_family(
    family_id: str,
    db: Session = Depends(get_db),
    user_id: str = Depends(get_current_user_id),
) -> dict:
    ensure_family_member(db, family_id, user_id)
    
    family = db.get(Family, family_id)
    if not family:
        raise HTTPException(status_code=404, detail="family not found")
    
    # 获取成员信息
    members = db.execute(
        select(User, FamilyMember)
        .join(FamilyMember, User.id == FamilyMember.user_id)
        .where(FamilyMember.family_id == family_id)
    ).all()
    
    return {
        "id": family.id,
        "name": family.name,
        "owner_id": family.owner_user_id,
        "created_at": family.created_at.isoformat(),
        "members": [
            {
                "user_id": m.User.id,
                "nickname": m.User.nickname,
                "avatar_url": m.User.avatar_url,
                "role": m.FamilyMember.role,
                "display_name": m.FamilyMember.display_name,
                "joined_at": m.FamilyMember.joined_at.isoformat(),
            }
            for m in members
        ],
    }


@app.post("/v1/families/{family_id}/members")
def add_member(
    family_id: str,
    payload: FamilyMemberAddRequest,
    db: Session = Depends(get_db),
    user_id: str = Depends(get_current_user_id),
) -> dict[str, str]:
    family = db.get(Family, family_id)
    if not family:
        raise HTTPException(status_code=404, detail="family not found")
    if family.owner_user_id != user_id:
        raise HTTPException(status_code=403, detail="only owner can add members")

    user = db.get(User, payload.user_id)
    if not user:
        raise HTTPException(status_code=404, detail="user not found")

    db.add(FamilyMember(
        family_id=family_id,
        user_id=payload.user_id,
        role=payload.role,
        display_name=payload.display_name,
    ))
    db.commit()
    return {"status": "added"}


@app.get("/v1/families/{family_id}/stats", response_model=FamilyStatsResponse)
def get_family_stats(
    family_id: str,
    db: Session = Depends(get_db),
    user_id: str = Depends(get_current_user_id),
) -> FamilyStatsResponse:
    ensure_family_member(db, family_id, user_id)
    
    # 成员数
    member_count = db.execute(
        select(func.count(FamilyMember.id)).where(FamilyMember.family_id == family_id)
    ).scalar_one()
    
    # 会话统计
    session_stats = db.execute(
        select(
            func.count(SessionModel.id),
            func.avg(SessionModel.avg_anger_score),
        ).where(SessionModel.family_id == family_id)
    ).one()
    
    return FamilyStatsResponse(
        family_id=family_id,
        member_count=member_count,
        total_sessions=session_stats[0] or 0,
        avg_anger_score=round(session_stats[1] or 0.0, 4),
        improvement_trend="stable",  # TODO: 计算趋势
    )


# ==================== Session APIs ====================

@app.post("/v1/sessions/start", response_model=SessionStartResponse)
def start_session(
    payload: SessionStartRequest,
    db: Session = Depends(get_db),
    user_id: str = Depends(get_current_user_id),
) -> SessionStartResponse:
    family = db.get(Family, payload.family_id)
    if not family:
        raise HTTPException(status_code=404, detail="family not found")
    ensure_family_member(db, payload.family_id, user_id)

    session_id = str(uuid.uuid4())
    session = SessionModel(
        id=session_id,
        family_id=payload.family_id,
        device_id=payload.device_id,
        device_type=payload.device_type,
        started_at=now_utc(),
    )
    db.add(session)
    db.commit()
    
    return SessionStartResponse(
        session_id=session_id,
        started_at=session.started_at,
        family_id=payload.family_id,
    )


@app.post("/v1/sessions/{session_id}/pause")
def pause_session(
    session_id: str,
    db: Session = Depends(get_db),
    user_id: str = Depends(get_current_user_id),
) -> dict:
    family_id = get_family_by_session(db, session_id)
    ensure_family_member(db, family_id, user_id)
    
    session = db.get(SessionModel, session_id)
    session.status = "paused"
    db.commit()
    
    return {"status": "paused"}


@app.post("/v1/sessions/{session_id}/resume")
def resume_session(
    session_id: str,
    db: Session = Depends(get_db),
    user_id: str = Depends(get_current_user_id),
) -> dict:
    family_id = get_family_by_session(db, session_id)
    ensure_family_member(db, family_id, user_id)
    
    session = db.get(SessionModel, session_id)
    session.status = "active"
    db.commit()
    
    return {"status": "resumed"}


@app.post("/v1/sessions/end")
def end_session(
    payload: SessionEndRequest,
    db: Session = Depends(get_db),
    user_id: str = Depends(get_current_user_id),
) -> dict:
    family_id = get_family_by_session(db, payload.session_id)
    ensure_family_member(db, family_id, user_id)
    
    session = db.get(SessionModel, payload.session_id)
    session.ended_at = now_utc()
    session.status = "ended"
    
    # 计算会话时长
    duration = (session.ended_at - session.started_at).total_seconds()
    session.duration_seconds = int(duration)
    
    db.commit()
    return {"status": "ended", "duration_seconds": session.duration_seconds}


@app.get("/v1/sessions/{session_id}")
def get_session(
    session_id: str,
    db: Session = Depends(get_db),
    user_id: str = Depends(get_current_user_id),
) -> dict:
    family_id = get_family_by_session(db, session_id)
    ensure_family_member(db, family_id, user_id)
    
    session = db.get(SessionModel, session_id)
    
    return {
        "id": session.id,
        "family_id": session.family_id,
        "device_id": session.device_id,
        "device_type": session.device_type,
        "status": session.status,
        "started_at": session.started_at.isoformat(),
        "ended_at": session.ended_at.isoformat() if session.ended_at else None,
        "duration_seconds": session.duration_seconds,
        "total_emotion_events": session.total_emotion_events,
        "avg_anger_score": session.avg_anger_score,
        "max_anger_score": session.max_anger_score,
    }


# ==================== Voice Profile APIs ====================

@app.post("/v1/voice-profiles", response_model=VoiceProfileCreateResponse)
def create_voice_profile(
    payload: VoiceProfileCreateRequest,
    db: Session = Depends(get_db),
    user_id: str = Depends(get_current_user_id),
) -> VoiceProfileCreateResponse:
    ensure_family_member(db, payload.family_id, user_id)
    
    profile_id = str(uuid.uuid4())
    profile = VoiceProfile(
        id=profile_id,
        user_id=user_id,
        family_id=payload.family_id,
        voice_embedding={},
        created_at=now_utc(),
    )
    db.add(profile)
    db.commit()
    
    return VoiceProfileCreateResponse(profile_id=profile_id, status="created")


@app.post("/v1/voice-profiles/{profile_id}/samples")
async def add_voice_sample(
    profile_id: str,
    audio: UploadFile = File(...),
    db: Session = Depends(get_db),
    user_id: str = Depends(get_current_user_id),
) -> dict:
    profile = db.get(VoiceProfile, profile_id)
    if not profile:
        raise HTTPException(status_code=404, detail="profile not found")
    if profile.user_id != user_id:
        raise HTTPException(status_code=403, detail="not your profile")
    
    # 读取音频数据
    audio_data = await audio.read()
    
    # 加载和处理音频
    audio_array, sr = audio_processor.load_audio(audio_data, format=audio.filename.split('.')[-1])
    processed = audio_processor.preprocess(audio_array, sr)
    
    # 提取声纹嵌入
    embedding = voice_recognizer.extract_embedding(processed.audio, processed.sample_rate)
    
    # 更新档案
    profile.voice_embedding = embedding.tolist()
    profile.sample_count += 1
    profile.total_duration_ms += int(processed.get_total_speech_duration() * 1000)
    profile.updated_at = now_utc()
    db.commit()
    
    return {
        "status": "sample_added",
        "sample_count": profile.sample_count,
        "total_duration_ms": profile.total_duration_ms,
    }


# ==================== Emotion Analysis APIs ====================

@app.post("/v1/sessions/{session_id}/analyze", response_model=EmotionAnalysisResponse)
async def analyze_emotion(
    session_id: str,
    audio: UploadFile = File(...),
    transcript: str = "",
    speaker_id: str = "unknown",
    db: Session = Depends(get_db),
    user_id: str = Depends(get_current_user_id),
) -> EmotionAnalysisResponse:
    family_id = get_family_by_session(db, session_id)
    ensure_family_member(db, family_id, user_id)
    
    session = db.get(SessionModel, session_id)
    if session.status != "active":
        raise HTTPException(status_code=400, detail="session not active")
    
    # 读取音频数据
    audio_data = await audio.read()
    
    # 加载和处理音频
    audio_array, sr = audio_processor.load_audio(audio_data, format=audio.filename.split('.')[-1])
    processed = audio_processor.preprocess(audio_array, sr)
    
    # 声纹识别
    voice_result = voice_recognizer.recognize(processed.audio, processed.sample_rate)
    detected_speaker = voice_result.speaker_id if voice_result.is_known else speaker_id
    
    # 情绪分析
    emotion_result = emotion_analyzer.analyze(processed.audio, transcript, processed.sample_rate)
    
    # 保存到数据库
    emotion_event = EmotionEvent(
        session_id=session_id,
        family_id=family_id,
        speaker_id=detected_speaker,
        speaker_confidence=voice_result.confidence,
        ts=now_utc(),
        audio_duration_ms=int(processed.get_total_speech_duration() * 1000),
        transcript=transcript,
        anger_score=emotion_result.anger_score,
        emotion_level=emotion_result.emotion_level,
        emotion_dimensions=emotion_result.to_dict()["emotion_dimensions"],
        acoustic_features=emotion_result.acoustic_features,
    )
    db.add(emotion_event)
    
    # 更新会话统计
    session.total_emotion_events += 1
    if emotion_result.anger_score > session.max_anger_score:
        session.max_anger_score = emotion_result.anger_score
    
    # 重新计算平均愤怒分数
    avg_result = db.execute(
        select(func.avg(EmotionEvent.anger_score)).where(EmotionEvent.session_id == session_id)
    ).scalar_one()
    session.avg_anger_score = avg_result or 0.0
    
    db.commit()
    
    return EmotionAnalysisResponse(
        anger_score=emotion_result.anger_score,
        emotion_level=emotion_result.emotion_level,
        emotion_dimensions=emotion_result.to_dict()["emotion_dimensions"],
        acoustic_features=emotion_result.acoustic_features,
        confidence=emotion_result.confidence,
        speaker_id=detected_speaker,
        speaker_confidence=voice_result.confidence,
    )


# ==================== Feedback APIs ====================

@app.post("/v1/feedback/actions")
def post_feedback_action(
    payload: FeedbackActionRequest,
    db: Session = Depends(get_db),
    user_id: str = Depends(get_current_user_id),
) -> dict:
    feedback = db.execute(
        select(FeedbackEvent).where(FeedbackEvent.token == payload.feedback_token)
    ).scalar_one_or_none()
    
    if not feedback:
        raise HTTPException(status_code=404, detail="feedback token not found")

    family_id = get_family_by_session(db, feedback.session_id)
    ensure_family_member(db, family_id, user_id)

    feedback.action = payload.action
    feedback.acted_at = now_utc()
    
    # 计算响应时间
    if feedback.shown_at:
        response_time = (feedback.acted_at - feedback.shown_at).total_seconds() * 1000
        feedback.user_response_time_ms = int(response_time)
    
    db.commit()
    
    # 更新会话统计
    session = db.get(SessionModel, feedback.session_id)
    if payload.action == "accepted":
        session.feedback_accepted_count += 1
        db.commit()
    
    return {"status": "updated", "action": payload.action}


# ==================== Report APIs ====================

@app.get("/v1/reports/daily/{family_id}")
def get_daily_report(
    family_id: str,
    date: str = Query(..., description="Date in YYYY-MM-DD format"),
    db: Session = Depends(get_db),
    user_id: str = Depends(get_current_user_id),
) -> DailyReportResponse:
    ensure_family_member(db, family_id, user_id)
    
    # 查询或计算每日统计
    daily_stats = db.execute(
        select(DailyStats).where(
            DailyStats.family_id == family_id,
            DailyStats.user_id.is_(None),
            DailyStats.date == date,
        )
    ).scalar_one_or_none()
    
    if daily_stats:
        return DailyReportResponse(
            date=date,
            session_count=daily_stats.session_count,
            total_duration_seconds=daily_stats.total_duration_seconds,
            emotion_event_count=daily_stats.emotion_event_count,
            emotion_events_by_level=daily_stats.emotion_events_by_level,
            avg_anger_score=daily_stats.avg_anger_score,
            max_anger_score=daily_stats.max_anger_score,
            feedback_shown_count=daily_stats.feedback_shown_count,
            feedback_accepted_count=daily_stats.feedback_accepted_count,
            feedback_accepted_rate=daily_stats.feedback_accepted_rate,
            improvement_score=daily_stats.improvement_score,
            trend_direction=daily_stats.trend_direction,
        )
    
    # 实时计算
    start_dt = datetime.fromisoformat(f"{date}T00:00:00")
    end_dt = datetime.fromisoformat(f"{date}T23:59:59")
    
    stats = db.execute(
        select(
            func.count(EmotionEvent.id),
            func.avg(EmotionEvent.anger_score),
            func.max(EmotionEvent.anger_score),
            func.sum(case((EmotionEvent.anger_score >= 0.7, 1), else_=0)),
        )
        .select_from(EmotionEvent)
        .join(SessionModel, SessionModel.id == EmotionEvent.session_id)
        .where(SessionModel.family_id == family_id)
        .where(EmotionEvent.ts >= start_dt)
        .where(EmotionEvent.ts <= end_dt)
    ).one()
    
    return DailyReportResponse(
        date=date,
        session_count=0,  # TODO: 计算会话数
        total_duration_seconds=0,
        emotion_event_count=stats[0] or 0,
        emotion_events_by_level={},
        avg_anger_score=round(stats[1] or 0.0, 4),
        max_anger_score=stats[2] or 0.0,
        feedback_shown_count=0,
        feedback_accepted_count=0,
        feedback_accepted_rate=0.0,
        improvement_score=0.0,
        trend_direction="stable",
    )


@app.get("/v1/reports/timeseries/{session_id}")
def get_timeseries_report(
    session_id: str,
    db: Session = Depends(get_db),
    user_id: str = Depends(get_current_user_id),
) -> TimeSeriesResponse:
    family_id = get_family_by_session(db, session_id)
    ensure_family_member(db, family_id, user_id)

    events = db.execute(
        select(EmotionEvent)
        .where(EmotionEvent.session_id == session_id)
        .order_by(EmotionEvent.ts)
    ).scalars().all()

    return TimeSeriesResponse(
        session_id=session_id,
        points=[
            TimeSeriesPoint(
                timestamp=e.ts.isoformat(),
                anger_score=e.anger_score,
                emotion_level=e.emotion_level,
                speaker_id=e.speaker_id,
            )
            for e in events
        ],
    )


@app.get("/v1/reports/family/{family_id}/range")
def get_family_range_report(
    family_id: str,
    start: str,
    end: str,
    db: Session = Depends(get_db),
    user_id: str = Depends(get_current_user_id),
) -> dict:
    ensure_family_member(db, family_id, user_id)
    
    start_dt = datetime.fromisoformat(start)
    end_dt = datetime.fromisoformat(end)
    
    # 按天聚合
    daily_data = db.execute(
        select(
            func.strftime("%Y-%m-%d", EmotionEvent.ts).label("date"),
            func.count(EmotionEvent.id),
            func.avg(EmotionEvent.anger_score),
            func.sum(case((EmotionEvent.anger_score >= 0.7, 1), else_=0)),
        )
        .select_from(EmotionEvent)
        .join(SessionModel, SessionModel.id == EmotionEvent.session_id)
        .where(SessionModel.family_id == family_id)
        .where(EmotionEvent.ts >= start_dt)
        .where(EmotionEvent.ts <= end_dt)
        .group_by("date")
        .order_by("date")
    ).all()
    
    return {
        "family_id": family_id,
        "start": start,
        "end": end,
        "daily_data": [
            {
                "date": row.date,
                "event_count": row[1],
                "avg_anger_score": round(row[2] or 0.0, 4),
                "high_emotion_count": row[3],
            }
            for row in daily_data
        ],
    }


# ==================== Goal APIs ====================

@app.post("/v1/goals")
def create_goal(
    payload: GoalCreateRequest,
    family_id: str = Query(...),
    db: Session = Depends(get_db),
    user_id: str = Depends(get_current_user_id),
) -> dict:
    ensure_family_member(db, family_id, user_id)
    
    goal_id = str(uuid.uuid4())
    goal = UserGoal(
        id=goal_id,
        user_id=user_id,
        family_id=family_id,
        goal_type=payload.goal_type,
        title=payload.title,
        description=payload.description,
        target_value=payload.target_value,
        unit=payload.unit,
        start_date=payload.start_date,
        end_date=payload.end_date,
        created_at=now_utc(),
    )
    db.add(goal)
    db.commit()
    
    return {"goal_id": goal_id, "status": "created"}


@app.get("/v1/goals")
def list_goals(
    family_id: str = Query(...),
    db: Session = Depends(get_db),
    user_id: str = Depends(get_current_user_id),
) -> dict:
    ensure_family_member(db, family_id, user_id)
    
    goals = db.execute(
        select(UserGoal).where(
            UserGoal.family_id == family_id,
            UserGoal.user_id == user_id,
        ).order_by(desc(UserGoal.created_at))
    ).scalars().all()
    
    return {
        "goals": [
            {
                "id": g.id,
                "goal_type": g.goal_type,
                "title": g.title,
                "description": g.description,
                "target_value": g.target_value,
                "current_value": g.current_value,
                "progress_percentage": g.progress_percentage,
                "unit": g.unit,
                "status": g.status,
                "start_date": g.start_date,
                "end_date": g.end_date,
            }
            for g in goals
        ],
    }


# ==================== Analytics APIs ====================

@app.post("/v1/analytics/events")
def track_event(
    payload: AnalyticsEventRequest,
    db: Session = Depends(get_db),
    user_id: str = Depends(get_current_user_id),
) -> dict:
    event = AnalyticsEvent(
        event_name=payload.event_name,
        user_id=user_id,
        properties=payload.properties,
        client_ts=payload.client_ts,
        ts=now_utc(),
    )
    db.add(event)
    db.commit()
    
    return {"status": "tracked"}


# ==================== WebSocket Real-time ====================

@app.websocket("/v1/realtime/ws")
async def realtime_ws(websocket: WebSocket) -> None:
    await websocket.accept()
    db = SessionLocal()
    
    try:
        while True:
            message = await websocket.receive_json()
            msg_type = message.get("type")
            
            if msg_type == "analyze":
                await _handle_analyze_message(websocket, message, db)
            elif msg_type == "feedback_action":
                await _handle_feedback_action(websocket, message, db)
            elif msg_type == "ping":
                await websocket.send_json({"type": "pong", "ts": now_utc().isoformat()})
            else:
                await websocket.send_json({"type": "error", "detail": "unknown message type"})
                
    except WebSocketDisconnect:
        pass
    finally:
        db.close()


async def _handle_analyze_message(websocket: WebSocket, message: dict, db: Session) -> None:
    """处理分析消息"""
    session_id = message.get("session_id")
    speaker_id = message.get("speaker_id", "unknown")
    transcript = message.get("transcript", "")
    audio_data = message.get("audio")  # base64编码的音频
    
    if not session_id:
        await websocket.send_json({"type": "error", "detail": "session_id is required"})
        return
    
    session = db.get(SessionModel, session_id)
    if not session:
        await websocket.send_json({"type": "error", "detail": "session not found"})
        return
    
    # 模拟情绪分析（实际应解码音频）
    # 这里使用模拟数据，实际应调用 emotion_analyzer.analyze()
    anger_score = max(0.0, min(1.0, float(message.get("anger_score", 0.0))))
    
    # 确定情绪等级
    if anger_score < 0.3:
        emotion_level = "calm"
    elif anger_score < 0.5:
        emotion_level = "mild"
    elif anger_score < 0.7:
        emotion_level = "moderate"
    elif anger_score < 0.85:
        emotion_level = "high"
    else:
        emotion_level = "extreme"
    
    # 生成反馈
    feedback = feedback_generator.generate_feedback(
        user_id=speaker_id,
        emotion_level=emotion_level,
        anger_score=anger_score,
    )
    
    # 保存情绪事件
    emotion_event = EmotionEvent(
        session_id=session_id,
        family_id=session.family_id,
        speaker_id=speaker_id,
        ts=now_utc(),
        transcript=transcript,
        anger_score=anger_score,
        emotion_level=emotion_level,
    )
    db.add(emotion_event)
    db.flush()  # 获取ID
    
    # 保存反馈事件
    feedback_token = str(uuid.uuid4())
    if feedback:
        feedback_event = FeedbackEvent(
            token=feedback_token,
            session_id=session_id,
            emotion_event_id=emotion_event.id,
            speaker_id=speaker_id,
            feedback_level=feedback.level,
            message=feedback.message,
            strategy=feedback.strategy,
            shown_at=now_utc(),
        )
        db.add(feedback_event)
        
        # 更新会话统计
        session.feedback_shown_count += 1
    
    # 更新会话统计
    session.total_emotion_events += 1
    if anger_score > session.max_anger_score:
        session.max_anger_score = anger_score
    
    db.commit()
    
    # 发送结果
    response = {
        "type": "analysis_result",
        "ts": now_utc().isoformat(),
        "session_id": session_id,
        "speaker_id": speaker_id,
        "anger_score": anger_score,
        "emotion_level": emotion_level,
    }
    
    if feedback:
        response["feedback"] = {
            "token": feedback_token,
            "level": feedback.level,
            "message": feedback.message,
            "strategy": feedback.strategy,
            "duration_seconds": feedback.duration_seconds,
        }
    
    await websocket.send_json(response)


async def _handle_feedback_action(websocket: WebSocket, message: dict, db: Session) -> None:
    """处理反馈动作消息"""
    feedback_token = message.get("feedback_token")
    action = message.get("action")
    
    if not feedback_token or not action:
        await websocket.send_json({"type": "error", "detail": "feedback_token and action required"})
        return
    
    feedback = db.execute(
        select(FeedbackEvent).where(FeedbackEvent.token == feedback_token)
    ).scalar_one_or_none()
    
    if not feedback:
        await websocket.send_json({"type": "error", "detail": "feedback not found"})
        return
    
    feedback.action = action
    feedback.acted_at = now_utc()
    
    # 计算响应时间
    if feedback.shown_at:
        response_time = (feedback.acted_at - feedback.shown_at).total_seconds() * 1000
        feedback.user_response_time_ms = int(response_time)
    
    # 更新会话统计
    if action == "accepted":
        session = db.get(SessionModel, feedback.session_id)
        session.feedback_accepted_count += 1
    
    db.commit()
    
    await websocket.send_json({
        "type": "feedback_action_confirmed",
        "feedback_token": feedback_token,
        "action": action,
    })
