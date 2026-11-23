from typing import List, Optional
from pydantic import BaseModel, Field


class SuggestionResponse(BaseModel):
    id: str
    user_id: str
    organization_id: Optional[str] = None
    title: str
    body: str
    images: List[str] = Field(default_factory=list)
    videos: List[str] = Field(default_factory=list)
    audios: List[str] = Field(default_factory=list)
    status: str
    admin_note: Optional[str] = None
    created_at: Optional[str] = None
    updated_at: Optional[str] = None

    @classmethod
    def from_entity(cls, s) -> "SuggestionResponse":
        return cls(
            id=str(s.id),
            user_id=str(s.user_id),
            organization_id=str(s.organization_id) if s.organization_id else None,
            title=s.title or "",
            body=s.body or "",
            images=list(s.images or []),
            videos=list(getattr(s, "videos", None) or []),
            audios=list(getattr(s, "audios", None) or []),
            status=s.status,
            admin_note=s.admin_note,
            created_at=s.created_at.isoformat() if s.created_at else None,
            updated_at=s.updated_at.isoformat() if s.updated_at else None,
        )


class SuggestionAdminResponse(SuggestionResponse):
    """Admin view: includes user display fields joined by the service."""

    user_name: str = ""
    user_email: str = ""
    organization_name: Optional[str] = None


class SuggestionUpdate(BaseModel):
    status: str = Field(
        ...,
        pattern="^(pending|proposed|in_progress|completed|rejected)$",
    )
    admin_note: Optional[str] = None


class SuggestionReplyCreate(BaseModel):
    body: str = Field(..., min_length=1)
    # Optional explicit ticket. Conversation endpoints fall back to the
    # user's latest suggestion when omitted (legacy behavior).
    suggestion_id: Optional[str] = None


class SuggestionMessageEdit(BaseModel):
    body: str = Field(..., min_length=1, max_length=5000)


class SuggestionConversationItem(BaseModel):
    """One conversation (all suggestions + replies from a single user)."""

    user_id: str
    user_name: str = ""
    user_email: str = ""
    organization_name: Optional[str] = None
    last_message: str = ""
    last_is_from_admin: bool = False
    last_message_at: Optional[str] = None
    unread_count: int = 0
    has_reply: bool = False
    suggestions_count: int = 0
    last_status: str = "pending"


class SuggestionConversationMessage(BaseModel):
    """A single message inside a conversation — either the user's own
    suggestion or an admin reply, merged into one chronological stream."""

    id: str
    kind: str  # "suggestion" | "reply"
    user_id: str
    suggestion_id: str
    title: str = ""
    body: str = ""
    images: List[str] = Field(default_factory=list)
    videos: List[str] = Field(default_factory=list)
    audios: List[str] = Field(default_factory=list)
    status: str = "pending"
    admin_note: Optional[str] = None
    is_from_admin: bool = False
    created_at: Optional[str] = None
    updated_at: Optional[str] = None
    is_edited: bool = False


class SuggestionReplyResponse(BaseModel):
    id: str
    suggestion_id: str
    user_id: str
    admin_id: Optional[str] = None
    body: str
    is_from_admin: bool = True
    images: List[str] = Field(default_factory=list)
    videos: List[str] = Field(default_factory=list)
    audios: List[str] = Field(default_factory=list)
    created_at: Optional[str] = None
    updated_at: Optional[str] = None
    is_edited: bool = False

    @classmethod
    def from_entity(cls, r) -> "SuggestionReplyResponse":
        return cls(
            id=str(r.id),
            suggestion_id=str(r.suggestion_id),
            user_id=str(r.user_id),
            admin_id=str(r.admin_id) if r.admin_id else None,
            body=r.body or "",
            is_from_admin=bool(r.admin_id),
            images=list(r.images or []),
            videos=list(getattr(r, "videos", None) or []),
            audios=list(getattr(r, "audios", None) or []),
            created_at=r.created_at.isoformat() if r.created_at else None,
            updated_at=(getattr(r, "updated_at", None) or r.created_at).isoformat()
            if (getattr(r, "updated_at", None) or r.created_at) else None,
            is_edited=bool(getattr(r, "is_edited", False)),
        )
