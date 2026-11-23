from pydantic import BaseModel
from typing import Optional, List
from datetime import datetime
from uuid import UUID


class SyncEntity(BaseModel):
    entity_type: str
    entity_id: UUID
    data: dict
    version: int = 1
    checksum: Optional[str] = None
    deleted: bool = False
    # Client-generated globally-unique idempotency key. If the SAME
    # operation_id arrives again (network retry after server applied it), the
    # server treats it as a no-op instead of applying the write twice.
    operation_id: Optional[str] = None
    # Wall-clock time the op was created on the device (ISO-8601). Used only
    # to order a stale personal UPDATE against the server row: newer intent
    # wins, older intent is reported back as superseded so the client drops it
    # instead of retrying forever. Absent = apply (legacy clients).
    client_updated_at: Optional[str] = None


class SyncPushRequest(BaseModel):
    batch_id: str
    entities: List[SyncEntity]
    force: bool = False


class SyncPullRequest(BaseModel):
    last_sync_at: Optional[datetime] = None
    entity_types: Optional[List[str]] = None
    full_sync: bool = False


class SyncConflict(BaseModel):
    entity_type: str
    entity_id: UUID
    client_version: int
    server_version: int
    client_data: Optional[dict] = None
    server_data: Optional[dict] = None
    resolution: str = "pending"


class SyncResult(BaseModel):
    batch_id: str
    success: bool
    pushed: int = 0
    pulled: int = 0
    conflicts: List[SyncConflict] = []
    errors: List[str] = []


class SyncStatusResponse(BaseModel):
    is_syncing: bool = False
    last_sync_at: Optional[datetime] = None
    last_sync_duration: Optional[float] = None
    pending_pushes: int = 0
    pending_pulls: int = 0
    total_conflicts: int = 0
    unresolved_conflicts: int = 0
    sync_enabled: bool = True


class SyncHealthResponse(BaseModel):
    server_time: datetime
    db_connected: bool = True
    sync_api_version: str = "1.0"
    supported_strategies: List[str] = ["lww", "server_wins", "client_wins", "manual"]
    max_batch_size: int = 500
    min_sync_interval_seconds: int = 5
