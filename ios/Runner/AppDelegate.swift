import AVFoundation
import Flutter
import Speech
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var speech: FyonaSpeech?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "FyonaSpeech") {
      speech = FyonaSpeech(messenger: registrar.messenger())
    }
  }
}

/// Sara voice: the phone's speech recognizer (on-device when supported).
/// Channel `com.fyona.erp/speech` — start {lang} / stop / cancel; events go
/// to Dart as onSpeech {type, value}: ready | partial | final | error.
final class FyonaSpeech: NSObject {
  private let channel: FlutterMethodChannel
  private let engine = AVAudioEngine()
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?
  private var recognizer: SFSpeechRecognizer?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "com.fyona.erp/speech", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "start":
      let args = call.arguments as? [String: Any]
      let lang = args?["lang"] as? String ?? "ar-SA"
      SFSpeechRecognizer.requestAuthorization { status in
        DispatchQueue.main.async {
          guard status == .authorized else {
            result(false)
            return
          }
          result(self.start(lang: lang))
        }
      }
    case "stop":
      stopAudio()
      request?.endAudio()
      result(true)
    case "cancel":
      cancel()
      result(true)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func start(lang: String) -> Bool {
    cancel()
    guard let r = SFSpeechRecognizer(locale: Locale(identifier: lang)), r.isAvailable else {
      return false
    }
    recognizer = r
    let req = SFSpeechAudioBufferRecognitionRequest()
    req.shouldReportPartialResults = true
    if r.supportsOnDeviceRecognition {
      req.requiresOnDeviceRecognition = true
    }
    request = req
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
      try session.setActive(true, options: .notifyOthersOnDeactivation)
      let input = engine.inputNode
      let format = input.outputFormat(forBus: 0)
      input.removeTap(onBus: 0)
      input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
        self?.request?.append(buffer)
      }
      engine.prepare()
      try engine.start()
    } catch {
      cancel()
      return false
    }
    task = r.recognitionTask(with: req) { [weak self] res, error in
      guard let self = self else { return }
      if let res = res {
        let text = res.bestTranscription.formattedString
        if res.isFinal {
          self.emit("final", text)
          self.finish()
          return
        }
        self.emit("partial", text)
      }
      if let error = error {
        self.emit("error", (error as NSError).code)
        self.finish()
      }
    }
    emit("ready", nil)
    return true
  }

  private func emit(_ type: String, _ value: Any?) {
    let payload: [String: Any] = ["type": type, "value": value ?? NSNull()]
    DispatchQueue.main.async {
      self.channel.invokeMethod("onSpeech", arguments: payload)
    }
  }

  private func stopAudio() {
    if engine.isRunning {
      engine.stop()
    }
    engine.inputNode.removeTap(onBus: 0)
  }

  private func finish() {
    stopAudio()
    request = nil
    task = nil
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }

  private func cancel() {
    task?.cancel()
    request?.endAudio()
    finish()
  }
}
