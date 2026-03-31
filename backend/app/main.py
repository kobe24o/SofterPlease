from __future__ import annotations

import asyncio
import uuid
from datetime import datetime, timezone

from fastapi import Depends, FastAPI, Header, HTTPException, Query, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field
from sqlalchemy import case, func, select
from sqlalchemy.orm import Session

from .db import Base, SessionLocal, engine
from .models import EmotionEvent, Family, FamilyMember, FeedbackEvent, Session as SessionModel, User

app = FastAPI(title="SofterPlease Phase-2 API", version="0.7.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


class UserCreateRequest(BaseModel):
    nickname: str = Field(min_length=1)


class UserCreateResponse(BaseModel):
    user_id: str


class FamilyCreateRequest(BaseModel):
    name: str = Field(min_length=1)


class FamilyCreateResponse(BaseModel):
    family_id: str


class FamilyMemberAddRequest(BaseModel):
    user_id: str = Field(min_length=1)
    role: str = Field(default="member")


class SessionStartRequest(BaseModel):
    family_id: str = Field(min_length=1)
    device_id: str = Field(min_length=1)


class SessionStartResponse(BaseModel):
    session_id: str
    started_at: datetime


class SessionEndRequest(BaseModel):
    session_id: str = Field(min_length=1)


class DailyReport(BaseModel):
    session_id: str
    samples: int
    avg_anger_score: float
    max_anger_score: float
    high_alert_count: int


class SpeakerReport(BaseModel):
    session_id: str
    speaker_id: str
    samples: int
    avg_anger_score: float
    high_alert_count: int


class FamilyDailyReport(BaseModel):
    family_id: str
    samples: int
    avg_anger_score: float
    high_alert_count: int


class FamilyRangeReport(BaseModel):
    family_id: str
    start: str
    end: str
    sessions: int
    samples: int
    avg_anger_score: float
    high_alert_count: int


class TimePoint(BaseModel):
    bucket: str
    avg_anger_score: float
    high_alert_count: int


class TimeSeriesReport(BaseModel):
    session_id: str
    points: list[TimePoint]


class EffectivenessReport(BaseModel):
    session_id: str
    shown_count: int
    accepted_count: int
    accepted_rate: float


class FeedbackActionRequest(BaseModel):
    feedback_token: str = Field(min_length=1)
    action: str = Field(pattern="^(accepted|ignored)$")


class EventListItem(BaseModel):
    ts: datetime
    speaker_id: str
    anger_score: float
    transcript: str


class EventListResponse(BaseModel):
    total: int
    limit: int
    offset: int
    items: list[EventListItem]


Base.metadata.create_all(bind=engine)


def get_db() -> Session:
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


def now_utc() -> datetime:
    return datetime.now(timezone.utc)


def get_current_user_id(x_user_id: str | None = Header(default=None), db: Session = Depends(get_db)) -> str:
    if not x_user_id:
        raise HTTPException(status_code=401, detail="x-user-id header required")
    user = db.get(User, x_user_id)
    if not user:
        raise HTTPException(status_code=401, detail="invalid user")
    return x_user_id


def parse_iso_datetime(raw: str) -> datetime:
    try:
        return datetime.fromisoformat(raw)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail="invalid datetime format, use ISO-8601") from exc


def compute_summary(query_result: tuple[object, object, object]) -> tuple[int, float, int]:
    samples = int(query_result[0] or 0)
    avg = float(query_result[1] or 0.0)
    high_alerts = int(query_result[2] or 0)
    return samples, round(avg, 4), high_alerts


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


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/v1/users", response_model=UserCreateResponse)
def create_user(payload: UserCreateRequest, db: Session = Depends(get_db)) -> UserCreateResponse:
    user_id = str(uuid.uuid4())
    db.add(User(id=user_id, nickname=payload.nickname, created_at=now_utc()))
    db.commit()
    return UserCreateResponse(user_id=user_id)


@app.post("/v1/families", response_model=FamilyCreateResponse)
def create_family(
    payload: FamilyCreateRequest,
    db: Session = Depends(get_db),
    user_id: str = Depends(get_current_user_id),
) -> FamilyCreateResponse:
    family_id = str(uuid.uuid4())
    db.add(Family(id=family_id, name=payload.name, owner_user_id=user_id, created_at=now_utc()))
    db.add(FamilyMember(family_id=family_id, user_id=user_id, role="owner"))
    db.commit()
    return FamilyCreateResponse(family_id=family_id)


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

    db.add(FamilyMember(family_id=family_id, user_id=payload.user_id, role=payload.role))
    db.commit()
    return {"status": "added"}


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
        started_at=now_utc(),
    )
    db.add(session)
    db.commit()
    return SessionStartResponse(session_id=session_id, started_at=session.started_at)


@app.post("/v1/sessions/end")
def end_session(
    payload: SessionEndRequest,
    db: Session = Depends(get_db),
    user_id: str = Depends(get_current_user_id),
) -> dict[str, str]:
    family_id = get_family_by_session(db, payload.session_id)
    ensure_family_member(db, family_id, user_id)
    session = db.get(SessionModel, payload.session_id)
    session.ended_at = now_utc()
    db.commit()
    return {"status": "ended"}


