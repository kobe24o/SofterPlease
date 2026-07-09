from __future__ import annotations

import asyncio
import logging
import os
import uuid
from datetime import date, datetime, time, timedelta, timezone
from pathlib import Path
from typing import Any, Optional
from urllib.parse import urlparse

import httpx
import jwt
import numpy as np
import soundfile as sf

# 配置日志
logger = logging.getLogger(__name__)

from fastapi import Depends, FastAPI, Header, HTTPException, Query, WebSocket, WebSocketDisconnect, UploadFile, File
from fastapi.responses import FileResponse
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field
from sqlalchemy import case, func, select, desc
from sqlalchemy.orm import Session

from .db import Base, SessionLocal, engine
from .models import (
    EmotionEvent, Family, FamilyMember, FeedbackEvent, Session as SessionModel, User,
    VoiceProfile, DailyStats, WeeklyStats, UserGoal, AnalyticsEvent, UserNotification,
    EmotionLevel, ConversationSegment, AdviceReport, SpeakerIdentity,
)
from .emotion_engine import EmotionAnalyzer, VoiceRecognizer, FeedbackGenerator, AudioProcessor
from .conversation_service import (
    ConversationService,
    MAX_DIARIZATION_SEGMENT_SECONDS,
    MAX_MODEL_SEGMENT_SECONDS,
    MAX_RECORDING_SECONDS,
)
from .training_service import TrainingService

APP_VERSION = "2.0.0"
JWT_SECRET = os.getenv("JWT_SECRET", "dev-secret-change-me")
JWT_EXPIRE_MINUTES = int(os.getenv("JWT_EXPIRE_MINUTES", "120"))
REPO_ROOT = Path(__file__).resolve().parents[2]
BACKEND_ROOT = Path(__file__).resolve().parents[1]
DEBUG_AUDIO_DIR = Path(os.getenv("DEBUG_AUDIO_DIR", "debug_audio"))
if not DEBUG_AUDIO_DIR.is_absolute():
    DEBUG_AUDIO_DIR = BACKEND_ROOT / DEBUG_AUDIO_DIR
DEBUG_AUDIO_MAX_ITEMS = int(os.getenv("DEBUG_AUDIO_MAX_ITEMS", "100"))
CONVERSATION_AUDIO_DIR = BACKEND_ROOT / os.getenv("CONVERSATION_AUDIO_DIR", "conversation_audio")

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
training_service = TrainingService(
    REPO_ROOT,
    DEBUG_AUDIO_DIR,
    on_model_ready=lambda path, version: emotion_analyzer.load_tri_class_calibrator(str(path), version),
)
conversation_service = ConversationService()


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


class LocalFamilyMemberCreateRequest(BaseModel):
    display_name: str = Field(min_length=1, max_length=64)


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
    emotion_value: int
    emotion_dimensions: dict
    acoustic_features: dict
    confidence: float
    model_backend: str
    raw_emotions: dict
    transcript: str
    speaker_id: str
    speaker_confidence: float


class DebugAudioLabelRequest(BaseModel):
    label: int = Field(ge=-1, le=1)
    note: Optional[str] = None


class CorpusUpdateRequest(BaseModel):
    ids: list[str] = Field(min_length=1)
    selected: Optional[bool] = None
    label: Optional[int] = Field(default=None, ge=-1, le=1)
    transcript: Optional[str] = None


class TrainingJobRequest(BaseModel):
    version_name: Optional[str] = None
    test_ratio: float = Field(default=0.2, ge=0.1, le=0.5)
    activate_after_training: bool = True


class ModelVersionLoadRequest(BaseModel):
    version: str = Field(min_length=1)


class SpeakerConfirmRequest(BaseModel):
    user_id: str = Field(min_length=1)


class SegmentSpeakerAssignRequest(BaseModel):
    user_id: str = Field(min_length=1)
    learn_voice: bool = False


class SpeakerRenameRequest(BaseModel):
    display_name: str = Field(min_length=1, max_length=64)


class AdviceGenerateRequest(BaseModel):
    family_id: str = Field(min_length=1)
    report_date: Optional[str] = None
    timezone_offset_minutes: int = Field(default=480, ge=-720, le=840)
    provider: str = Field(default="openai-compatible")
    base_url: str = Field(default="https://api.openai.com/v1", min_length=1)
    model: str = Field(default="gpt-4o-mini", min_length=1)
    api_key: Optional[str] = None


class AdviceConnectionTestRequest(BaseModel):
    base_url: str = Field(min_length=1)
    model: str = Field(min_length=1)
    api_key: Optional[str] = None


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


def safe_audio_suffix(filename: str | None) -> str:
    if not filename or "." not in filename:
        return ".wav"
    suffix = Path(filename).suffix.lower()
    if suffix in {".wav", ".mp3", ".m4a", ".webm", ".ogg", ".flac", ".aac"}:
        return suffix
    return ".wav"


def save_debug_audio_record(
    *,
    audio_data: bytes,
    filename: str | None,
    session_id: str,
    family_id: str,
    user_id: str,
    speaker_id: str,
    transcript: str,
    source: str,
    emotion_payload: dict[str, Any],
    audio_duration_ms: int,
    sample_rate: int,
) -> None:
    try:
        DEBUG_AUDIO_DIR.mkdir(parents=True, exist_ok=True)
        record_id = str(uuid.uuid4())
        created_at = now_utc()
        suffix = safe_audio_suffix(filename)
        audio_name = f"{created_at.strftime('%Y%m%dT%H%M%S')}_{record_id}{suffix}"
        audio_path = DEBUG_AUDIO_DIR / audio_name
        audio_path.write_bytes(audio_data)

        metadata = {
            "id": record_id,
            "created_at": created_at.isoformat(),
            "session_id": session_id,
            "family_id": family_id,
            "user_id": user_id,
            "speaker_id": speaker_id,
            "transcript": transcript,
            "source": source,
            "filename": filename or audio_name,
            "audio_file": audio_name,
            "audio_url": f"/v1/debug/audio/{record_id}/file",
            "audio_bytes": len(audio_data),
            "audio_duration_ms": audio_duration_ms,
            "sample_rate": sample_rate,
            "result": emotion_payload,
        }
        (DEBUG_AUDIO_DIR / f"{record_id}.json").write_text(
            json_dumps(metadata),
            encoding="utf-8",
        )
        prune_debug_audio_records()
    except Exception as exc:
        logger.warning("Failed to save debug audio record: %s", exc)


def json_dumps(payload: dict[str, Any]) -> str:
    import json

    return json.dumps(payload, ensure_ascii=False, indent=2, default=str)


def read_debug_audio_records(limit: int = 30) -> list[dict[str, Any]]:
    import json

    if not DEBUG_AUDIO_DIR.exists():
        return []

    records = []
    for meta_path in DEBUG_AUDIO_DIR.glob("*.json"):
        try:
            records.append(json.loads(meta_path.read_text(encoding="utf-8")))
        except Exception as exc:
            logger.warning("Failed to read debug audio metadata %s: %s", meta_path, exc)

    records.sort(key=lambda item: item.get("created_at", ""), reverse=True)
    return records[:limit]


def prune_debug_audio_records() -> None:
    records = read_debug_audio_records(limit=DEBUG_AUDIO_MAX_ITEMS + 50)
    for stale in records[DEBUG_AUDIO_MAX_ITEMS:]:
        try:
            audio_file = stale.get("audio_file")
            if audio_file:
                (DEBUG_AUDIO_DIR / audio_file).unlink(missing_ok=True)
            (DEBUG_AUDIO_DIR / f"{stale['id']}.json").unlink(missing_ok=True)
        except Exception as exc:
            logger.warning("Failed to prune debug audio record: %s", exc)


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


