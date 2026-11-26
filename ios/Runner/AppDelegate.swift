import AVFoundation
import AuthenticationServices
import CryptoKit
import Flutter
import Security
import Speech
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var speech: FyonaSpeech?
  private var deviceIdentity: FyonaDeviceIdentity?
  private var appleSignIn: FyonaAppleSignIn?

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
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "FyonaDeviceIdentity") {
      deviceIdentity = FyonaDeviceIdentity(messenger: registrar.messenger())
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "FyonaAppleSignIn") {
      appleSignIn = FyonaAppleSignIn(messenger: registrar.messenger())
    }
  }
}

/// Trusted-device identity (docs/AUTH_PLAN.md): one ECDSA P-256 key pair per
/// install, created in the Secure Enclave when the phone has one (else a
/// device-only Keychain key). The private key is never exported: only the
/// public key (SubjectPublicKeyInfo DER, base64) and DER signatures leave.
/// Channel `com.fyona.erp/device_identity` — ensure / publicKey /
/// sign {message} / deviceInfo (same contract as Android).
final class FyonaDeviceIdentity: NSObject {
  private let channel: FlutterMethodChannel
  private let tag = "com.fyona.erp.device_identity.v1".data(using: .utf8)!
  private let queue = DispatchQueue(label: "com.fyona.erp.device_identity")
  private var secureEnclaveBacked = false

  /// DER prefix of a P-256 SubjectPublicKeyInfo; followed by the 65-byte
  /// uncompressed point (0x04 || X || Y) from SecKeyCopyExternalRepresentation.
  private static let spkiPrefix: [UInt8] = [
    0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
    0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
  ]

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "com.fyona.erp/device_identity", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    queue.async {
      var value: Any?
      var failure: FlutterError?
      switch call.method {
      case "ensure":
        let created = self.ensureKey()
        if let pk = self.publicKeyBase64() {
          value = ["created": created, "public_key": pk, "secure_enclave": self.secureEnclaveBacked] as [String: Any]
        } else {
          failure = FlutterError(code: "device_key", message: "no key", details: nil)
        }
      case "publicKey":
        _ = self.ensureKey()
        if let pk = self.publicKeyBase64() {
          value = pk
        } else {
          failure = FlutterError(code: "device_key", message: "no key", details: nil)
        }
      case "sign":
        guard let message = args?["message"] as? String else {
          failure = FlutterError(code: "bad_args", message: "message missing", details: nil)
          break
        }
        _ = self.ensureKey()
        if let sig = self.sign(message) {
          value = sig
        } else {
          failure = FlutterError(code: "device_key", message: "sign failed", details: nil)
        }
      case "deviceInfo":
        value = FyonaDeviceIdentity.deviceInfo()
      default:
        DispatchQueue.main.async { result(FlutterMethodNotImplemented) }
        return
      }
      DispatchQueue.main.async {
        if let failure = failure {
          result(failure)
        } else {
          result(value)
        }
      }
    }
  }

  private func loadKey() -> SecKey? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassKey,
      kSecAttrApplicationTag as String: tag,
      kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
      kSecReturnRef as String: true,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess, let found = item else { return nil }
    return (found as! SecKey)
  }

  private func createKey(secureEnclave: Bool) -> SecKey? {
    var error: Unmanaged<CFError>?
    let flags: SecAccessControlCreateFlags = secureEnclave ? [.privateKeyUsage] : []
    guard let access = SecAccessControlCreateWithFlags(
      kCFAllocatorDefault,
      kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      flags,
      &error
    ) else { return nil }
    var attributes: [String: Any] = [
      kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
      kSecAttrKeySizeInBits as String: 256,
      kSecPrivateKeyAttrs as String: [
        kSecAttrIsPermanent as String: true,
        kSecAttrApplicationTag as String: tag,
        kSecAttrAccessControl as String: access,
      ] as [String: Any],
    ]
    if secureEnclave {
      attributes[kSecAttrTokenID as String] = kSecAttrTokenIDSecureEnclave
    }
    return SecKeyCreateRandomKey(attributes as CFDictionary, &error)
  }

  /// Returns true when a NEW key pair was created.
  private func ensureKey() -> Bool {
    if loadKey() != nil { return false }
    if createKey(secureEnclave: true) != nil {
      secureEnclaveBacked = true
      return true
    }
    // Simulator / no Secure Enclave: device-only Keychain key.
    secureEnclaveBacked = false
    return createKey(secureEnclave: false) != nil
  }

  private func publicKeyBase64() -> String? {
    guard let key = loadKey(), let pub = SecKeyCopyPublicKey(key) else { return nil }
    var error: Unmanaged<CFError>?
    guard let raw = SecKeyCopyExternalRepresentation(pub, &error) as Data? else { return nil }
    var der = Data(FyonaDeviceIdentity.spkiPrefix)
    der.append(raw)
    return der.base64EncodedString()
  }

  private func sign(_ message: String) -> String? {
    guard let key = loadKey(), let data = message.data(using: .utf8) else { return nil }
    var error: Unmanaged<CFError>?
    guard let sig = SecKeyCreateSignature(
      key,
      .ecdsaSignatureMessageX962SHA256,
      data as CFData,
      &error
    ) as Data? else { return nil }
    return sig.base64EncodedString()
  }

  private static func deviceInfo() -> [String: String] {
    var system = utsname()
    uname(&system)
    let machine = withUnsafePointer(to: &system.machine) { ptr -> String in
      ptr.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
    }
    var name = ""
    var version = ""
    var os = "iOS"
    if Thread.isMainThread {
      name = UIDevice.current.name
      version = UIDevice.current.systemVersion
      os = UIDevice.current.systemName
    } else {
      DispatchQueue.main.sync {
        name = UIDevice.current.name
        version = UIDevice.current.systemVersion
        os = UIDevice.current.systemName
      }
    }
    if os == "iPadOS" || os == "iPhone OS" { os = "iOS" }
    return [
      "name": name.isEmpty ? "iPhone" : name,
      "model": machine.isEmpty ? "iPhone" : machine,
      "os": os,
      "os_version": version,
    ]
  }
}

