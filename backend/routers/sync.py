from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session
from database import get_db
from models import User, ChatLog, ActionLog
from routers.auth import get_current_user
from schemas.sync import SyncPushRequest, SyncPushResponse

router = APIRouter(prefix="/api/v1/sync", tags=["sync"])

@router.post("/push", response_model=SyncPushResponse)
def push_sync_logs(
    payload: SyncPushRequest,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user)
):
    """
    Append-only sync logic: 
    Accepts arrays of chat logs and action logs from the device and appends them to the database.
    """
    chat_count = 0
    action_count = 0

    # Process Chat Logs
    for clog in payload.chat_logs:
        # Simple deduplication by local_id to avoid double insertion on retry
        existing = db.query(ChatLog).filter(
            ChatLog.user_id == current_user.id,
            ChatLog.local_id == clog.local_id
        ).first()
        
        if not existing:
            new_clog = ChatLog(
                user_id=current_user.id,
                local_id=clog.local_id,
                role=clog.role,
                content=clog.content,
                timestamp=clog.timestamp
            )
            db.add(new_clog)
            chat_count += 1

    # Process Action Logs
    for alog in payload.action_logs:
        existing = db.query(ActionLog).filter(
            ActionLog.user_id == current_user.id,
            ActionLog.local_id == alog.local_id
        ).first()
        
        if not existing:
            new_alog = ActionLog(
                user_id=current_user.id,
                local_id=alog.local_id,
                action_type=alog.action_type,
                action_detail=alog.action_detail,
                timestamp=alog.timestamp
            )
            db.add(new_alog)
            action_count += 1

    db.commit()

    return SyncPushResponse(
        success=True,
        synced_chat_count=chat_count,
        synced_action_count=action_count
    )