def elapsed_ms(start: datetime, end: datetime) -> int:
    """计算耗时，兼容 SQLite 取回的 naive datetime。"""
    if start.tzinfo is None and end.tzinfo is not None:
        end = end.replace(tzinfo=None)
    elif start.tzinfo is not None and end.tzinfo is None:
        start = start.replace(tzinfo=None)
    return int((end - start).total_seconds() * 1000)


def family_member_names(db: Session, family_id: str) -> dict[str, str]:
    rows = db.execute(
        select(User, FamilyMember)
        .join(FamilyMember, User.id == FamilyMember.user_id)
        .where(FamilyMember.family_id == family_id)
    ).all()
    names = {
        row.User.id: row.FamilyMember.display_name or row.User.nickname
        for row in rows
    }
    identities = db.execute(
        select(SpeakerIdentity).where(SpeakerIdentity.family_id == family_id)
    ).scalars().all()
    names.update({identity.id: identity.display_name for identity in identities})
    return names


def serialize_segment(segment: ConversationSegment, names: dict[str, str]) -> dict[str, Any]:
    resolved_id = segment.corrected_speaker_id or segment.predicted_speaker_id
    return {
        "id": segment.id,
        "session_id": segment.session_id,
        "sequence_index": segment.sequence_index,
        "started_at_ms": segment.started_at_ms,
        "ended_at_ms": segment.ended_at_ms,
        "created_at": segment.created_at.isoformat(),
        "audio_url": f"/v1/conversation-segments/{segment.id}/audio",
        "audio_sample_rate": segment.audio_sample_rate,
        "transcript": segment.transcript,
        "transcript_confidence": segment.transcript_confidence,
        "language": segment.language,
        "emotion_value": segment.emotion_value,
        "emotion_label": segment.emotion_label,
        "anger_score": segment.anger_score,
        "emotion_level": segment.emotion_level,
        "emotion_dimensions": {
            "valence": segment.valence,
            "arousal": segment.arousal,
            "dominance": segment.dominance,
            "stress": segment.stress,
            "impatience": segment.impatience,
        },
        "confidence": segment.emotion_confidence,
        "model_backend": segment.model_backend,
        "raw_emotions": segment.raw_emotions,
        "acoustic_features": segment.acoustic_features,
        "speaker_cluster": segment.speaker_cluster,
        "predicted_speaker_id": segment.predicted_speaker_id,
        "corrected_speaker_id": segment.corrected_speaker_id,
        "resolved_speaker_id": resolved_id,
        "resolved_speaker_name": names.get(resolved_id or "", segment.speaker_cluster),
        "speaker_confidence": segment.speaker_confidence,
        "role_confirmed": segment.role_confirmed,
        "assignment_source": segment.assignment_source,
    }


def load_family_voice_profiles(db: Session, family_id: str) -> dict[str, np.ndarray]:
    expected_dim = voice_recognizer.embedding_dim

    def migrate_embedding(speaker_id: str, raw_embedding: Any) -> np.ndarray:
        embedding = np.asarray(raw_embedding, dtype=np.float32).reshape(-1)
        if embedding.size == expected_dim:
            return embedding
        rows = db.execute(
            select(ConversationSegment).where(
                ConversationSegment.family_id == family_id,
                func.coalesce(
                    ConversationSegment.corrected_speaker_id,
                    ConversationSegment.predicted_speaker_id,
                    ConversationSegment.speaker_cluster,
                ) == speaker_id,
            ).order_by(ConversationSegment.created_at.desc()).limit(3)
        ).scalars().all()
        migrated: list[np.ndarray] = []
        for row in rows:
            path = Path(row.audio_storage_path)
            if not path.is_file():
                continue
            audio, sample_rate = sf.read(path, dtype="float32", always_2d=False)
            if np.asarray(audio).ndim > 1:
                audio = np.mean(audio, axis=1)
            migrated.append(voice_recognizer.extract_embedding(np.asarray(audio), sample_rate))
        if not migrated:
            return np.asarray([], dtype=np.float32)
        embedding = np.mean(np.asarray(migrated), axis=0)
        return embedding / max(float(np.linalg.norm(embedding)), 1e-8)

    profiles = db.execute(
        select(VoiceProfile).where(
            VoiceProfile.family_id == family_id,
            VoiceProfile.is_active.is_(True),
        )
    ).scalars().all()
    result: dict[str, np.ndarray] = {}
    for profile in profiles:
        embedding = migrate_embedding(profile.user_id, profile.voice_embedding)
        if embedding.size:
            result[profile.user_id] = embedding
            if len(profile.voice_embedding) != embedding.size:
                profile.voice_embedding = embedding.tolist()
                profile.embedding_version = "campplus-v1"
    identities = db.execute(
        select(SpeakerIdentity).where(SpeakerIdentity.family_id == family_id)
    ).scalars().all()
    for identity in identities:
        embedding = migrate_embedding(identity.id, identity.voice_embedding)
        if embedding.size:
            result[identity.id] = embedding
            if len(identity.voice_embedding) != embedding.size:
                identity.voice_embedding = embedding.tolist()
                identity.embedding_version = "campplus-v1"
    db.flush()
    return result


def next_speaker_name(db: Session, family_id: str) -> str:
    count = db.execute(
        select(func.count(SpeakerIdentity.id)).where(SpeakerIdentity.family_id == family_id)
    ).scalar_one()
    return f"说话人 {int(count) + 1}"


def chat_completions_endpoint(base_url: str) -> str:
    normalized = base_url.strip().rstrip("/")
    if normalized.endswith("/chat/completions"):
        return normalized
    return f"{normalized}/chat/completions"


def provider_error_message(response: httpx.Response) -> str:
    try:
        body = response.json()
        message = body.get("error", {}).get("message") or body.get("message") or body.get("detail")
        if message:
            return str(message)[:300]
    except ValueError:
        pass
    text = response.text.strip().replace("\n", " ")
    return text[:300] if text else "服务商未返回错误详情"


async def call_chat_completions(
    *,
    base_url: str,
    model: str,
    api_key: str | None,
    messages: list[dict[str, str]],
    max_tokens: int,
) -> str:
    parsed = urlparse(base_url.strip())
    if parsed.scheme not in {"http", "https"} or not parsed.netloc or parsed.username or parsed.password:
        raise HTTPException(status_code=400, detail="大模型 Base URL 无效")
    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key.strip()}"
    request_body = {
        "model": model.strip(),
        "temperature": 0.4,
        "stream": False,
        "max_tokens": max_tokens,
        "messages": messages,
    }
    timeout = httpx.Timeout(180.0, connect=20.0)
    try:
        # Do not inherit desktop VPN/proxy environment variables. The backend
        # connects directly so phone-side VPN state cannot alter this request.
        async with httpx.AsyncClient(timeout=timeout, trust_env=False) as client:
            response = await client.post(
                chat_completions_endpoint(base_url),
                headers=headers,
                json=request_body,
            )
    except httpx.TimeoutException as exc:
        raise HTTPException(status_code=504, detail="大模型响应超时，请稍后重试") from exc
    except httpx.HTTPError as exc:
        raise HTTPException(status_code=502, detail=f"无法连接大模型服务：{type(exc).__name__}") from exc
    if response.is_error:
        raise HTTPException(
            status_code=502,
            detail=f"大模型服务返回 HTTP {response.status_code}：{provider_error_message(response)}",
        )
    try:
        body = response.json()
        message = body["choices"][0]["message"]
        content = str(message.get("content") or message.get("reasoning_content") or "").strip()
    except (ValueError, KeyError, IndexError, TypeError) as exc:
        raise HTTPException(status_code=502, detail="大模型返回格式不兼容") from exc
    if not content:
        raise HTTPException(status_code=502, detail="大模型返回了空内容")
    return content


