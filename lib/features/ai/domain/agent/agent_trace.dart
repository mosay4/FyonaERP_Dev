import 'dart:convert';
import 'package:flutter/foundation.dart';

/// Execution trace for debugging and monitoring Sara Agent.
/// Each user interaction produces a trace entry.
class AgentTraceEntry {
  final String id;
  final DateTime timestamp;
  final String userInput;
  final String? detectedIntent;
  final String? detectedTool;
  final Map<String, dynamic>? extractedParams;
  final List<String>? missingParams;
  final bool? validationPassed;
  final String? validationResult;
  final Map<String, dynamic>? toolArgs;
  final bool? executionSuccess;
  final String? executionResult;
  final String? verificationStatus;
  final String? finalResponse;
  final int? durationMs;
  final String? error;

  AgentTraceEntry({
    required this.id,
    required this.timestamp,
    required this.userInput,
    this.detectedIntent,
    this.detectedTool,
    this.extractedParams,
    this.missingParams,
    this.validationPassed,
    this.validationResult,
    this.toolArgs,
    this.executionSuccess,
    this.executionResult,
    this.verificationStatus,
    this.finalResponse,
    this.durationMs,
    this.error,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'timestamp': timestamp.toIso8601String(),
    'user_input': userInput,
    if (detectedIntent != null) 'detected_intent': detectedIntent,
    if (detectedTool != null) 'detected_tool': detectedTool,
    if (extractedParams != null) 'extracted_params': extractedParams,
    if (missingParams != null) 'missing_params': missingParams,
    if (validationPassed != null) 'validation_passed': validationPassed,
    if (validationResult != null) 'validation_result': validationResult,
    if (toolArgs != null) 'tool_args': toolArgs,
    if (executionSuccess != null) 'execution_success': executionSuccess,
    if (executionResult != null) 'execution_result': executionResult,
    if (verificationStatus != null) 'verification_status': verificationStatus,
    if (finalResponse != null) 'final_response': finalResponse,
    if (durationMs != null) 'duration_ms': durationMs,
    if (error != null) 'error': error,
  };

  @override
  String toString() => jsonEncode(toJson());
}

/// Mutable builder for building a trace entry step by step.
class AgentTraceBuilder {
  String? id;
  DateTime? timestamp;
  String? userInput;
  String? detectedIntent;
  String? detectedTool;
  Map<String, dynamic>? extractedParams;
  List<String>? missingParams;
  bool? validationPassed;
  String? validationResult;
  Map<String, dynamic>? toolArgs;
  bool? executionSuccess;
  String? executionResult;
  String? verificationStatus;
  String? finalResponse;
  int? durationMs;
  String? error;

  AgentTraceBuilder start(String input) {
    id = DateTime.now().microsecondsSinceEpoch.toString();
    timestamp = DateTime.now();
    userInput = input;
    return this;
  }

  AgentTraceBuilder setIntent(String intent) { detectedIntent = intent; return this; }
  AgentTraceBuilder setTool(String tool) { detectedTool = tool; return this; }
  AgentTraceBuilder setExtractedParams(Map<String, dynamic> params) { extractedParams = params; return this; }
  AgentTraceBuilder setMissingParams(List<String> params) { missingParams = params; return this; }
  AgentTraceBuilder setValidation(bool passed, String result) { validationPassed = passed; validationResult = result; return this; }
  AgentTraceBuilder setToolArgs(Map<String, dynamic> args) { toolArgs = args; return this; }
  AgentTraceBuilder setExecution(bool success, String result) { executionSuccess = success; executionResult = result; return this; }
  AgentTraceBuilder setVerification(String status) { verificationStatus = status; return this; }
  AgentTraceBuilder setResponse(String response) { finalResponse = response; return this; }
  AgentTraceBuilder setError(String err) { error = err; return this; }

  AgentTraceEntry build({int? elapsed}) {
    durationMs = elapsed;
    return AgentTraceEntry(
      id: id ?? DateTime.now().microsecondsSinceEpoch.toString(),
      timestamp: timestamp ?? DateTime.now(),
      userInput: userInput ?? '',
      detectedIntent: detectedIntent,
      detectedTool: detectedTool,
      extractedParams: extractedParams,
      missingParams: missingParams,
      validationPassed: validationPassed,
      validationResult: validationResult,
      toolArgs: toolArgs,
      executionSuccess: executionSuccess,
      executionResult: executionResult,
      verificationStatus: verificationStatus,
      finalResponse: finalResponse,
      durationMs: durationMs,
      error: error,
    );
  }
}

/// In-memory trace store (last 50 entries per session).
class AgentTraceStore {
  static final AgentTraceStore instance = AgentTraceStore._();
  AgentTraceStore._();

  final List<AgentTraceEntry> _entries = [];
  static const int _maxEntries = 50;

  void record(AgentTraceEntry entry) {
    _entries.add(entry);
    if (_entries.length > _maxEntries) {
      _entries.removeAt(0);
    }
    if (kDebugMode) {
      debugPrint('[SaraTrace] ${entry.userInput} → tool=${entry.detectedTool} '
          'success=${entry.executionSuccess} verify=${entry.verificationStatus} '
          '${entry.durationMs}ms');
    }
  }

  List<AgentTraceEntry> get entries => List.unmodifiable(_entries);

  AgentTraceEntry? get lastEntry => _entries.isNotEmpty ? _entries.last : null;

  void clear() => _entries.clear();
}