@app.post("/v1/feedback/actions")
def post_feedback_action(
    payload: FeedbackActionRequest,
    db: Session = Depends(get_db),
    user_id: str = Depends(get_current_user_id),
) -> dict[str, str]:
    feedback = db.execute(select(FeedbackEvent).where(FeedbackEvent.token == payload.feedback_token)).scalar_one_or_none()
    if not feedback:
        raise HTTPException(status_code=404, detail="feedback token not found")

    family_id = get_family_by_session(db, feedback.session_id)
    ensure_family_member(db, family_id, user_id)

    feedback.action = payload.action
    feedback.acted_at = now_utc()
    db.commit()
    return {"status": "updated"}


@app.get("/v1/sessions/{session_id}/events", response_model=EventListResponse)
def list_events(
    session_id: str,
    limit: int = Query(default=50, ge=1, le=200),
    offset: int = Query(default=0, ge=0),
    db: Session = Depends(get_db),
    user_id: str = Depends(get_current_user_id),
) -> EventListResponse:
    family_id = get_family_by_session(db, session_id)
    ensure_family_member(db, family_id, user_id)

    total = db.execute(select(func.count(EmotionEvent.id)).where(EmotionEvent.session_id == session_id)).scalar_one()
    rows = db.execute(
        select(EmotionEvent)
        .where(EmotionEvent.session_id == session_id)
        .order_by(EmotionEvent.ts.desc())
        .offset(offset)
        .limit(limit)
    ).scalars()
    return EventListResponse(
        total=int(total),
        limit=limit,
        offset=offset,
        items=[
            EventListItem(ts=row.ts, speaker_id=row.speaker_id, anger_score=row.anger_score, transcript=row.transcript)
            for row in rows
        ],
    )


@app.get("/v1/reports/daily/{session_id}", response_model=DailyReport)
def get_daily_report(session_id: str, db: Session = Depends(get_db), user_id: str = Depends(get_current_user_id)) -> DailyReport:
    family_id = get_family_by_session(db, session_id)
    ensure_family_member(db, family_id, user_id)

    summary = db.execute(
        select(
            func.count(EmotionEvent.id),
            func.avg(EmotionEvent.anger_score),
            func.sum(case((EmotionEvent.anger_score >= 0.75, 1), else_=0)),
            func.max(EmotionEvent.anger_score),
        ).where(EmotionEvent.session_id == session_id)
    ).one()
    samples, avg, high_alerts = compute_summary((summary[0], summary[1], summary[2]))
    return DailyReport(
        session_id=session_id,
        samples=samples,
        avg_anger_score=avg,
        max_anger_score=float(summary[3] or 0.0),
        high_alert_count=high_alerts,
    )


@app.get("/v1/reports/speaker/{session_id}/{speaker_id}", response_model=SpeakerReport)
def get_speaker_report(
    session_id: str,
    speaker_id: str,
    db: Session = Depends(get_db),
    user_id: str = Depends(get_current_user_id),
) -> SpeakerReport:
    family_id = get_family_by_session(db, session_id)
    ensure_family_member(db, family_id, user_id)

    summary = db.execute(
        select(
            func.count(EmotionEvent.id),
            func.avg(EmotionEvent.anger_score),
            func.sum(case((EmotionEvent.anger_score >= 0.75, 1), else_=0)),
        )
        .where(EmotionEvent.session_id == session_id)
        .where(EmotionEvent.speaker_id == speaker_id)
    ).one()

    samples, avg, high_alerts = compute_summary(summary)
    return SpeakerReport(session_id=session_id, speaker_id=speaker_id, samples=samples, avg_anger_score=avg, high_alert_count=high_alerts)


@app.get("/v1/reports/family/{family_id}/daily", response_model=FamilyDailyReport)
def get_family_daily_report(
    family_id: str,
    db: Session = Depends(get_db),
    user_id: str = Depends(get_current_user_id),
) -> FamilyDailyReport:
    ensure_family_member(db, family_id, user_id)
    summary = db.execute(
        select(
            func.count(EmotionEvent.id),
            func.avg(EmotionEvent.anger_score),
            func.sum(case((EmotionEvent.anger_score >= 0.75, 1), else_=0)),
        )
        .select_from(EmotionEvent)
        .join(SessionModel, SessionModel.id == EmotionEvent.session_id)
        .where(SessionModel.family_id == family_id)
    ).one()
    samples, avg, high_alerts = compute_summary(summary)
    return FamilyDailyReport(family_id=family_id, samples=samples, avg_anger_score=avg, high_alert_count=high_alerts)