def local_day_bounds(day: date, offset_minutes: int) -> tuple[datetime, datetime]:
    local_tz = timezone(timedelta(minutes=offset_minutes))
    start = datetime.combine(day, time.min, tzinfo=local_tz).astimezone(timezone.utc)
    return start, start + timedelta(days=1)


def as_utc(value: datetime) -> datetime:
    return value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value.astimezone(timezone.utc)


def build_advice_snapshot(
    db: Session,
    family_id: str,
    report_day: date,
    offset_minutes: int,
) -> dict[str, Any]:
    today_start, today_end = local_day_bounds(report_day, offset_minutes)
    current_start = today_end - timedelta(days=7)
    previous_start = current_start - timedelta(days=7)
    rows = db.execute(
        select(ConversationSegment).where(
            ConversationSegment.family_id == family_id,
            ConversationSegment.created_at >= previous_start,
            ConversationSegment.created_at < today_end,
        ).order_by(ConversationSegment.created_at, ConversationSegment.sequence_index)
    ).scalars().all()
    names = family_member_names(db, family_id)

    def period_stats(items: list[ConversationSegment]) -> dict[str, Any]:
        values = [item.emotion_value for item in items]
        return {
            "utterance_count": len(items),
            "average_emotion": round(sum(values) / len(values), 3) if values else None,
            "negative_ratio": round(sum(value < 0 for value in values) / len(values), 3) if values else None,
        }

    today_rows = [row for row in rows if today_start <= as_utc(row.created_at) < today_end]
    current_rows = [row for row in rows if current_start <= as_utc(row.created_at) < today_end]
    previous_rows = [row for row in rows if previous_start <= as_utc(row.created_at) < current_start]
    role_stats: dict[str, dict[str, Any]] = {}
    for row in today_rows:
        speaker_id = row.corrected_speaker_id or row.predicted_speaker_id
        resolved_id = speaker_id or row.speaker_cluster
        role = names.get(resolved_id, row.speaker_cluster)
        bucket = role_stats.setdefault(resolved_id, {
            "speaker_id": resolved_id,
            "display_name": role,
            "utterance_count": 0,
            "emotion_total": 0,
            "negative_count": 0,
        })
        bucket["utterance_count"] += 1
        bucket["emotion_total"] += row.emotion_value
        bucket["negative_count"] += int(row.emotion_value < 0)
    for bucket in role_stats.values():
        count = bucket["utterance_count"]
        bucket["average_emotion"] = round(bucket.pop("emotion_total") / count, 3)
        bucket["negative_ratio"] = round(bucket.pop("negative_count") / count, 3)

    dialogues = []
    for row in today_rows[-120:]:
        speaker_id = row.corrected_speaker_id or row.predicted_speaker_id
        dialogues.append({
            "time": row.created_at.isoformat(),
            "speaker_id": speaker_id or row.speaker_cluster,
            "speaker_name": names.get(speaker_id or "", row.speaker_cluster),
            "role_confirmed": row.role_confirmed,
            "text": row.transcript,
            "emotion_value": row.emotion_value,
            "emotion_label": row.emotion_label,
        })
    return {
        "report_date": report_day.isoformat(),
        "today": period_stats(today_rows),
        "current_7_days": period_stats(current_rows),
        "previous_7_days": period_stats(previous_rows),
        "today_by_speaker": list(role_stats.values()),
        "today_dialogues": dialogues,
    }


# ==================== Health Check ====================

@app.get("/")
def root() -> dict[str, Any]:
    return {
        "name": "SofterPlease API",
        "version": APP_VERSION,
        "status": "running",
        "docs": "/docs",
        "health": "/health",
        "system_info": "/v1/system/info",
    }


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
def system_info() -> dict[str, Any]:
    return {
        "version": APP_VERSION,
        "server_time": now_utc().isoformat(),
        "features": [
            "emotion_analysis", "voice_recognition", "realtime_feedback",
            "long_recording_vad", "speaker_diarization", "family_advice",
        ],
        "audio": {
            "max_recording_seconds": MAX_RECORDING_SECONDS,
            "max_model_segment_seconds": MAX_MODEL_SEGMENT_SECONDS,
            "speaker_window_seconds": MAX_DIARIZATION_SEGMENT_SECONDS,
        },
        "speaker_model": voice_recognizer.get_stats(),
        "emotion_model": emotion_analyzer.get_status(),
    }


@app.post("/v1/system/emotion-model/load")
def load_emotion_model() -> dict[str, Any]:
    loaded = emotion_analyzer.ensure_model_loaded()
    speaker_loaded = voice_recognizer.ensure_model_loaded()
    return {
        "loaded": loaded,
        "speaker_model_loaded": speaker_loaded,
        "emotion_model": emotion_analyzer.get_status(),
        "speaker_model": voice_recognizer.get_stats(),
    }


@app.get("/v1/debug/audio")
def list_debug_audio(limit: int = Query(default=30, ge=1, le=100)) -> dict[str, Any]:
    return {
        "items": read_debug_audio_records(limit=limit),
    }


@app.get("/v1/debug/audio/{record_id}/file")
def get_debug_audio_file(record_id: str) -> FileResponse:
    records = read_debug_audio_records(limit=DEBUG_AUDIO_MAX_ITEMS)
    record = next((item for item in records if item.get("id") == record_id), None)
    if not record:
        raise HTTPException(status_code=404, detail="debug audio not found")

    audio_file = record.get("audio_file")
    if not audio_file:
        raise HTTPException(status_code=404, detail="debug audio file missing")

    audio_path = DEBUG_AUDIO_DIR / audio_file
    if not audio_path.exists() or not audio_path.is_file():
        raise HTTPException(status_code=404, detail="debug audio file missing")

    media_types = {
        ".wav": "audio/wav",
        ".mp3": "audio/mpeg",
        ".m4a": "audio/mp4",
        ".webm": "audio/webm",
        ".ogg": "audio/ogg",
        ".flac": "audio/flac",
        ".aac": "audio/aac",
    }
    return FileResponse(
        path=audio_path,
        media_type=media_types.get(audio_path.suffix.lower(), "application/octet-stream"),
        filename=record.get("filename") or audio_file,
    )


@app.post("/v1/debug/audio/{record_id}/label")
def label_debug_audio(record_id: str, payload: DebugAudioLabelRequest) -> dict[str, Any]:
    import json

    metadata_path = DEBUG_AUDIO_DIR / f"{record_id}.json"
    if not metadata_path.exists():
        raise HTTPException(status_code=404, detail="debug audio not found")

    record = json.loads(metadata_path.read_text(encoding="utf-8"))
    record["human_label"] = payload.label
    record["label_note"] = payload.note or ""
    record["labeled_at"] = now_utc().isoformat()
    metadata_path.write_text(json_dumps(record), encoding="utf-8")
    return record


# ==================== Corpus Training APIs ====================

@app.get("/v1/training/corpus")
def list_training_corpus() -> dict[str, Any]:
    return {
        "items": training_service.list_corpus(),
        "summary": training_service.corpus_summary(),
    }


