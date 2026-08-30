import EventKit
import Flutter
import ActivityKit
import AVFoundation
import MediaPlayer
import Speech
import UIKit
import WebKit
import WidgetKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, AVAudioPlayerDelegate {
  private let eventStore = EKEventStore()
  private let audioEngine = AVAudioEngine()
  private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
  private var recognitionTask: SFSpeechRecognitionTask?
  private var speechResult: FlutterResult?
  private var latestTranscription = ""
  private var audioTapInstalled = false
  private var playbackPlayer: AVAudioPlayer?
  private var playbackUsesSystemMedia = false
  private var nativeChannel: FlutterMethodChannel?
  private var chatBackgroundTask = UIBackgroundTaskIdentifier.invalid
  private var chatActivityToken: Any?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let channel = FlutterMethodChannel(
      name: "com.susuclaude.app/native",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    nativeChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { result(FlutterError(code: "unavailable", message: nil, details: nil)); return }
      let arguments = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "getTimeZoneIdentifier": result(TimeZone.current.identifier)
      case "beginChatBackgroundTask":
        self.beginChatBackgroundTask(arguments)
        result(true)
      case "updateChatActivity":
        self.updateChatActivity(arguments)
        result(nil)
      case "endChatBackgroundTask":
        self.endChatBackgroundTask(arguments)
        result(nil)
      case "addCalendarEvent": self.addCalendarEvent(arguments, result: result)
      case "addSystemReminder": self.addReminder(arguments, result: result)
      case "pickSystemRingtone": result(["title": "系统默认提示音", "uri": NSNull()])
      case "previewHtml":
        let source = arguments["html"] as? String ?? ""
        let runtimeScope = arguments["runtimeScope"] as? String ?? "shared"
        let fallbackTitle = arguments["title"] as? String ?? "HTML 预览"
        let preview = HtmlPreviewViewController(
          source: source,
          runtimeScope: runtimeScope,
          fallbackTitle: fallbackTitle,
          channel: channel
        )
        let navigation = UINavigationController(rootViewController: preview)
        navigation.modalPresentationStyle = .fullScreen
        guard let presenter = self.activeViewController() else {
          result(FlutterError(code: "unavailable", message: "No active view controller", details: nil))
          return
        }
        presenter.present(navigation, animated: true)
        result(nil)
      case "clearPreviewCache":
        HtmlPreviewViewController.clearRuntime(
          arguments["runtimeScope"] as? String ?? "shared"
        ) { result(nil) }
      case "recognizeSpeech":
        self.recognizeSpeech(arguments, result: result)
      case "playAudio":
        self.playAudio(arguments, result: result)
      case "stopAudio":
        self.stopAudio(result: result)
      case "updateWidget":
        let defaults = UserDefaults(suiteName: "group.com.susuclaude.app")
        defaults?.set(arguments["title"], forKey: "widgetTitle")
        defaults?.set(arguments["body"], forKey: "widgetBody")
        if #available(iOS 14.0, *) {
          WidgetCenter.shared.reloadAllTimelines()
        }
        result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  private func beginChatBackgroundTask(_ arguments: [String: Any]) {
    endUIKitBackgroundTask()
    chatBackgroundTask = UIApplication.shared.beginBackgroundTask(
      withName: "ClaudeChat model response"
    ) { [weak self] in
      self?.endUIKitBackgroundTask()
    }
    guard #available(iOS 16.1, *), ActivityAuthorizationInfo().areActivitiesEnabled else {
      return
    }
    Task { @MainActor [weak self] in
      guard let self else { return }
      if let old = self.chatActivityToken as? Activity<ClaudeChatActivityAttributes> {
        await old.end(
          using: ClaudeChatActivityAttributes.ContentState(
            status: "任务已结束",
            preview: "",
            working: false
          ),
          dismissalPolicy: .immediate
        )
      }
      let attributes = ClaudeChatActivityAttributes(
        title: (arguments["title"] as? String)?.nonEmpty ?? "ClaudeChat",
        scopeId: arguments["scopeId"] as? String ?? ""
      )
      let state = ClaudeChatActivityAttributes.ContentState(
        status: (arguments["status"] as? String)?.nonEmpty ?? "小机子正在回复",
        preview: arguments["preview"] as? String ?? "",
        working: true
      )
      do {
        self.chatActivityToken = try Activity.request(
          attributes: attributes,
          contentState: state,
          pushType: nil
        )
      } catch {
        self.chatActivityToken = nil
      }
    }
  }

  private func updateChatActivity(_ arguments: [String: Any]) {
    guard #available(iOS 16.1, *),
          let activity = chatActivityToken as? Activity<ClaudeChatActivityAttributes> else {
      return
    }
    let state = ClaudeChatActivityAttributes.ContentState(
      status: (arguments["status"] as? String)?.nonEmpty ?? "任务正在运行",
      preview: arguments["preview"] as? String ?? "",
      working: arguments["working"] as? Bool ?? true
    )
    Task { await activity.update(using: state) }
  }

  private func endChatBackgroundTask(_ arguments: [String: Any]) {
    endUIKitBackgroundTask()
    guard #available(iOS 16.1, *),
          let activity = chatActivityToken as? Activity<ClaudeChatActivityAttributes> else {
      chatActivityToken = nil
      return
    }
    chatActivityToken = nil
    let state = ClaudeChatActivityAttributes.ContentState(
      status: (arguments["status"] as? String)?.nonEmpty ?? "任务已结束",
      preview: arguments["preview"] as? String ?? "",
      working: false
    )
    Task {
      await activity.end(
        using: state,
        dismissalPolicy: .after(Date().addingTimeInterval(30))
      )
    }
  }

  private func endUIKitBackgroundTask() {
    guard chatBackgroundTask != .invalid else { return }
    UIApplication.shared.endBackgroundTask(chatBackgroundTask)
    chatBackgroundTask = .invalid
  }

  private func playAudio(_ arguments: [String: Any], result: @escaping FlutterResult) {
    guard let path = arguments["path"] as? String, !path.isEmpty else {
      result(FlutterError(code: "audio", message: "Missing audio path", details: nil))
      return
    }
    do {
      let session = AVAudioSession.sharedInstance()
      let backgroundPlayback = arguments["backgroundPlayback"] as? Bool ?? false
      if backgroundPlayback {
        try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
      } else {
        try session.setCategory(.ambient, mode: .default, options: [])
      }
      try session.setActive(true)
      let player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
      player.delegate = self
      player.prepareToPlay()
      guard player.play() else {
        result(FlutterError(code: "audio", message: "Audio playback did not start", details: nil))
        return
      }
      playbackPlayer = player
      playbackUsesSystemMedia = backgroundPlayback
      if backgroundPlayback {
        configureSystemMediaPlayback(
          title: (arguments["title"] as? String)?.nonEmpty ?? "语音播放",
          subtitle: arguments["subtitle"] as? String ?? "",
          preview: arguments["preview"] as? String ?? ""
        )
      } else {
        clearSystemMediaPlayback()
      }
      result(nil)
    } catch {
      result(FlutterError(code: "audio", message: error.localizedDescription, details: nil))
    }
  }

  private func stopAudio(result: @escaping FlutterResult) {
    playbackPlayer?.stop()
    playbackPlayer = nil
    clearSystemMediaPlayback()
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    nativeChannel?.invokeMethod("audioPlaybackComplete", arguments: nil)
    result(nil)
  }

  func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    playbackPlayer = nil
    clearSystemMediaPlayback()
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    nativeChannel?.invokeMethod("audioPlaybackComplete", arguments: nil)
  }

  private func configureSystemMediaPlayback(title: String, subtitle: String, preview: String) {
    guard let player = playbackPlayer else { return }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = [
      MPMediaItemPropertyTitle: title,
      MPMediaItemPropertyArtist: subtitle.nonEmpty ?? "ClaudeChat",
      MPMediaItemPropertyAlbumTitle: preview.nonEmpty ?? "Ta的声音",
      MPMediaItemPropertyPlaybackDuration: player.duration,
      MPNowPlayingInfoPropertyElapsedPlaybackTime: player.currentTime,
      MPNowPlayingInfoPropertyPlaybackRate: 1.0,
    ]

    let commands = MPRemoteCommandCenter.shared()
    commands.playCommand.removeTarget(nil)
    commands.pauseCommand.removeTarget(nil)
    commands.togglePlayPauseCommand.removeTarget(nil)
    commands.playCommand.isEnabled = true
    commands.pauseCommand.isEnabled = true
    commands.togglePlayPauseCommand.isEnabled = true
    commands.playCommand.addTarget { [weak self] _ in
      guard let self, let player = self.playbackPlayer else { return .commandFailed }
      guard player.play() else { return .commandFailed }
      self.updateSystemMediaPlaybackRate(1)
      return .success
    }
    commands.pauseCommand.addTarget { [weak self] _ in
      guard let self, let player = self.playbackPlayer else { return .commandFailed }
      player.pause()
      self.updateSystemMediaPlaybackRate(0)
      return .success
    }
    commands.togglePlayPauseCommand.addTarget { [weak self] _ in
      guard let self, let player = self.playbackPlayer else { return .commandFailed }
      if player.isPlaying {
        player.pause()
        self.updateSystemMediaPlaybackRate(0)
      } else {
        guard player.play() else { return .commandFailed }
        self.updateSystemMediaPlaybackRate(1)
      }
      return .success
    }
  }

  private func updateSystemMediaPlaybackRate(_ rate: Double) {
    guard playbackUsesSystemMedia, var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else {
      return
    }
    info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = playbackPlayer?.currentTime ?? 0
    info[MPNowPlayingInfoPropertyPlaybackRate] = rate
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
  }

  private func clearSystemMediaPlayback() {
    playbackUsesSystemMedia = false
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    let commands = MPRemoteCommandCenter.shared()
    commands.playCommand.removeTarget(nil)
    commands.pauseCommand.removeTarget(nil)
    commands.togglePlayPauseCommand.removeTarget(nil)
    commands.playCommand.isEnabled = false
    commands.pauseCommand.isEnabled = false
    commands.togglePlayPauseCommand.isEnabled = false
  }

  private func addCalendarEvent(_ arguments: [String: Any], result: @escaping FlutterResult) {
    Task {
      do {
        if #available(iOS 17.0, *) { _ = try await eventStore.requestFullAccessToEvents() }
        else { _ = try await eventStore.requestAccess(to: .event) }
        let event = EKEvent(eventStore: eventStore)
        event.title = arguments["title"] as? String
        event.notes = arguments["notes"] as? String
        event.startDate = Date(timeIntervalSince1970: ((arguments["start"] as? NSNumber)?.doubleValue ?? 0) / 1000)
        event.endDate = Date(timeIntervalSince1970: ((arguments["end"] as? NSNumber)?.doubleValue ?? 0) / 1000)
        event.calendar = eventStore.defaultCalendarForNewEvents
        try eventStore.save(event, span: .thisEvent)
        await MainActor.run { result(nil) }
      } catch { await MainActor.run { result(FlutterError(code: "calendar", message: error.localizedDescription, details: nil)) } }
    }
  }

  private func activeViewController() -> UIViewController? {
    let scene = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first { $0.activationState == .foregroundActive }
    var controller = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
    while let presented = controller?.presentedViewController {
      controller = presented
    }
    return controller
  }

  private func recognizeSpeech(_ arguments: [String: Any], result: @escaping FlutterResult) {
    guard speechResult == nil else {
      result(FlutterError(code: "busy", message: "Speech recognition is already active", details: nil))
      return
    }
    speechResult = result
    latestTranscription = ""
    SFSpeechRecognizer.requestAuthorization { [weak self] status in
      guard let self else { return }
      guard status == .authorized else {
        DispatchQueue.main.async { self.finishSpeech(error: "Speech recognition permission was denied") }
        return
      }
      AVAudioSession.sharedInstance().requestRecordPermission { allowed in
        DispatchQueue.main.async {
          guard allowed else {
            self.finishSpeech(error: "Microphone permission was denied")
            return
          }
          self.startSpeech(locale: arguments["locale"] as? String ?? "zh-CN")
        }
      }
    }
  }

  private func startSpeech(locale: String) {
    guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)), recognizer.isAvailable else {
      finishSpeech(error: "System speech recognizer is unavailable")
      return
    }
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.record, mode: .measurement, options: .duckOthers)
      try session.setActive(true, options: .notifyOthersOnDeactivation)
      let request = SFSpeechAudioBufferRecognitionRequest()
      request.shouldReportPartialResults = true
      request.taskHint = .dictation
      recognitionRequest = request
      let input = audioEngine.inputNode
      let format = input.outputFormat(forBus: 0)
      if audioTapInstalled { input.removeTap(onBus: 0) }
      input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
        request.append(buffer)
      }
      audioTapInstalled = true
      audioEngine.prepare()
      try audioEngine.start()
      recognitionTask = recognizer.recognitionTask(with: request) { [weak self] response, error in
        guard let self else { return }
        if let response {
          self.latestTranscription = response.bestTranscription.formattedString
          if response.isFinal {
            DispatchQueue.main.async { self.finishSpeech() }
          }
        } else if error != nil {
          DispatchQueue.main.async { self.finishSpeech(error: "Speech recognition failed") }
        }
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
        self?.finishSpeech()
      }
    } catch {
      finishSpeech(error: error.localizedDescription)
    }
  }

  private func finishSpeech(error: String? = nil) {
    guard let result = speechResult else { return }
    speechResult = nil
    if audioEngine.isRunning { audioEngine.stop() }
    if audioTapInstalled {
      audioEngine.inputNode.removeTap(onBus: 0)
      audioTapInstalled = false
    }
    recognitionRequest?.endAudio()
    recognitionTask?.cancel()
    recognitionRequest = nil
    recognitionTask = nil
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    if let error, latestTranscription.isEmpty {
      result(FlutterError(code: "speech", message: error, details: nil))
    } else {
      result(latestTranscription.isEmpty ? nil : latestTranscription)
    }
  }

  private func addReminder(_ arguments: [String: Any], result: @escaping FlutterResult) {
    Task {
      do {
        if #available(iOS 17.0, *) { _ = try await eventStore.requestFullAccessToReminders() }
        else { _ = try await eventStore.requestAccess(to: .reminder) }
        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = arguments["title"] as? String
        reminder.notes = arguments["notes"] as? String
        reminder.calendar = eventStore.defaultCalendarForNewReminders()
        let date = Date(timeIntervalSince1970: ((arguments["due"] as? NSNumber)?.doubleValue ?? 0) / 1000)
        reminder.dueDateComponents = Calendar.current.dateComponents(in: .current, from: date)
        try eventStore.save(reminder, commit: true)
        await MainActor.run { result(nil) }
      } catch { await MainActor.run { result(FlutterError(code: "reminder", message: error.localizedDescription, details: nil)) } }
    }
  }
}

