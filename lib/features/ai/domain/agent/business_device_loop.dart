import '../services/ai_service.dart' show AiAgentResponse;
import 'sara_device_loop.dart';

export 'sara_device_loop.dart' show SaraDeviceLoop, SaraDeviceCall, SaraDeviceResume;

/// Answers one device call ({id, method, path, params}) from this phone.
typedef BusinessDeviceCall = SaraDeviceCall;

/// Sends the phone's answers back to the server (/business-sara/continue).
typedef BusinessDeviceResume = SaraDeviceResume;

/// The Business Sara read loop on a device-ledger branch (and «جميع الفروع»):
/// the shared [SaraDeviceLoop] with Business's own messages (they name
/// branches). Behaviour, limits and texts are unchanged.
abstract final class BusinessDeviceLoop {
  static const maxRounds = SaraDeviceLoop.maxRounds;
  static const callTimeout = SaraDeviceLoop.callTimeout;
  static const budget = SaraDeviceLoop.budget;

  /// The server refuses a tool result above 40,000 characters.
  static const resultLimit = SaraDeviceLoop.resultLimit;

  /// Runs the loop. Returns null when [alive] turns false (page closed or
  /// branch changed): the caller then shows nothing.
  static Future<AiAgentResponse?> run(
    AiAgentResponse first, {
    required BusinessDeviceCall handle,
    required BusinessDeviceResume resume,
    bool Function()? alive,
    void Function(int round)? onRound,
    bool arabic = true,
    Duration perCall = callTimeout,
    Duration total = budget,
    Stopwatch? clock,
  }) => SaraDeviceLoop.run(first, handle: handle, resume: resume, alive: alive,
      onRound: onRound, arabic: arabic, perCall: perCall, total: total, clock: clock);

  /// Trims a device answer so it fits what the server reads.
  static Map<String, dynamic> compact(
    Map<String, dynamic> result, {
    int limit = resultLimit,
  }) => SaraDeviceLoop.compact(result, limit: limit);
}