@app.post("/v1/training/corpus/update")
def update_training_corpus(payload: CorpusUpdateRequest) -> dict[str, Any]:
    summary = training_service.update_corpus(
        payload.ids,
        selected=payload.selected,
        label=payload.label,
        transcript=payload.transcript,
    )
    return {"updated": len(payload.ids), "summary": summary}


@app.get("/v1/training/corpus/synthetic/audio")
def get_synthetic_corpus_audio(path: str = Query(min_length=1)) -> FileResponse:
    try:
        audio_path = training_service.resolve_synthetic_audio(path)
    except FileNotFoundError as exc:
        raise HTTPException(status_code=404, detail="synthetic audio not found") from exc
    return FileResponse(path=audio_path, media_type="audio/wav", filename=audio_path.name)


@app.post("/v1/training/jobs")
def start_training_job(payload: TrainingJobRequest) -> dict[str, Any]:
    try:
        return training_service.start_job(
            payload.version_name,
            payload.test_ratio,
            payload.activate_after_training,
        )
    except RuntimeError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc


@app.get("/v1/training/jobs/current")
def get_current_training_job() -> dict[str, Any]:
    return {"job": training_service.get_job()}


@app.get("/v1/training/models")
def list_training_models() -> dict[str, Any]:
    return {
        "items": training_service.list_models(),
        "active_model": emotion_analyzer.get_status().get("tri_class_calibrator_version"),
    }