@app.get("/v1/reports/family/{family_id}/range", response_model=FamilyRangeReport)
def get_family_range_report(
    family_id: str,
    start: str,
    end: str,
    db: Session = Depends(get_db),
    user_id: str = Depends(get_current_user_id),
) -> FamilyRangeReport:
    ensure_family_member(db, family_id, user_id)
    start_dt = parse_iso_datetime(start)
    end_dt = parse_iso_datetime(end)
    if end_dt < start_dt:
        raise HTTPException(status_code=400, detail="end must be >= start")

    session_count = db.execute(
        select(func.count(SessionModel.id)).where(
            SessionModel.family_id == family_id,
            SessionModel.started_at >= start_dt,
            SessionModel.started_at <= end_dt,
        )
    ).scalar_one()

    summary = db.execute(
        select(
            func.count(EmotionEvent.id),
            func.avg(EmotionEvent.anger_score),
            func.sum(case((EmotionEvent.anger_score >= 0.75, 1), else_=0)),
        )
        .select_from(EmotionEvent)
        .join(SessionModel, SessionModel.id == EmotionEvent.session_id)
        .where(SessionModel.family_id == family_id)
        .where(SessionModel.started_at >= start_dt)
        .where(SessionModel.started_at <= end_dt)
    ).one()
    samples, avg, high_alerts = compute_summary(summary)
    return FamilyRangeReport(
        family_id=family_id,
        start=start,
        end=end,
        sessions=int(session_count or 0),
        samples=samples,
        avg_anger_score=avg,
        high_alert_count=high_alerts,
    )


@app.get("/v1/reports/timeseries/{session_id}", response_model=TimeSeriesReport)
def get_timeseries_report(session_id: str, db: Session = Depends(get_db), user_id: str = Depends(get_current_user_id)) -> TimeSeriesReport:
    family_id = get_family_by_session(db, session_id)
    ensure_family_member(db, family_id, user_id)

    rows = db.execute(
        select(
            func.strftime("%Y-%m-%d %H:%M", EmotionEvent.ts).label("bucket"),
            func.avg(EmotionEvent.anger_score).label("avg_anger_score"),
            func.sum(case((EmotionEvent.anger_score >= 0.75, 1), else_=0)).label("high_alert_count"),
        )
        .where(EmotionEvent.session_id == session_id)
        .group_by("bucket")
        .order_by("bucket")
    ).all()
    return TimeSeriesReport(
        session_id=session_id,
        points=[
            TimePoint(bucket=row.bucket, avg_anger_score=round(float(row.avg_anger_score or 0.0), 4), high_alert_count=int(row.high_alert_count or 0))
            for row in rows
        ],
    )


@app.get("/v1/reports/effectiveness/{session_id}", response_model=EffectivenessReport)
def get_effectiveness_report(session_id: str, db: Session = Depends(get_db), user_id: str = Depends(get_current_user_id)) -> EffectivenessReport:
    family_id = get_family_by_session(db, session_id)
    ensure_family_member(db, family_id, user_id)

    summary = db.execute(
        select(
            func.count(FeedbackEvent.id),
            func.sum(case((FeedbackEvent.action == "accepted", 1), else_=0)),
        ).where(FeedbackEvent.session_id == session_id)
    ).one()

    shown_count = int(summary[0] or 0)
    accepted_count = int(summary[1] or 0)
    accepted_rate = round((accepted_count / shown_count), 4) if shown_count > 0 else 0.0
    return EffectivenessReport(session_id=session_id, shown_count=shown_count, accepted_count=accepted_count, accepted_rate=accepted_rate)


@app.websocket("/v1/realtime/ws")
async def realtime_ws(websocket: WebSocket) -> None:
    await websocket.accept()
    try:
        while True:
            payload = await websocket.receive_json()
            session_id = payload.get("session_id")
            speaker_id = payload.get("speaker_id", "unknown")
            anger_score = max(0.0, min(1.0, float(payload.get("anger_score", 0.0))))
            transcript = payload.get("transcript", "")

            if not session_id:
                await websocket.send_json({"type": "error", "detail": "session_id is required"})
                continue

            db = SessionLocal()
            session = db.get(SessionModel, session_id)
            if not session:
                await websocket.send_json({"type": "error", "detail": "session not found"})
                db.close()
                continue

            feedback_level = "calm"
            message = "很好，继续保持平稳语气。"
            if anger_score >= 0.75:
                feedback_level = "high"
                message = "你可以慢一点说，先呼吸两次。"
            elif anger_score >= 0.55:
                feedback_level = "medium"
                message = "语气有点急，试着放慢语速。"

            feedback_token = str(uuid.uuid4())
            db.add(EmotionEvent(session_id=session_id, ts=now_utc(), speaker_id=speaker_id, anger_score=anger_score, transcript=transcript))
            db.add(
                FeedbackEvent(
                    token=feedback_token,
                    session_id=session_id,
                    speaker_id=speaker_id,
                    feedback_level=feedback_level,
                    message=message,
                    action="shown",
                    shown_at=now_utc(),
                )
            )
            db.commit()
            db.close()

            await websocket.send_json(
                {
                    "type": "feedback",
                    "ts": now_utc().isoformat(),
                    "session_id": session_id,
                    "speaker_id": speaker_id,
                    "anger_score": anger_score,
                    "feedback_level": feedback_level,
                    "message": message,
                    "feedback_token": feedback_token,
                }
            )
            await asyncio.sleep(0.01)
    except WebSocketDisconnect:
        return