private extension String {
  var nonEmpty: String? { isEmpty ? nil : self }
}

@available(iOS 16.1, *)
struct ClaudeChatActivityAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable {
    let status: String
    let preview: String
    let working: Bool
  }

  let title: String
  let scopeId: String
}

private final class HtmlPreviewViewController: UIViewController, WKNavigationDelegate {
  private static weak var activePreview: HtmlPreviewViewController?
  private var source: String
  private let runtimeScope: String
  private var fallbackTitle: String
  private let channel: FlutterMethodChannel
  private var webView: WKWebView!

  init(
    source: String,
    runtimeScope: String,
    fallbackTitle: String,
    channel: FlutterMethodChannel
  ) {
    self.source = source
    self.runtimeScope = Self.safeRuntimeScope(runtimeScope)
    let cleanTitle = fallbackTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    self.fallbackTitle = cleanTitle.isEmpty ? "HTML 预览" : cleanTitle
    self.channel = channel
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { nil }

  override func viewDidLoad() {
    super.viewDidLoad()
    Self.activePreview = self
    title = fallbackTitle
    edgesForExtendedLayout = []
    view.backgroundColor = .systemBackground
    navigationItem.leftBarButtonItem = UIBarButtonItem(
      image: UIImage(systemName: "chevron.left"),
      style: .plain,
      target: self,
      action: #selector(closePreview)
    )
    navigationItem.leftBarButtonItem?.accessibilityLabel = "返回"
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      barButtonSystemItem: .refresh,
      target: self,
      action: #selector(refreshPreview)
    )
    navigationItem.rightBarButtonItem?.accessibilityLabel = "刷新页面"
    if let navigationBar = navigationController?.navigationBar {
      let appearance = UINavigationBarAppearance()
      appearance.configureWithOpaqueBackground()
      appearance.backgroundColor = .systemBackground
      appearance.shadowColor = .separator
      appearance.titleTextAttributes = [.foregroundColor: UIColor.label]
      navigationBar.standardAppearance = appearance
      navigationBar.scrollEdgeAppearance = appearance
      navigationBar.compactAppearance = appearance
      navigationBar.isTranslucent = false
      navigationBar.tintColor = .label
    }
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .default()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = true
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    let interactionScript = WKUserScript(
      source: """
      (() => {
        let viewport = document.querySelector('meta[name="viewport"]');
        if (!viewport) {
          viewport = document.createElement('meta');
          viewport.name = 'viewport';
          document.head.appendChild(viewport);
        }
        viewport.content = 'width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover';
        const style = document.createElement('style');
        style.textContent = 'html,body{overscroll-behavior:none;-webkit-text-size-adjust:100%;}';
        document.head.appendChild(style);
      })();
      """,
      injectionTime: .atDocumentEnd,
      forMainFrameOnly: true
    )
    configuration.userContentController.addUserScript(interactionScript)
    webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = self
    webView.translatesAutoresizingMaskIntoConstraints = false
    webView.scrollView.bounces = false
    webView.scrollView.alwaysBounceHorizontal = false
    webView.scrollView.alwaysBounceVertical = false
    webView.scrollView.isDirectionalLockEnabled = true
    webView.scrollView.contentInsetAdjustmentBehavior = .never
    webView.scrollView.minimumZoomScale = 1
    webView.scrollView.maximumZoomScale = 1
    webView.scrollView.pinchGestureRecognizer?.isEnabled = false
    webView.scrollView.showsHorizontalScrollIndicator = false
    view.addSubview(webView)
    let closeGesture = UIScreenEdgePanGestureRecognizer(
      target: self,
      action: #selector(handleCloseGesture(_:))
    )
    closeGesture.edges = .left
    view.addGestureRecognizer(closeGesture)
    NSLayoutConstraint.activate([
      webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      webView.topAnchor.constraint(equalTo: view.topAnchor),
      webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    loadDocument()
  }

  @objc private func closePreview() { dismiss(animated: true) }

  @objc private func refreshPreview() { requestLatestDocument() }

  private func requestLatestDocument() {
    channel.invokeMethod(
      "requestPreviewHtml",
      arguments: ["runtimeScope": runtimeScope]
    ) { [weak self] value in
      guard let self else { return }
      if let payload = value as? [String: Any] {
        if let html = payload["html"] as? String { self.source = html }
        if let nextTitle = payload["title"] as? String,
           !nextTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          self.fallbackTitle = nextTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        }
      }
      self.loadDocument()
    }
  }

  private func loadDocument() {
    title = fallbackTitle
    let policy = "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src http: https: data: blob: 'unsafe-inline' 'unsafe-eval'; script-src http: https: data: blob: 'unsafe-inline' 'unsafe-eval'; worker-src blob: data:; connect-src http: https: data: blob:; img-src http: https: data: blob:; media-src http: https: data: blob:\">"
    let document: String
    if source.range(of: "<head", options: .caseInsensitive) != nil {
      document = source.replacingOccurrences(
        of: "(?i)<head[^>]*>",
        with: "$0\(policy)",
        options: .regularExpression
      )
    } else {
      document = "<!doctype html><html><head>\(policy)</head><body>\(source)</body></html>"
    }
    webView.loadHTMLString(
      document,
      baseURL: URL(
        string: "https://\(runtimeScope).runtime.claudechat.local/?previewRevision=\(Date().timeIntervalSince1970)"
      )
    )
  }

  static func clearRuntime(_ value: String, completion: @escaping () -> Void) {
    let scope = safeRuntimeScope(value)
    let host = "\(scope).runtime.claudechat.local"
    let store = WKWebsiteDataStore.default()
    let types = WKWebsiteDataStore.allWebsiteDataTypes()
    store.fetchDataRecords(ofTypes: types) { records in
      let scopedRecords = records.filter {
        $0.displayName == host || $0.displayName.hasSuffix(".\(host)")
      }
      let finish = {
        DispatchQueue.main.async {
          if let preview = activePreview, preview.runtimeScope == scope {
            preview.webView.evaluateJavaScript(
              "try{localStorage.clear();sessionStorage.clear();}catch(e){}"
            )
            preview.requestLatestDocument()
          }
          completion()
        }
      }
      guard !scopedRecords.isEmpty else { finish(); return }
      store.removeData(ofTypes: types, for: scopedRecords, completionHandler: finish)
    }
  }

  private static func safeRuntimeScope(_ value: String) -> String {
    let safe = value.lowercased()
      .map { $0.isLetter || $0.isNumber || $0 == "-" ? String($0) : "-" }
      .joined()
      .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    if safe.isEmpty { return "shared" }
    return String(safe.prefix(48))
  }

  @objc private func handleCloseGesture(_ gesture: UIScreenEdgePanGestureRecognizer) {
    if gesture.state == .ended && gesture.translation(in: view).x > 70 {
      closePreview()
    }
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    disableNativeDoubleTapZoom(in: webView.scrollView)
    webView.evaluateJavaScript("document.title || ''") { [weak self] value, _ in
      guard let self else { return }
      let htmlTitle = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      self.title = htmlTitle.isEmpty ? self.fallbackTitle : htmlTitle
    }
  }

  private func disableNativeDoubleTapZoom(in view: UIView) {
    view.gestureRecognizers?.forEach { recognizer in
      if let tap = recognizer as? UITapGestureRecognizer,
         tap.numberOfTapsRequired > 1 {
        tap.isEnabled = false
      }
    }
    view.subviews.forEach { disableNativeDoubleTapZoom(in: $0) }
  }

  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
  ) {
    guard let scheme = navigationAction.request.url?.scheme?.lowercased() else {
      decisionHandler(.allow)
      return
    }
    decisionHandler(
      scheme == "about" || scheme == "http" || scheme == "https" ? .allow : .cancel
    )
  }
}