/// Sign in with Apple over channel `com.fyona.erp/apple_sign_in`.
/// signIn {nonce} — `nonce` is the RAW random value; Apple receives its
/// SHA-256 (hex) and the server checks the identity token's nonce claim
/// against sha256(raw). Returns {identity_token, authorization_code, user,
/// email?, given_name?, family_name?} (names only on the first sign-in).
final class FyonaAppleSignIn: NSObject, ASAuthorizationControllerDelegate,
  ASAuthorizationControllerPresentationContextProviding
{
  private let channel: FlutterMethodChannel
  private var pending: FlutterResult?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "com.fyona.erp/apple_sign_in", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isAvailable":
      result(true)
    case "signIn":
      guard pending == nil else {
        result(FlutterError(code: "busy", message: "sign-in already running", details: nil))
        return
      }
      let args = call.arguments as? [String: Any]
      guard let rawNonce = args?["nonce"] as? String, !rawNonce.isEmpty else {
        result(FlutterError(code: "bad_args", message: "nonce missing", details: nil))
        return
      }
      pending = result
      let request = ASAuthorizationAppleIDProvider().createRequest()
      request.requestedScopes = [.fullName, .email]
      request.nonce = FyonaAppleSignIn.sha256Hex(rawNonce)
      let controller = ASAuthorizationController(authorizationRequests: [request])
      controller.delegate = self
      controller.presentationContextProvider = self
      controller.performRequests()
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  static func sha256Hex(_ input: String) -> String {
    let digest = SHA256.hash(data: Data(input.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    for scene in scenes {
      if let window = scene.windows.first(where: { $0.isKeyWindow }) {
        return window
      }
    }
    if let window = scenes.first?.windows.first {
      return window
    }
    return ASPresentationAnchor()
  }

  func authorizationController(
    controller: ASAuthorizationController,
    didCompleteWithAuthorization authorization: ASAuthorization
  ) {
    guard let result = pending else { return }
    pending = nil
    guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
      let tokenData = credential.identityToken,
      let token = String(data: tokenData, encoding: .utf8)
    else {
      result(FlutterError(code: "no_token", message: "no identity token", details: nil))
      return
    }
    var payload: [String: Any] = [
      "identity_token": token,
      "user": credential.user,
    ]
    if let codeData = credential.authorizationCode,
      let code = String(data: codeData, encoding: .utf8)
    {
      payload["authorization_code"] = code
    }
    if let email = credential.email { payload["email"] = email }
    if let given = credential.fullName?.givenName { payload["given_name"] = given }
    if let family = credential.fullName?.familyName { payload["family_name"] = family }
    result(payload)
  }

  func authorizationController(
    controller: ASAuthorizationController,
    didCompleteWithError error: Error
  ) {
    guard let result = pending else { return }
    pending = nil
    let code: String
    if let authError = error as? ASAuthorizationError, authError.code == .canceled {
      code = "canceled"
    } else {
      code = "failed"
    }
    result(FlutterError(code: code, message: error.localizedDescription, details: nil))
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
