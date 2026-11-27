import AVFoundation
import CoreBluetooth
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
  private var printer: FyonaPrinterBle?
  private var storageSpace: FyonaStorageSpace?

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
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "FyonaPrinterBle") {
      printer = FyonaPrinterBle(messenger: registrar.messenger())
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "FyonaStorageSpace") {
      storageSpace = FyonaStorageSpace(messenger: registrar.messenger())
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


/// Print Center on iOS: Bluetooth Low Energy receipt printers (CoreBluetooth).
/// Channel `com.fyona.erp/printer` — scan / connect / write / read /
/// disconnect with transport "ble" (same contract as Android). Network
/// printers (raw TCP, IPP) are reached from Dart directly. Work runs on a
/// private queue; the UI thread never waits.
final class FyonaPrinterBle: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
  private let channel: FlutterMethodChannel
  private let queue = DispatchQueue(label: "fyona.printer.ble")
  private let work = DispatchQueue(label: "fyona.printer.work")
  private var central: CBCentralManager!
  private var found: [UUID: CBPeripheral] = [:]
  private var names: [UUID: String] = [:]
  private var peripheral: CBPeripheral?
  private var writeChar: CBCharacteristic?
  private var powered = DispatchSemaphore(value: 0)
  private var connected = DispatchSemaphore(value: 0)
  private var discovered = DispatchSemaphore(value: 0)
  private var wrote = DispatchSemaphore(value: 0)
  private var ready = DispatchSemaphore(value: 0)
  private var pendingChars = 0

  private static let printServices: [CBUUID] = [
    "18F0", "E7810A71-73AE-499D-8C15-FAA9AEF0C3F2", "49535343-FE7D-4AE5-8FA9-9FAFD205E455",
    "FF00", "FFE0", "FEE7",
  ].map { CBUUID(string: $0) }

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "com.fyona.erp/printer", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    guard (args["transport"] as? String) == "ble" else {
      result(FlutterMethodNotImplemented)
      return
    }
    work.async {
      let reply: Any?
      switch call.method {
      case "scan":
        reply = self.scan(timeout: (args["timeoutMs"] as? Int ?? 6000))
      case "connect":
        reply = self.connect(address: args["address"] as? String ?? "")
      case "write":
        let data = (args["bytes"] as? FlutterStandardTypedData)?.data ?? Data()
        reply = self.write(data)
      case "read":
        reply = nil
      case "disconnect":
        self.disconnect()
        reply = true
      default:
        DispatchQueue.main.async { result(FlutterMethodNotImplemented) }
        return
      }
      DispatchQueue.main.async { result(reply) }
    }
  }

  private func ensureCentral() -> Bool {
    if central == nil {
      powered = DispatchSemaphore(value: 0)
      central = CBCentralManager(delegate: self, queue: queue)
    }
    if central.state == .poweredOn { return true }
    _ = powered.wait(timeout: .now() + 3)
    return central.state == .poweredOn
  }

  private func scan(timeout: Int) -> Any {
    guard ensureCentral() else { return [[String: Any]]() }
    queue.sync { found.removeAll(); names.removeAll() }
    central.scanForPeripherals(withServices: nil,
                               options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    Thread.sleep(forTimeInterval: Double(min(timeout, 8000)) / 1000)
    central.stopScan()
    return queue.sync {
      found.map { id, p in ["name": names[id] ?? p.name ?? "", "address": id.uuidString] as [String: Any] }
    }
  }

  private func connect(address: String) -> Any {
    guard ensureCentral(), let id = UUID(uuidString: address) else {
      return FlutterError(code: "connect", message: "bluetooth", details: nil)
    }
    disconnect()
    let p = queue.sync { found[id] } ?? central.retrievePeripherals(withIdentifiers: [id]).first
    guard let target = p else { return FlutterError(code: "connect", message: "not found", details: nil) }
    connected = DispatchSemaphore(value: 0)
    discovered = DispatchSemaphore(value: 0)
    peripheral = target
    target.delegate = self
    central.connect(target, options: nil)
    if connected.wait(timeout: .now() + 10) == .timedOut || target.state != .connected {
      disconnect()
      return FlutterError(code: "connect", message: "timeout", details: nil)
    }
    target.discoverServices(nil)
    if discovered.wait(timeout: .now() + 10) == .timedOut || writeChar == nil {
      disconnect()
      return FlutterError(code: "unsupported", message: "no writable characteristic", details: nil)
    }
    return true
  }

  private func write(_ data: Data) -> Any {
    guard let p = peripheral, let c = writeChar, p.state == .connected else {
      return FlutterError(code: "lost", message: "not connected", details: nil)
    }
    let withResponse = !c.properties.contains(.writeWithoutResponse)
    let type: CBCharacteristicWriteType = withResponse ? .withResponse : .withoutResponse
    let size = max(20, min(512, p.maximumWriteValueLength(for: type)))
    var offset = 0
    while offset < data.count {
      let end = min(offset + size, data.count)
      let slice = data.subdata(in: offset..<end)
      if withResponse {
        wrote = DispatchSemaphore(value: 0)
        p.writeValue(slice, for: c, type: .withResponse)
        if wrote.wait(timeout: .now() + 5) == .timedOut {
          return FlutterError(code: "write", message: "ble timeout", details: nil)
        }
      } else {
        while !p.canSendWriteWithoutResponse {
          ready = DispatchSemaphore(value: 0)
          if ready.wait(timeout: .now() + 5) == .timedOut {
            return FlutterError(code: "write", message: "ble busy", details: nil)
          }
        }
        p.writeValue(slice, for: c, type: .withoutResponse)
      }
      if p.state != .connected { return FlutterError(code: "lost", message: "disconnected", details: nil) }
      offset = end
    }
    return true
  }

  private func disconnect() {
    if let p = peripheral { central?.cancelPeripheralConnection(p) }
    peripheral = nil
    writeChar = nil
  }

  // MARK: CBCentralManagerDelegate
  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    if central.state == .poweredOn { powered.signal() }
  }

  func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                      advertisementData: [String: Any], rssi RSSI: NSNumber) {
    let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
    let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
    let looksLikePrinter = services.contains(where: { FyonaPrinterBle.printServices.contains($0) }) ||
      name.range(of: "print|pos|mpt|ptp|rpp|xp-|mtp|thermal|receipt",
                 options: [.regularExpression, .caseInsensitive]) != nil
    if looksLikePrinter {
      found[peripheral.identifier] = peripheral
      names[peripheral.identifier] = name
    }
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    connected.signal()
  }

  func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
    connected.signal()
  }

  func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
    if peripheral == self.peripheral { writeChar = nil }
    wrote.signal()
    ready.signal()
  }

  // MARK: CBPeripheralDelegate
  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    let services = peripheral.services ?? []
    if services.isEmpty { discovered.signal(); return }
    pendingChars = services.count
    for s in services { peripheral.discoverCharacteristics(nil, for: s) }
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
    let writable = (service.characteristics ?? []).first {
      $0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse)
    }
    // Known printer services win over any other writable characteristic.
    if let w = writable, writeChar == nil || FyonaPrinterBle.printServices.contains(service.uuid) {
      writeChar = w
    }
    pendingChars -= 1
    if pendingChars <= 0 { discovered.signal() }
  }

  func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
    wrote.signal()
  }

  func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
    ready.signal()
  }
}

/// Channel `com.fyona.erp/storage_space` — freeBytes {path}: space the app
/// may still write on that volume (before a large restore). Same contract
/// as Android. iOS saves large backups through the share sheet (Files).
final class FyonaStorageSpace: NSObject {
  private let channel: FlutterMethodChannel

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "com.fyona.erp/storage_space", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { call, result in
      guard call.method == "freeBytes" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let path = (call.arguments as? [String: Any])?["path"] as? String ?? NSHomeDirectory()
      DispatchQueue.global(qos: .utility).async {
        let url = URL(fileURLWithPath: path)
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let free = values?.volumeAvailableCapacityForImportantUsage
        DispatchQueue.main.async { result(free.map { NSNumber(value: $0) }) }
      }
    }
  }
}
