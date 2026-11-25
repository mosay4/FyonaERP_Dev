from pydantic import BaseModel
from typing import Optional, List
from datetime import datetime


class AgentContext(BaseModel):
    user_id: str
    user_name: str
    account_type: str = "personal"  # personal | business
    company_name: Optional[str] = None
    current_screen: str = ""
    language: str = "Arabic"
    timezone: str = "UTC"
    permissions: List[str] = []

    # ── App Awareness (live application state) ──
    subscription_plan: Optional[str] = None
    subscription_status: Optional[str] = None
    subscription_context: dict = {}  # Server-owned entitlements/catalog, never request authority.
    network_status: str = "online"
    current_tab: str = ""
    open_modals: List[str] = []
    pending_operations: List[str] = []
    last_screen: str = ""
    last_operation: str = ""
    # Live screen catalog streamed by the installed app (route/title/summary)
    screen_catalog: List[dict] = []

    # ── Agent Memory hints (short-term, supplied by the service) ──
    memory: dict = {}
    current_task: Optional[str] = None


class AgentAction(BaseModel):
    action: str
    params: dict = {}
    label: Optional[str] = None


class AgentResponse(BaseModel):
    text: str
    actions: List[AgentAction] = []
    suggestions: List[str] = []
    confidence: float = 0.9
    needs_clarification: bool = False
    pending_tools: List[dict] = []  # Tools to execute on Flutter side
    # Personal device mode: reads the phone answers before Sara continues
    # (POST /ai/continue with the signed [state]).
    device_calls: List[dict] = []
    state: Optional[dict] = None


class IntentClassification(BaseModel):
    category: str  # balance, sales, customers, inventory, help, navigation, create, analysis, search, general
    subcategory: Optional[str] = None
    period: Optional[str] = None  # today, week, month, year, custom
    entities: List[str] = []  # extracted entities from query
    needs_data: bool = True
