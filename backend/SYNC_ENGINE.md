# Sync Engine — FYONA ERP

> **Version:** 1.0
> **Protocol:** REST API + JSON
> **Strategy:** Optimistic Concurrency with Version Vectors

---

## Architecture

```
┌─────────────────────────────────────────────┐
│              Client (Flutter)                │
│  ┌──────────┐  ┌──────────┐  ┌───────────┐ │
│  │  SQLite   │  │  Pending │  │  Sync     │ │
│  │  (Cache)  │  │  Queue   │  │  Manager  │ │
│  └──────────┘  └──────────┘  └───────────┘ │
│                    │  Push / Pull            │
└────────────────────┼────────────────────────┘
                     │
┌────────────────────┼────────────────────────┐
│           Backend (FastAPI)                  │
│  ┌────────────────┴──────────────────────┐  │
│  │          Sync API                      │  │
│  │  /sync/push  /sync/pull  /sync/status  │  │
│  └────────────────┬──────────────────────┘  │
│  ┌────────────────┴──────────────────────┐  │
│  │          Sync Service                  │  │
│  │  Push Handler  │  Pull Handler        │  │
│  │  Conflict Res. │  Version Tracker     │  │
│  └────────────────┬──────────────────────┘  │
│  ┌────────────────┴──────────────────────┐  │
│  │     EntityVersions / SyncLogs DB      │  │
│  │     PostgreSQL                         │  │
│  └─────────────────────────────────────────┘  │
└─────────────────────────────────────────────┘
```

## Sync Flow

### Push (Client → Server)
```
1. Client collects all changes since last sync
2. Groups by entity type + computes checksums
3. POST /sync/push with batch
4. Server validates versions:
   - New entity → create version entry
   - Newer version → accept update
   - Same version → skip (no-op)
   - Older version → conflict → log + return to client
5. Client receives SyncResult with pushed count + conflicts
```

### Pull (Server → Client)
```
1. Client sends last_sync timestamp + optional entity types
2. Server returns all versions modified since that time
3. Client compares with local state
4. Client downloads full data for changed entities via CRUD API
```

### Conflict Resolution Strategies
| Strategy | Behavior |
|----------|----------|
| `lww` | Last write wins (higher version wins) |
| `server_wins` | Server version always accepted |
| `client_wins` | Client version always accepted |
| `manual` | Logged for manual resolution via admin |

## API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| POST | /sync/push | Push changes to server |
| POST | /sync/pull | Pull changes from server |
| GET | /sync/status | Sync status & health |
| GET | /sync/health | Sync engine health |
| GET | /sync/conflicts | List conflicts |
| GET | /sync/logs | View sync logs |

## Sync Contract

- Batches: max 500 entities per batch
- Interval: minimum 5 seconds between syncs
- Version: increments on each successful push
- Checksum: SHA-256 (first 16 chars)
- Encoding: UTF-8 JSON
- Auth: JWT Bearer token required