@app.post("/v1/training/models/load")
def load_training_model_version(payload: ModelVersionLoadRequest) -> dict[str, Any]:
    try:
        path = training_service.activate_model(payload.version)
    except FileNotFoundError as exc:
        raise HTTPException(status_code=404, detail="model version not found") from exc
    return {
        "loaded": True,
        "version": payload.version,
        "path": str(path),
        "emotion_model": emotion_analyzer.get_status(),
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
    
    try:
        # 开始事务
        db.add(user)
        
        # 自动为新用户创建家庭
        family_id = str(uuid.uuid4())
        family = Family(
            id=family_id,
            name=f"{payload.nickname}的家庭",
            owner_user_id=user_id,
            invite_code=generate_invite_code(),
            created_at=now_utc(),
        )
        db.add(family)
        
        # 将用户添加为家庭管理员
        family_member = FamilyMember(
            family_id=family_id,
            user_id=user_id,
            role="owner",
            joined_at=now_utc(),
        )
        db.add(family_member)
        
        # 提交事务
        db.commit()
        return UserCreateResponse(user_id=user_id, nickname=payload.nickname)
    except Exception as e:
        # 回滚事务
        db.rollback()
        logger.error(f"Failed to create user with family: {e}")
        raise HTTPException(status_code=500, detail="Failed to create user")


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
    
    # 更新最后登录时间
    user.last_login_at = now_utc()
    db.commit()
    
    # 获取用户家庭信息
    families = db.execute(
        select(Family, FamilyMember)
        .join(FamilyMember, Family.id == FamilyMember.family_id)
        .where(FamilyMember.user_id == user.id)
    ).all()
    
    token = issue_jwt(payload.user_id)
    
    return AuthLoginResponse(
        access_token=token,
        expires_in=JWT_EXPIRE_MINUTES * 60,
        user={
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


@app.post("/v1/families/{family_id}/local-members")
def add_local_member(
    family_id: str,
    payload: LocalFamilyMemberCreateRequest,
    db: Session = Depends(get_db),
    user_id: str = Depends(get_current_user_id),
) -> dict[str, str]:
    family = db.get(Family, family_id)
    if not family:
        raise HTTPException(status_code=404, detail="family not found")
    ensure_family_member(db, family_id, user_id)

    display_name = payload.display_name.strip()
    if not display_name:
        raise HTTPException(status_code=400, detail="display name cannot be empty")

    member_user_id = f"local_{uuid.uuid4().hex[:12]}"
    user = User(id=member_user_id, nickname=display_name)
    db.add(user)
    db.add(FamilyMember(
        family_id=family_id,
        user_id=member_user_id,
        role="member",
        display_name=display_name,
    ))
    db.commit()
    return {"status": "added", "user_id": member_user_id, "display_name": display_name}


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


@app.post("/v1/voice/analyze")
async def analyze_voice(
    audio: UploadFile = File(...),
    session_id: str = None,
    device_id: str = None,
    db: Session = Depends(get_db),
    user_id: str = Depends(get_current_user_id),
) -> dict:
    """分析语音情绪"""
    try:
        # 读取音频文件
        audio_data = await audio.read()
        
        # 尝试处理音频，捕获格式错误
        try:
            # 处理音频
            processed_audio = audio_processor.process_audio(audio_data)
        except Exception as e:
            logger.warning(f"Audio processing error: {e}, trying alternative approach")
            # 如果处理失败，尝试直接使用音频数据（适用于浏览器录制的格式）
            # 这里可以添加更多的错误处理和格式转换逻辑
            raise HTTPException(status_code=400, detail="Unsupported audio format")
        
        # 分析情绪
        emotion_result = emotion_analyzer.analyze(processed_audio)
        
        # 生成反馈
        feedback = feedback_generator.generate_feedback(
            user_id=user_id,
            emotion_level=emotion_result.emotion_level,
            anger_score=emotion_result.anger_score,
        )
        
        # 保存情绪事件
        if session_id:
            emotion_event = EmotionEvent(
                id=str(uuid.uuid4()),
                session_id=session_id,
                user_id=user_id,
                anger_score=emotion_result.anger_score,
                emotion_level=emotion_result.emotion_level,
                created_at=now_utc(),
            )
            db.add(emotion_event)
            db.commit()
        
        return {
            "anger_score": emotion_result.anger_score,
            "emotion_level": emotion_result.emotion_level,
            "emotion_value": emotion_result.emotion_value,
            "emotion_dimensions": emotion_result.to_dict()["emotion_dimensions"],
            "confidence": emotion_result.confidence,
            "model_backend": emotion_result.model_backend,
            "raw_emotions": emotion_result.raw_emotions,
            "feedback": feedback.to_dict() if feedback else None,
        }
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Voice analysis error: {e}")
        raise HTTPException(status_code=500, detail="Failed to analyze voice")


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


@app.get("/v1/sessions/{session_id}/events")
def list_session_events(
    session_id: str,
    limit: int = Query(default=50, ge=1, le=200),
    offset: int = Query(default=0, ge=0),
    db: Session = Depends(get_db),
    user_id: str = Depends(get_current_user_id),
) -> dict:
    family_id = get_family_by_session(db, session_id)
    ensure_family_member(db, family_id, user_id)

    events = db.execute(
        select(EmotionEvent)
        .where(EmotionEvent.session_id == session_id)
        .order_by(desc(EmotionEvent.ts))
        .limit(limit)
        .offset(offset)
    ).scalars().all()

    return {
        "session_id": session_id,
        "limit": limit,
        "offset": offset,
        "events": [
            {
                "id": event.id,
                "ts": event.ts.isoformat(),
                "speaker_id": event.speaker_id,
                "speaker_confidence": event.speaker_confidence,
                "transcript": event.transcript,
                "anger_score": event.anger_score,
                "emotion_level": event.emotion_level,
                "emotion_dimensions": event.emotion_dimensions,
            }
            for event in events
        ],
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
    effective_transcript = transcript.strip() or emotion_result.transcript
    
    # 保存到数据库
    emotion_event = EmotionEvent(
        session_id=session_id,
        family_id=family_id,
        speaker_id=detected_speaker,
        speaker_confidence=voice_result.confidence,
        ts=now_utc(),
        audio_duration_ms=int(processed.get_total_speech_duration() * 1000),
        transcript=effective_transcript,
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
    
    response = EmotionAnalysisResponse(
        anger_score=emotion_result.anger_score,
        emotion_level=emotion_result.emotion_level,
        emotion_value=emotion_result.emotion_value,
        emotion_dimensions=emotion_result.to_dict()["emotion_dimensions"],
        acoustic_features=emotion_result.acoustic_features,
        confidence=emotion_result.confidence,
        model_backend=emotion_result.model_backend,
        raw_emotions=emotion_result.raw_emotions,
        transcript=effective_transcript,
        speaker_id=detected_speaker,
        speaker_confidence=voice_result.confidence,
    )
    save_debug_audio_record(
        audio_data=audio_data,
        filename=audio.filename,
        session_id=session_id,
        family_id=family_id,
        user_id=user_id,
        speaker_id=detected_speaker,
        transcript=effective_transcript,
        source=session.device_type,
        emotion_payload=response.model_dump(),
        audio_duration_ms=int(processed.get_total_speech_duration() * 1000),
        sample_rate=processed.sample_rate,
    )
    return response


@app.post("/v1/sessions/{session_id}/analyze-long")
async def analyze_long_recording(
    session_id: str,
    audio: UploadFile = File(...),
    db: Session = Depends(get_db),
    user_id: str = Depends(get_current_user_id),
) -> dict[str, Any]:
    family_id = get_family_by_session(db, session_id)
    ensure_family_member(db, family_id, user_id)
    session = db.get(SessionModel, session_id)
    if not session or session.status != "active":
        raise HTTPException(status_code=400, detail="session not active")

    audio_data = await audio.read()
    if not audio_data:
        raise HTTPException(status_code=400, detail="empty audio")
    suffix = safe_audio_suffix(audio.filename).lstrip(".")
    try:
        audio_array, source_sr = audio_processor.load_audio(audio_data, format=suffix)
    except Exception as exc:
        raise HTTPException(status_code=400, detail=f"invalid audio: {exc}") from exc
    duration_seconds = len(audio_array) / max(source_sr, 1)
    if duration_seconds > MAX_RECORDING_SECONDS + 1:
        raise HTTPException(
            status_code=413,
            detail=f"recording exceeds {int(MAX_RECORDING_SECONDS)} seconds",
        )

    processed = audio_processor.preprocess(audio_array, source_sr)
    slices = conversation_service.split_audio(processed.audio, processed.sample_rate)
    if not slices:
        raise HTTPException(status_code=422, detail="no speech detected")

    embeddings = [voice_recognizer.extract_embedding(item.audio, processed.sample_rate) for item in slices]
    clusters = conversation_service.cluster_embeddings(embeddings)
    known_profiles = load_family_voice_profiles(db, family_id)
    learned_identities = db.execute(
        select(SpeakerIdentity).where(SpeakerIdentity.family_id == family_id)
    ).scalars().all()
    learned_identity_by_id = {identity.id: identity for identity in learned_identities}
    auto_profile_ids = set(learned_identity_by_id)
    names = family_member_names(db, family_id)
    cluster_speakers: dict[str, tuple[str, float]] = {}
    for cluster in dict.fromkeys(clusters):
        member_indexes = [index for index, label in enumerate(clusters) if label == cluster]
        members = [embeddings[index] for index in member_indexes]
        centroid = np.mean(np.asarray(members, dtype=np.float32), axis=0)
        centroid /= max(float(np.linalg.norm(centroid)), 1e-8)
        duration_ms = sum(
            slices[index].end_ms(processed.sample_rate) - slices[index].start_ms(processed.sample_rate)
            for index in member_indexes
        )
        match = conversation_service.match_speaker_profile(centroid, known_profiles, auto_profile_ids)
        if match is None:
            identity = SpeakerIdentity(
                id=f"spk_{uuid.uuid4().hex[:12]}",
                family_id=family_id,
                display_name=next_speaker_name(db, family_id),
                voice_embedding=centroid.tolist(),
                embedding_version="campplus-v1",
                sample_count=len(members),
                total_duration_ms=duration_ms,
            )
            db.add(identity)
            db.flush()
            best_id, best_score = identity.id, 1.0
            known_profiles[identity.id] = centroid
            learned_identity_by_id[identity.id] = identity
            auto_profile_ids.add(identity.id)
            names[identity.id] = identity.display_name
        else:
            best_id, best_score = match.speaker_id, match.confidence
            identity = learned_identity_by_id.get(best_id)
            if identity is not None:
                updated = conversation_service.update_speaker_centroid(
                    identity.voice_embedding,
                    centroid,
                    identity.sample_count,
                )
                identity.voice_embedding = updated.tolist()
                identity.sample_count += len(members)
                identity.total_duration_ms += duration_ms
                known_profiles[best_id] = updated
        cluster_speakers[cluster] = (best_id, best_score)
    output_dir = CONVERSATION_AUDIO_DIR / session_id
    output_dir.mkdir(parents=True, exist_ok=True)
    created: list[ConversationSegment] = []

    for index, (item, embedding, cluster) in enumerate(zip(slices, embeddings, clusters)):
        predicted_speaker_id, speaker_confidence = cluster_speakers[cluster]
        segment_match = conversation_service.match_speaker_profile(embedding, known_profiles, auto_profile_ids)
        if segment_match is not None and segment_match.confidence > speaker_confidence:
            predicted_speaker_id = segment_match.speaker_id
            speaker_confidence = segment_match.confidence

        emotion = emotion_analyzer.analyze(item.audio, "", processed.sample_rate)
        emotion_payload = emotion.to_dict()
        raw_emotions = emotion_payload["raw_emotions"]
        emotion_label = max(raw_emotions, key=raw_emotions.get) if raw_emotions else (
            "positive" if emotion.emotion_value > 0 else "negative" if emotion.emotion_value < 0 else "neutral"
        )
        segment_id = str(uuid.uuid4())
        segment_path = output_dir / f"{index:03d}_{segment_id}.wav"
        sf.write(segment_path, item.audio.astype(np.float32), processed.sample_rate, subtype="PCM_16")
        started_at_ms = item.start_ms(processed.sample_rate)
        ended_at_ms = item.end_ms(processed.sample_rate)
        event = EmotionEvent(
            session_id=session_id,
            family_id=family_id,
            speaker_id=predicted_speaker_id,
            speaker_confidence=speaker_confidence,
            ts=now_utc(),
            audio_duration_ms=ended_at_ms - started_at_ms,
            audio_sample_rate=processed.sample_rate,
            transcript=emotion.transcript,
            transcript_confidence=emotion.confidence,
            anger_score=emotion.anger_score,
            emotion_level=emotion.emotion_level,
            emotion_dimensions=emotion_payload["emotion_dimensions"],
            acoustic_features=emotion.acoustic_features,
            feature_vector={"speaker_embedding": embedding.tolist()},
            audio_storage_path=str(segment_path),
        )
        db.add(event)
        db.flush()
        dimensions = emotion_payload["emotion_dimensions"]
        segment = ConversationSegment(
            id=segment_id,
            session_id=session_id,
            family_id=family_id,
            emotion_event_id=event.id,
            sequence_index=index,
            started_at_ms=started_at_ms,
            ended_at_ms=ended_at_ms,
            audio_storage_path=str(segment_path),
            audio_sample_rate=processed.sample_rate,
            transcript=emotion.transcript,
            transcript_confidence=emotion.confidence,
            emotion_value=emotion.emotion_value,
            emotion_label=emotion_label,
            anger_score=emotion.anger_score,
            emotion_level=emotion.emotion_level,
            valence=dimensions["valence"],
            arousal=dimensions["arousal"],
            dominance=dimensions["dominance"],
            stress=dimensions["stress"],
            impatience=dimensions["impatience"],
            emotion_confidence=emotion.confidence,
            model_backend=emotion.model_backend,
            raw_emotions=raw_emotions,
            acoustic_features=emotion.acoustic_features,
            speaker_embedding=embedding.tolist(),
            speaker_cluster=cluster,
            predicted_speaker_id=predicted_speaker_id,
            speaker_confidence=speaker_confidence,
            assignment_source="speaker_identity",
            source=session.device_type,
        )
        db.add(segment)
        created.append(segment)

    session.total_emotion_events += len(created)
    session.max_anger_score = max(session.max_anger_score, *(item.anger_score for item in created))
    db.flush()
    session.avg_anger_score = float(db.execute(
        select(func.avg(EmotionEvent.anger_score)).where(EmotionEvent.session_id == session_id)
    ).scalar_one() or 0.0)
    db.commit()
    return {
        "session_id": session_id,
        "recording_duration_ms": round(duration_seconds * 1000),
        "model_segment_limit_seconds": MAX_MODEL_SEGMENT_SECONDS,
        "vad_applied": True,
        "segment_count": len(created),
        "segments": [serialize_segment(item, names) for item in created],
    }


@app.get("/v1/sessions/{session_id}/segments")
def list_conversation_segments(
    session_id: str,
    db: Session = Depends(get_db),
    user_id: str = Depends(get_current_user_id),
) -> dict[str, Any]:
    family_id = get_family_by_session(db, session_id)
    ensure_family_member(db, family_id, user_id)
    segments = db.execute(
        select(ConversationSegment)
        .where(ConversationSegment.session_id == session_id)
        .order_by(ConversationSegment.sequence_index)
    ).scalars().all()
    names = family_member_names(db, family_id)
    return {"items": [serialize_segment(item, names) for item in segments]}


@app.get("/v1/conversation-segments/{segment_id}/audio")
def get_conversation_segment_audio(
    segment_id: str,
    db: Session = Depends(get_db),
    user_id: str = Depends(get_current_user_id),
) -> FileResponse:
    segment = db.get(ConversationSegment, segment_id)
    if not segment:
        raise HTTPException(status_code=404, detail="segment not found")
    ensure_family_member(db, segment.family_id, user_id)
    path = Path(segment.audio_storage_path)
    if not path.is_file():
        raise HTTPException(status_code=404, detail="segment audio not found")
    return FileResponse(path, media_type="audio/wav", filename=f"segment-{segment.sequence_index + 1}.wav")


@app.post("/v1/conversation-segments/{segment_id}/confirm-speaker")
def confirm_segment_speaker(
    segment_id: str,
    payload: SpeakerConfirmRequest,
    db: Session = Depends(get_db),
    user_id: str = Depends(get_current_user_id),
) -> dict[str, Any]:
    segment = db.get(ConversationSegment, segment_id)
    if not segment:
        raise HTTPException(status_code=404, detail="segment not found")
    ensure_family_member(db, segment.family_id, user_id)
    ensure_family_member(db, segment.family_id, payload.user_id)
    embedding = np.asarray(segment.speaker_embedding, dtype=np.float32)
    if not embedding.size:
        raise HTTPException(status_code=422, detail="segment has no speaker embedding")
    embedding /= max(float(np.linalg.norm(embedding)), 1e-8)

    profile = db.execute(
        select(VoiceProfile).where(
            VoiceProfile.family_id == segment.family_id,
            VoiceProfile.user_id == payload.user_id,
        )
    ).scalars().first()
    duration_ms = segment.ended_at_ms - segment.started_at_ms
    if profile:
        old = np.asarray(profile.voice_embedding, dtype=np.float32)
        if old.size != embedding.size:
            learned = embedding
            profile.sample_count = 0
            profile.total_duration_ms = 0
            profile.embedding_version = "campplus-v1"
        else:
            old /= max(float(np.linalg.norm(old)), 1e-8)
            count = max(profile.sample_count, 1)
            learned = (old * count + embedding) / (count + 1)
            learned /= max(float(np.linalg.norm(learned)), 1e-8)
        profile.voice_embedding = learned.tolist()
        profile.sample_count += 1
        profile.total_duration_ms += duration_ms
        profile.updated_at = now_utc()
    else:
        learned = embedding
        profile = VoiceProfile(
            id=str(uuid.uuid4()),
            user_id=payload.user_id,
            family_id=segment.family_id,
            voice_embedding=learned.tolist(),
            embedding_version="campplus-v1",
            sample_count=1,
            total_duration_ms=duration_ms,
        )
        db.add(profile)

    session_segments = db.execute(
        select(ConversationSegment).where(ConversationSegment.session_id == segment.session_id)
    ).scalars().all()
    updated_count = 0
    for candidate in session_segments:
        similarity = conversation_service.cosine_similarity(candidate.speaker_embedding, learned)
        if candidate.id == segment.id or (
            not candidate.role_confirmed and similarity >= voice_recognizer.RECOGNITION_THRESHOLD
        ):
            candidate.predicted_speaker_id = payload.user_id
            candidate.speaker_confidence = max(candidate.speaker_confidence, similarity)
            candidate.assignment_source = "voice_profile"
            if candidate.id == segment.id:
                candidate.corrected_speaker_id = payload.user_id
                candidate.role_confirmed = True
                candidate.assignment_source = "human"
            if candidate.emotion_event_id:
                event = db.get(EmotionEvent, candidate.emotion_event_id)
                if event:
                    event.speaker_id = payload.user_id
                    event.speaker_confidence = candidate.speaker_confidence
            updated_count += 1
    db.commit()
    names = family_member_names(db, segment.family_id)
    session_segments.sort(key=lambda item: item.sequence_index)
    return {
        "updated_count": updated_count,
        "voice_profile_sample_count": profile.sample_count,
        "items": [serialize_segment(item, names) for item in session_segments],
    }


@app.patch("/v1/conversation-segments/{segment_id}/speaker")
def assign_segment_speaker(
    segment_id: str,
    payload: SegmentSpeakerAssignRequest,
    db: Session = Depends(get_db),
    user_id: str = Depends(get_current_user_id),
) -> dict[str, Any]:
    segment = db.get(ConversationSegment, segment_id)
    if not segment:
        raise HTTPException(status_code=404, detail="segment not found")
    ensure_family_member(db, segment.family_id, user_id)
    ensure_family_member(db, segment.family_id, payload.user_id)

    segment.corrected_speaker_id = payload.user_id
    segment.predicted_speaker_id = payload.user_id
    segment.role_confirmed = True
    segment.assignment_source = "human"
    if segment.emotion_event_id:
        event = db.get(EmotionEvent, segment.emotion_event_id)
        if event:
            event.speaker_id = payload.user_id
            event.speaker_confidence = segment.speaker_confidence

    db.commit()

    if payload.learn_voice:
        return confirm_segment_speaker(
            segment_id,
            SpeakerConfirmRequest(user_id=payload.user_id),
            db,
            user_id,
        )

    names = family_member_names(db, segment.family_id)
    return {"segment": serialize_segment(segment, names)}


@app.patch("/v1/families/{family_id}/speakers/{speaker_id}")
def rename_speaker(
    family_id: str,
    speaker_id: str,
    payload: SpeakerRenameRequest,
    db: Session = Depends(get_db),
    user_id: str = Depends(get_current_user_id),
) -> dict[str, Any]:
    ensure_family_member(db, family_id, user_id)
    display_name = payload.display_name.strip()
    if not display_name:
        raise HTTPException(status_code=400, detail="display name cannot be empty")
    duplicate = db.execute(
        select(SpeakerIdentity).where(
            SpeakerIdentity.family_id == family_id,
            SpeakerIdentity.display_name == display_name,
            SpeakerIdentity.id != speaker_id,
        )
    ).scalars().first()
    if duplicate:
        raise HTTPException(status_code=409, detail="speaker name already exists")

    identity = db.get(SpeakerIdentity, speaker_id)
    updated_count = 0
    if identity:
        if identity.family_id != family_id:
            raise HTTPException(status_code=404, detail="speaker not found")
        identity.display_name = display_name
        identity.updated_at = now_utc()
    else:
        legacy_rows = db.execute(
            select(ConversationSegment).where(
                ConversationSegment.family_id == family_id,
                func.coalesce(
                    ConversationSegment.corrected_speaker_id,
                    ConversationSegment.predicted_speaker_id,
                    ConversationSegment.speaker_cluster,
                ) == speaker_id,
            )
        ).scalars().all()
        if not legacy_rows:
            raise HTTPException(status_code=404, detail="speaker not found")
        embeddings = [np.asarray(row.speaker_embedding, dtype=np.float32) for row in legacy_rows if row.speaker_embedding]
        centroid = np.mean(np.asarray(embeddings), axis=0) if embeddings else np.asarray([], dtype=np.float32)
        if centroid.size:
            centroid /= max(float(np.linalg.norm(centroid)), 1e-8)
        identity = SpeakerIdentity(
            id=f"spk_{uuid.uuid4().hex[:12]}",
            family_id=family_id,
            display_name=display_name,
            voice_embedding=centroid.tolist(),
            sample_count=len(legacy_rows),
            total_duration_ms=sum(row.ended_at_ms - row.started_at_ms for row in legacy_rows),
        )
        db.add(identity)
        for row in legacy_rows:
            if row.corrected_speaker_id == speaker_id:
                row.corrected_speaker_id = identity.id
            row.predicted_speaker_id = identity.id
            row.assignment_source = "speaker_identity"
            if row.emotion_event_id:
                event = db.get(EmotionEvent, row.emotion_event_id)
                if event:
                    event.speaker_id = identity.id
            updated_count += 1
    db.commit()
    return {
        "speaker_id": identity.id,
        "display_name": identity.display_name,
        "updated_count": updated_count,
    }


@app.delete("/v1/families/{family_id}/speaker-data")
def clear_speaker_data(
    family_id: str,
    scope: str = Query(default="voice", pattern="^(voice|all)$"),
    db: Session = Depends(get_db),
    user_id: str = Depends(get_current_user_id),
) -> dict[str, Any]:
    ensure_family_member(db, family_id, user_id)

    deleted_voice_profiles = db.query(VoiceProfile).filter(
        VoiceProfile.family_id == family_id,
    ).delete(synchronize_session=False)
    deleted_speaker_identities = db.query(SpeakerIdentity).filter(
        SpeakerIdentity.family_id == family_id,
    ).delete(synchronize_session=False)
    cleared_segments = 0
    cleared_events = 0

    if scope == "all":
        segments = db.execute(
            select(ConversationSegment).where(ConversationSegment.family_id == family_id)
        ).scalars().all()
        for segment in segments:
            segment.predicted_speaker_id = None
            segment.corrected_speaker_id = None
            segment.speaker_confidence = 0.0
            segment.role_confirmed = False
            segment.assignment_source = "cleared"
            cleared_segments += 1

        events = db.execute(
            select(EmotionEvent).where(EmotionEvent.family_id == family_id)
        ).scalars().all()
        for event in events:
            event.speaker_id = "unknown"
            event.speaker_confidence = 0.0
            cleared_events += 1

        feedback_events = db.execute(
            select(FeedbackEvent)
            .join(SessionModel, SessionModel.id == FeedbackEvent.session_id)
            .where(SessionModel.family_id == family_id)
        ).scalars().all()
        for feedback_event in feedback_events:
            feedback_event.speaker_id = "unknown"

    db.commit()
    return {
        "status": "cleared",
        "scope": scope,
        "deleted_voice_profiles": deleted_voice_profiles,
        "deleted_speaker_identities": deleted_speaker_identities,
        "cleared_segments": cleared_segments,
        "cleared_events": cleared_events,
    }


@app.get("/v1/families/{family_id}/speaker-stats")
def get_speaker_stats(
    family_id: str,
    days: int = Query(default=30, ge=1, le=365),
    timezone_offset_minutes: int = Query(default=480, ge=-720, le=840),
    db: Session = Depends(get_db),
    user_id: str = Depends(get_current_user_id),
) -> dict[str, Any]:
    ensure_family_member(db, family_id, user_id)
    end = now_utc()
    start = end - timedelta(days=days)
    rows = db.execute(
        select(ConversationSegment).where(
            ConversationSegment.family_id == family_id,
            ConversationSegment.created_at >= start,
        ).order_by(ConversationSegment.created_at)
    ).scalars().all()
    names = family_member_names(db, family_id)
    offset = timedelta(minutes=timezone_offset_minutes)
    speakers: dict[str, dict[str, Any]] = {}
    for row in rows:
        speaker_id = row.corrected_speaker_id or row.predicted_speaker_id or row.speaker_cluster
        speaker = speakers.setdefault(speaker_id, {
            "speaker_id": speaker_id,
            "display_name": names.get(speaker_id, speaker_id),
            "utterance_count": 0,
            "emotion_score": 0,
            "emotion_counts": {"positive": 0, "neutral": 0, "negative": 0},
            "daily": {},
        })
        day = (as_utc(row.created_at) + offset).date().isoformat()
        daily = speaker["daily"].setdefault(day, {
            "date": day,
            "utterance_count": 0,
            "emotion_score": 0,
            "emotion_counts": {"positive": 0, "neutral": 0, "negative": 0},
        })
        emotion_key = "positive" if row.emotion_value > 0 else "negative" if row.emotion_value < 0 else "neutral"
        speaker["utterance_count"] += 1
        speaker["emotion_score"] += row.emotion_value
        speaker["emotion_counts"][emotion_key] += 1
        daily["utterance_count"] += 1
        daily["emotion_score"] += row.emotion_value
        daily["emotion_counts"][emotion_key] += 1
    for speaker in speakers.values():
        speaker["daily"] = sorted(speaker["daily"].values(), key=lambda item: item["date"], reverse=True)
    return {"days": days, "speakers": sorted(speakers.values(), key=lambda item: item["utterance_count"], reverse=True)}


@app.get("/v1/families/{family_id}/speaker-records")
def get_speaker_records(
    family_id: str,
    speaker_id: str = Query(min_length=1),
    record_date: Optional[str] = Query(default=None, alias="date"),
    timezone_offset_minutes: int = Query(default=480, ge=-720, le=840),
    db: Session = Depends(get_db),
    user_id: str = Depends(get_current_user_id),
) -> dict[str, Any]:
    ensure_family_member(db, family_id, user_id)
    query = select(ConversationSegment).where(
        ConversationSegment.family_id == family_id,
        func.coalesce(
            ConversationSegment.corrected_speaker_id,
            ConversationSegment.predicted_speaker_id,
            ConversationSegment.speaker_cluster,
        ) == speaker_id,
    ).order_by(ConversationSegment.created_at.desc(), ConversationSegment.sequence_index.desc())
    rows = db.execute(query).scalars().all()
    if record_date:
        try:
            target_date = date.fromisoformat(record_date)
        except ValueError as exc:
            raise HTTPException(status_code=400, detail="date must be YYYY-MM-DD") from exc
        offset = timedelta(minutes=timezone_offset_minutes)
        rows = [row for row in rows if (as_utc(row.created_at) + offset).date() == target_date]
    names = family_member_names(db, family_id)
    return {
        "speaker_id": speaker_id,
        "display_name": names.get(speaker_id, speaker_id),
        "date": record_date,
        "items": [serialize_segment(row, names) for row in rows[:500]],
    }


@app.post("/v1/advice/generate")
async def generate_family_advice(
    payload: AdviceGenerateRequest,
    db: Session = Depends(get_db),
    user_id: str = Depends(get_current_user_id),
) -> dict[str, Any]:
    ensure_family_member(db, payload.family_id, user_id)
    try:
        report_day = date.fromisoformat(payload.report_date) if payload.report_date else (
            now_utc() + timedelta(minutes=payload.timezone_offset_minutes)
        ).date()
    except ValueError as exc:
        raise HTTPException(status_code=400, detail="report_date must be YYYY-MM-DD") from exc
    snapshot = build_advice_snapshot(db, payload.family_id, report_day, payload.timezone_offset_minutes)
    if not snapshot["today_dialogues"]:
        raise HTTPException(status_code=400, detail="today has no conversation data")
    system_prompt = (
        "你是一位严谨、温和的家庭沟通与儿童发展顾问。根据角色、对话和情绪趋势，"
        "给出帮助家庭关系变得更好的建议。必须区分事实和推测，不做医学或心理疾病诊断；"
        "必须为数据中每一个 speaker_id 分别设置小标题，给出其今天可执行的改进行动和值得肯定之处，"
        "不得把不同说话人的建议混在一起；最后总结相较上一周的家庭整体变化。使用中文 Markdown，结构清晰。"
    )
    content = await call_chat_completions(
        base_url=payload.base_url,
        model=payload.model,
        api_key=payload.api_key,
        max_tokens=1800,
        messages=[
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": "请分析以下家庭数据并给出建议：\n" + json_dumps(snapshot)},
        ],
    )
    report = AdviceReport(
        id=str(uuid.uuid4()),
        family_id=payload.family_id,
        requested_by_user_id=user_id,
        report_date=report_day.isoformat(),
        provider=payload.provider,
        model=payload.model,
        content=content,
        stats_snapshot=snapshot,
    )
    db.add(report)
    db.commit()
    return {
        "id": report.id,
        "report_date": report.report_date,
        "content": report.content,
        "stats": report.stats_snapshot,
        "model": report.model,
        "created_at": report.created_at.isoformat(),
    }


@app.post("/v1/advice/test-connection")
async def test_advice_connection(
    payload: AdviceConnectionTestRequest,
    user_id: str = Depends(get_current_user_id),
) -> dict[str, Any]:
    del user_id
    content = await call_chat_completions(
        base_url=payload.base_url,
        model=payload.model,
        api_key=payload.api_key,
        max_tokens=20,
        messages=[{"role": "user", "content": "只回复：连接成功"}],
    )
    return {"status": "ok", "message": content}


@app.get("/v1/advice/{family_id}")
def get_latest_family_advice(
    family_id: str,
    report_date: Optional[str] = None,
    db: Session = Depends(get_db),
    user_id: str = Depends(get_current_user_id),
) -> dict[str, Any]:
    ensure_family_member(db, family_id, user_id)
    query = select(AdviceReport).where(AdviceReport.family_id == family_id)
    if report_date:
        query = query.where(AdviceReport.report_date == report_date)
    report = db.execute(query.order_by(AdviceReport.created_at.desc())).scalars().first()
    if not report:
        raise HTTPException(status_code=404, detail="advice not found")
    return {
        "id": report.id,
        "report_date": report.report_date,
        "content": report.content,
        "stats": report.stats_snapshot,
        "model": report.model,
        "created_at": report.created_at.isoformat(),
    }


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
        feedback.user_response_time_ms = elapsed_ms(feedback.shown_at, feedback.acted_at)
    
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
    date: str = Query(default_factory=lambda: now_utc().date().isoformat(), description="Date in YYYY-MM-DD format"),
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

    session_stats = db.execute(
        select(
            func.count(SessionModel.id),
            func.sum(SessionModel.duration_seconds),
            func.sum(SessionModel.feedback_shown_count),
            func.sum(SessionModel.feedback_accepted_count),
        )
        .where(SessionModel.family_id == family_id)
        .where(SessionModel.started_at >= start_dt)
        .where(SessionModel.started_at <= end_dt)
    ).one()

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

    level_rows = db.execute(
        select(EmotionEvent.emotion_level, func.count(EmotionEvent.id))
        .select_from(EmotionEvent)
        .join(SessionModel, SessionModel.id == EmotionEvent.session_id)
        .where(SessionModel.family_id == family_id)
        .where(EmotionEvent.ts >= start_dt)
        .where(EmotionEvent.ts <= end_dt)
        .group_by(EmotionEvent.emotion_level)
    ).all()

    prev_start = start_dt - timedelta(days=1)
    prev_end = end_dt - timedelta(days=1)
    prev_avg = db.execute(
        select(func.avg(EmotionEvent.anger_score))
        .select_from(EmotionEvent)
        .join(SessionModel, SessionModel.id == EmotionEvent.session_id)
        .where(SessionModel.family_id == family_id)
        .where(EmotionEvent.ts >= prev_start)
        .where(EmotionEvent.ts <= prev_end)
    ).scalar_one()

    current_avg = float(stats[1] or 0.0)
    previous_avg = float(prev_avg or 0.0)
    if previous_avg == 0.0 or abs(current_avg - previous_avg) < 0.03:
        trend_direction = "stable"
    elif current_avg < previous_avg:
        trend_direction = "improving"
    else:
        trend_direction = "worsening"

    feedback_shown = int(session_stats[2] or 0)
    feedback_accepted = int(session_stats[3] or 0)

    return DailyReportResponse(
        date=date,
        session_count=0,  # TODO: 计算会话数
        total_duration_seconds=int(session_stats[1] or 0),
        emotion_event_count=stats[0] or 0,
        emotion_events_by_level={row[0]: row[1] for row in level_rows},
        avg_anger_score=round(current_avg, 4),
        max_anger_score=stats[2] or 0.0,
        feedback_shown_count=feedback_shown,
        feedback_accepted_count=feedback_accepted,
        feedback_accepted_rate=round(feedback_accepted / feedback_shown, 4) if feedback_shown else 0.0,
        improvement_score=round(max(previous_avg - current_avg, 0.0), 4),
        trend_direction=trend_direction,
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
            if msg_type is None and message.get("session_id"):
                msg_type = "analyze"
            
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
        response["feedback_token"] = feedback_token
    
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
        feedback.user_response_time_ms = elapsed_ms(feedback.shown_at, feedback.acted_at)
    
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
