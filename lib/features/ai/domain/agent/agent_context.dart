/// Manages Sara Agent's context throughout a conversation session.
///
/// Tracks:
/// - Current pending tool (if collecting params)
/// - Collected parameters so far
/// - Last operation performed
/// - Current screen
/// - User preferences
/// - Conversation state
enum AgentState {
  idle,
  collectingParams,
  awaitingConfirmation,
  executing,
  verifying,
}

class AgentContext {
  AgentState _state = AgentState.idle;
  String? _pendingToolName;
  Map<String, dynamic> _collectedParams = {};
  String? _lastToolName;
  Map<String, dynamic>? _lastToolResult;
  String? _lastEntityId;
  String? _lastEntityType;
  String _currentScreen = '';
  String _lastOperation = '';
  String _language = 'ar';
  final List<String> _recentToolCalls = [];

  AgentState get state => _state;
  String? get pendingToolName => _pendingToolName;
  Map<String, dynamic> get collectedParams => Map.unmodifiable(_collectedParams);
  String? get lastToolName => _lastToolName;
  Map<String, dynamic>? get lastToolResult => _lastToolResult;
  String? get lastEntityId => _lastEntityId;
  String? get lastEntityType => _lastEntityType;
  String get currentScreen => _currentScreen;
  String get lastOperation => _lastOperation;
  String get language => _language;
  List<String> get recentToolCalls => List.unmodifiable(_recentToolCalls);

  // ── State transitions ──

  void startCollecting(String toolName) {
    _state = AgentState.collectingParams;
    _pendingToolName = toolName;
    _collectedParams = {};
  }

  void updateCollectedParams(Map<String, dynamic> params) {
    _collectedParams = Map.from(_collectedParams)..addAll(params);
  }

  void startConfirmation() {
    _state = AgentState.awaitingConfirmation;
  }

  void startExecution() {
    _state = AgentState.executing;
  }

  void startVerification() {
    _state = AgentState.verifying;
  }

  void completeOperation(String toolName, Map<String, dynamic> result, {String? entityId, String? entityType}) {
    _state = AgentState.idle;
    _lastToolName = toolName;
    _lastToolResult = result;
    _lastEntityId = entityId;
    _lastEntityType = entityType;
    _pendingToolName = null;
    _collectedParams = {};
    _lastOperation = toolName;
    _recentToolCalls.add(toolName);
    if (_recentToolCalls.length > 10) {
      _recentToolCalls.removeAt(0);
    }
  }

  void cancel() {
    _state = AgentState.idle;
    _pendingToolName = null;
    _collectedParams = {};
  }

  void setCurrentScreen(String screen) {
    _currentScreen = screen;
  }

  void setLanguage(String lang) {
    _language = lang;
  }

  /// Check if a tool was recently called (idempotency check).
  bool wasRecentlyCalled(String toolName, {Duration within = const Duration(minutes: 5)}) {
    return _recentToolCalls.contains(toolName);
  }

  /// Reset for new conversation.
  void reset() {
    _state = AgentState.idle;
    _pendingToolName = null;
    _collectedParams = {};
    _lastToolName = null;
    _lastToolResult = null;
    _lastEntityId = null;
    _lastEntityType = null;
    _lastOperation = '';
    _recentToolCalls.clear();
  }
}
