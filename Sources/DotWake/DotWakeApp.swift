import SwiftUI
import AVFoundation
import CoreAudio
import AudioToolbox
import CoreMedia
import WakeInference
import WakeCore
import ApplicationServices

struct InputChoice: Identifiable {
    let id: AudioDeviceID
    let name: String
    let builtIn: Bool
}
final class Detector: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    let queue = DispatchQueue(label: "DotWake.detector")
    private var spotter: SherpaOnnxKeywordSpotterWrapper?
    private var captureSession: AVCaptureSession?
    private var captureOutput: AVCaptureAudioDataOutput?
    private var runtimeObserver: NSObjectProtocol?
    private var running = false
    private var frames: UInt64 = 0
    private var callbacks: UInt64 = 0
    private var decodes: UInt64 = 0
    private var lastReport: TimeInterval = 0
    private var acceptedRate: Int?
    private var hitHandler: ((String) -> Void)?
    private var diagnosticHandler: ((String, Float) -> Void)?
    // Used identically by microphone capture and injected PCM verification.
    private func process(_ buffer: AVAudioPCMBuffer) {
        guard running, let spotter else { return }
        let format = buffer.format
        let rate = Int(format.sampleRate)
        guard rate > 0, format.channelCount > 0, let channels = buffer.floatChannelData else {
            diagnosticHandler?("Unsupported microphone PCM format", 0); return
        }
        if let acceptedRate, acceptedRate != rate {
            diagnosticHandler?("Input rate changed — stop and restart listening", 0); running = false; return
        }
        acceptedRate = rate
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }
        var mono = [Float](repeating: 0, count: count)
        let channelCount = Int(format.channelCount)
        for i in 0..<count {
            for c in 0..<channelCount {
                mono[i] += (format.isInterleaved ? channels[0][i * channelCount + c] : channels[c][i]) / Float(channelCount)
            }
        }
        callbacks += 1; frames += UInt64(count)
        let rms = sqrt(mono.reduce(Float(0)) { $0 + $1 * $1 } / Float(count))
        spotter.acceptWaveform(samples: mono, sampleRate: rate)
        while spotter.isReady() {
            spotter.decode(); decodes += 1
            let keyword = spotter.getResult().keyword
            if !keyword.isEmpty { spotter.reset(); hitHandler?(keyword) }
        }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastReport >= 0.25 {
            lastReport = now
            let db = max(-90, 20 * log10(max(rms, 0.000001)))
            diagnosticHandler?("\(rate) Hz · \(channelCount) ch · \(frames) frames · \(decodes) decode steps · \(Int(db)) dB", min(1, rms * 8))
        }
    }
    static func deviceString(_ device: AudioDeviceID, selector: AudioObjectPropertySelector) -> String {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?; var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr else { return "Microphone \(device)" }
        return name?.takeRetainedValue() as String? ?? "Microphone \(device)"
    }
    static func deviceName(_ device: AudioDeviceID) -> String { deviceString(device, selector: kAudioObjectPropertyName) }
    static func deviceUID(_ device: AudioDeviceID) -> String { deviceString(device, selector: kAudioDevicePropertyDeviceUID) }
    static func inputChoices() -> [InputChoice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { device in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &streamSize) == noErr, streamSize > 0 else { return nil }
            var transportAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var transport: UInt32 = 0; var transportSize = UInt32(MemoryLayout<UInt32>.size)
            _ = AudioObjectGetPropertyData(device, &transportAddress, 0, nil, &transportSize, &transport)
            return InputChoice(id: device, name: deviceName(device), builtIn: transport == kAudioDeviceTransportTypeBuiltIn)
        }.sorted { $0.builtIn && !$1.builtIn }
    }
    var counters: String { "callbacks=\(callbacks), frames=\(frames), decodes=\(decodes)" }
    private func beginProcessing(hit: @escaping (String) -> Void, diagnostics: ((String, Float) -> Void)? = nil) {
        queue.sync {
            frames = 0; callbacks = 0; decodes = 0; lastReport = 0; acceptedRate = nil
            hitHandler = hit; diagnosticHandler = diagnostics; running = true
        }
    }
    func prepare(name: String) throws {
        let root = Bundle.main.resourceURL!.appendingPathComponent("Model")
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
        func path(_ prefix: String) throws -> String {
            guard let f = files.first(where: { $0.hasPrefix(prefix) && $0.hasSuffix(".onnx") }) else { throw NSError(domain: "Missing model: \(prefix)", code: 1) }; return root.appendingPathComponent(f).path
        }
        let tokens = root.appendingPathComponent("tokens.txt").path
        let vocab = try String(contentsOfFile: tokens, encoding: .utf8).split(separator: "\n").compactMap { $0.split(separator: " ").first.map(String.init) }
        let scores = try JSONDecoder().decode([String: Double].self, from: Data(contentsOf: root.appendingPathComponent("bpe-scores.json")))
        guard let hey = KeywordTokens.encode("Hey \(name)", vocabulary: vocab, scores: scores),
              let mute = KeywordTokens.encode("Mute \(name)", vocabulary: vocab, scores: scores),
              let bye = KeywordTokens.encode("Bye \(name)", vocabulary: vocab, scores: scores),
              let by = KeywordTokens.encode("By \(name)", vocabulary: vocab, scores: scores) else {
            throw NSError(domain: "Name must use English letters supported by this model", code: 2)
        }
        // Three semantic commands. Preserve the existing homophone spelling for Bye;
        // both spellings emit the same bye label, never a fourth command.
        let keywords = "\(hey) @hey\n\(mute) #0.20 @mute\n\(bye) @bye\n\(by) @bye\n"
        let transducer = try sherpaOnnxOnlineTransducerModelConfig(encoder: path("encoder"), decoder: path("decoder"), joiner: path("joiner"))
        let model = sherpaOnnxOnlineModelConfig(tokens: tokens, transducer: transducer)
        var config = sherpaOnnxKeywordSpotterConfig(featConfig: sherpaOnnxFeatureConfig(sampleRate: 16000, featureDim: 80), modelConfig: model, keywordsFile: "", keywordsScore: 1.0, keywordsThreshold: 0.25, keywordsBuf: keywords, keywordsBufSize: keywords.utf8.count)
        spotter = SherpaOnnxKeywordSpotterWrapper(config: &config)
    }
    func start(device: AudioDeviceID, hit: @escaping (String) -> Void, diagnostics: @escaping (String, Float) -> Void) throws {
        let uid = Self.deviceUID(device)
        guard let microphone = AVCaptureDevice(uniqueID: uid), microphone.hasMediaType(.audio) else {
            throw NSError(domain: "Selected microphone unavailable. Refresh microphones and select the Mac input.", code: 5)
        }
        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: microphone)
        let output = AVCaptureAudioDataOutput()
        // macOS AVCapture performs format conversion; no AVAudioEngine graph or AUHAL rebinding.
        output.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true]
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw NSError(domain: "Cannot configure selected microphone capture", code: 6)
        }
        session.addInput(input); session.addOutput(output); session.commitConfiguration()
        beginProcessing(hit: hit, diagnostics: diagnostics)
        output.setSampleBufferDelegate(self, queue: queue)
        captureSession = session; captureOutput = output
        runtimeObserver = NotificationCenter.default.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: nil) { [weak self] notification in
            let message = (notification.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription ?? "Unknown capture error"
            self?.queue.async { [weak self] in self?.diagnosticHandler?("Capture error: \(message)", 0) }
        }
        session.startRunning()
        guard session.isRunning else { stop(); throw NSError(domain: "Microphone capture session did not start", code: 7) }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        receiveSample(sampleBuffer)
    }
    private func receiveSample(_ sampleBuffer: CMSampleBuffer) {
        guard running, let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: asbd) else { return }
        let count = CMSampleBufferGetNumSamples(sampleBuffer)
        guard count > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { return }
        pcm.frameLength = AVAudioFrameCount(count)
        let result = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(count), into: pcm.mutableAudioBufferList)
        guard result == noErr else { diagnosticHandler?("Capture error: PCM copy failed (OSStatus \(result))", 0); return }
        // This delegate already runs on the detector's serial queue: no nested sync/deadlock.
        process(pcm)
    }
    #if DOT_WAKE_DIAGNOSTICS
    static func checkOfflineLifecycle() throws {
        let detector = Detector()
        let names = ["Lucy", "Sam", "Jane Doe", "alice", "ABCDEFGHIJKLMNOPQRSTUVWXYZ"]
        var cycles = 0
        for _ in 0..<4 {
            for name in names {
                try detector.prepare(name: name)
                precondition(detector.spotter != nil && !detector.running)
                precondition(detector.captureSession == nil && detector.captureOutput == nil)
                precondition(detector.runtimeObserver == nil && detector.frames == 0)
                detector.stop()
                detector.stop()
                precondition(detector.spotter == nil && !detector.running)
                precondition(detector.captureSession == nil && detector.captureOutput == nil)
                precondition(detector.runtimeObserver == nil && detector.hitHandler == nil && detector.diagnosticHandler == nil)
                cycles += 1
            }
        }
        for name in ["你好", "🙂"] {
            var rejected = false
            do { try detector.prepare(name: name) } catch { rejected = true }
            precondition(rejected && detector.spotter == nil)
            detector.stop()
        }
        print("PASS offline lifecycle: \(cycles) prepare/double-stop cycles, \(names.count) configured names, 2 invalid names rejected; no capture created")
    }
    private func injectSample(_ pcm: AVAudioPCMBuffer) throws {
        var description: CMAudioFormatDescription?
        var result = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: pcm.format.streamDescription,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description)
        guard result == noErr, let description else { throw NSError(domain: "Fixture audio format creation", code: Int(result)) }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(pcm.format.sampleRate)), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        result = CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: description, sampleCount: Int(pcm.frameLength),
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample)
        guard result == noErr, let sample else { throw NSError(domain: "Fixture sample creation", code: Int(result)) }
        result = CMSampleBufferSetDataBufferFromAudioBufferList(sample, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: pcm.audioBufferList)
        guard result == noErr else { throw NSError(domain: "Fixture sample PCM setup", code: Int(result)) }
        CMSampleBufferSetDataReady(sample)
        queue.sync { receiveSample(sample) }
    }
    func checkFile(_ url: URL, targetRate: Double? = nil, stereo: Bool = false, paced: Bool = false) throws -> [String] {
        guard spotter != nil else { return [] }
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0 else { throw NSError(domain: "Empty test audio", code: 4) }
        let sourceFormat = file.processingFormat
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetRate ?? sourceFormat.sampleRate, channels: stereo ? 2 : 1, interleaved: false)!
        // Convert synthetic fixture to a microphone-like PCM format, then invoke the exact capture path.
        let source = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: source)
        let converter = AVAudioConverter(from: sourceFormat, to: format)!
        let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(file.length) * format.sampleRate / sourceFormat.sampleRate) + 512)!
        var supplied = false
        var conversionError: NSError?
        converter.convert(to: converted, error: &conversionError) { _, status in
            if supplied { status.pointee = .endOfStream; return nil }
            supplied = true; status.pointee = .haveData; return source
        }
        if let conversionError { throw conversionError }
        var hits: [String] = []
        beginProcessing(hit: { hits.append($0) })
        var offset = 0
        while offset < Int(converted.frameLength) {
            let length = min(2048, Int(converted.frameLength) - offset)
            let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(length))!
            chunk.frameLength = AVAudioFrameCount(length)
            for c in 0..<Int(format.channelCount) {
                chunk.floatChannelData![c].update(from: converted.floatChannelData![c].advanced(by: offset), count: length)
            }
            if paced { Thread.sleep(forTimeInterval: Double(length) / format.sampleRate) }
            try injectSample(chunk); offset += length
        }
        // Streaming silence, never inputFinished(): mirrors a live microphone after the phrase.
        for _ in 0..<Int(ceil(format.sampleRate / 2048)) {
            let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2048)!
            silence.frameLength = 2048
            for c in 0..<Int(format.channelCount) { silence.floatChannelData![c].initialize(repeating: 0, count: 2048) }
            if paced { Thread.sleep(forTimeInterval: 2048 / format.sampleRate) }
            try injectSample(silence)
        }
        print("CMSampleBuffer capture path: \(Int(format.sampleRate)) Hz / \(format.channelCount) ch; \(counters)")
        queue.sync { running = false; hitHandler = nil; diagnosticHandler = nil }
        return hits
    }
    #endif
    func stop() {
        captureOutput?.setSampleBufferDelegate(nil, queue: nil)
        captureSession?.stopRunning()
        if let observer = runtimeObserver { NotificationCenter.default.removeObserver(observer) }
        runtimeObserver = nil
        if let session = captureSession {
            session.beginConfiguration()
            for input in session.inputs { session.removeInput(input) }
            for output in session.outputs { session.removeOutput(output) }
            session.commitConfiguration()
        }
        captureOutput = nil; captureSession = nil
        queue.sync { running = false; spotter = nil; hitHandler = nil; diagnosticHandler = nil }
    }

}
@MainActor final class Model: ObservableObject {
    @Published var name = UserDefaults.standard.string(forKey: "dotName") ?? "Lucy"
    @Published var status = "Listening off"
    @Published var listening = false
    @Published var starting = false
    @Published var realStatus = "Checking ChatGPT…"
    private let realController = LucyCallController()
    private var callRequestGeneration = 0
    var callSummary: String {
        if realStatus.contains("Accessibility required") { return "Allow Accessibility for Dot Wake in System Settings to control calls." }
        if realStatus.hasPrefix("Dot session UI: inactive") { return "\(name.trimmingCharacters(in: .whitespacesAndNewlines)) is ready for a call" }
        if realStatus.hasPrefix("Dot session UI: muted") || realStatus.hasPrefix("Dot muted") { return "Call microphone muted" }
        if realStatus.hasPrefix("Dot session UI: unmuted") || realStatus.hasPrefix("Dot unmuted") { return "Call microphone on" }
        if realStatus.hasPrefix("Dot start requested") { return "Calling \(name)…" }
        if realStatus.hasPrefix("Dot call ended") { return "Call ended" }
        if realStatus.hasPrefix("Checking") { return "Checking ChatGPT…" }
        if realStatus.hasPrefix("Sending") { return "Updating the call…" }
        return realStatus.replacingOccurrences(of: "Call control error: ", with: "")
    }
    func nameChanged() {
        callRequestGeneration += 1; realController.cancel()
        let generation = callRequestGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.callRequestGeneration == generation else { return }
            self.refreshRealState()
        }
    }
    func refreshRealState() { requestReal(nil) }
    func requestReal(_ intent: CallIntent?) {
        guard let target = try? DotTarget(name: name) else { realStatus = "Enter your dot’s name in Settings."; return }
        let generation = callRequestGeneration
        realStatus = intent == nil ? "Checking ChatGPT…" : "Sending call action…"
        realController.request(intent, target: target) { [weak self] result in
            guard let self, self.callRequestGeneration == generation else { return }
            self.realStatus = result
            if !self.listening, !self.starting, AXIsProcessTrusted(), self.status == "Accessibility permission required" {
                self.status = "Listening off"
            }
            if intent != nil { self.add(result) }
        }
    }
    @Published var inputs: [InputChoice] = Detector.inputChoices()
    @Published var selectedInput: AudioDeviceID = 0
    init() {
        selectedInput = inputs.first(where: { $0.builtIn })?.id ?? inputs.first?.id ?? 0
    }
    func refreshInputs() {
        inputs = Detector.inputChoices()
        if !inputs.contains(where: { $0.id == selectedInput }) { selectedInput = inputs.first(where: { $0.builtIn })?.id ?? inputs.first?.id ?? 0 }
    }
    @Published var inputDevice = "Default microphone"
    @Published var diagnostics = "Microphone off — no audio captured"
    @Published var inputLevel: Float = 0
    @Published var lastDetection = "No wake phrase detected yet"
    private var healthTimer: Timer?
    private var receivedFrames = false
    @Published var log: [String] = []
    private var gate = WakeGate()
    private let detector = Detector()
    private var epoch = ListeningEpoch()
    func add(_ text: String) { log.insert("\(Date().formatted(date: .omitted, time: .standard)) · \(text)", at: 0); if log.count > 20 { log.removeLast(log.count - 20) } }
    func stop() { callRequestGeneration += 1; realController.cancel(); realStatus = "Listening stopped; ChatGPT call unchanged."; _ = epoch.advance(); detector.stop(); gate.stop(); listening = false; starting = false; status = "Listening off"; healthTimer?.invalidate(); healthTimer = nil; inputLevel = 0; diagnostics = "Microphone off — no audio captured" }
    func start() {
        guard !starting, !listening else { return }
        let clean = name.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !clean.isEmpty, clean.count <= 32, clean.allSatisfy({ $0.isASCII && ($0.isLetter || $0 == " ") }) else { status = "Use 1–32 English letters/spaces"; return }
        guard AXIsProcessTrusted() else {
            status = "Accessibility permission required"
            realStatus = "Accessibility required for Dot Wake.app to control calls. Allow Dot Wake in System Settings."
            return
        }
        name = clean; UserDefaults.standard.set(clean, forKey: "dotName")
        starting = true; let token = epoch.advance()
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            beginListening(clean: clean, token: token)
        case .notDetermined:
            status = "Waiting for macOS microphone permission…"
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] allowed in
                Task { @MainActor in
                    guard let self, self.epoch.accepts(token) else { return }
                    if allowed { self.beginListening(clean: clean, token: token) }
                    else { self.starting = false; self.status = "Microphone denied — enable Dot Wake in System Settings" }
                }
            }
        case .denied:
            starting = false; status = "Microphone denied — enable Dot Wake in System Settings"
        case .restricted:
            starting = false; status = "Microphone access restricted by macOS"
        @unknown default:
            starting = false; status = "Microphone authorization unavailable"
        }
    }
    private func beginListening(clean: String, token: Int) {
        guard epoch.accepts(token), starting else { return }
        status = "Starting local detector…"
                do {
                    try self.detector.prepare(name: clean)
                    self.gate.name = clean; self.gate.listening = true
                    self.inputDevice = Detector.deviceName(self.selectedInput)
                    self.receivedFrames = false
                    self.diagnostics = "Waiting for microphone frames…"
                    try self.detector.start(device: self.selectedInput, hit: { [weak self] phrase in
                        Task { @MainActor in
                            guard let self, self.epoch.accepts(token),
                                  let command = KeywordPhrases.phrase(for: phrase, name: clean) else { return }
                            self.receive(command)
                        }
                    }, diagnostics: { [weak self] text, level in
                        Task { @MainActor in
                            guard let self, self.epoch.accepts(token) else { return }
                            if text.hasPrefix("Capture error:") || text.hasPrefix("Unsupported") || text.hasPrefix("Input rate changed") {
                                self.stop(); self.status = text; return
                            }
                            self.receivedFrames = true; self.diagnostics = text; self.inputLevel = level
                            self.status = "Listening · Hey / Mute / Bye \(clean)"
                        }
                    })
                    self.healthTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
                        Task { @MainActor in
                            guard let self, self.epoch.accepts(token), !self.receivedFrames else { return }
                            let deviceName = self.inputDevice
                            self.stop()
                            self.status = "No frames from \(deviceName). Capture stopped. Select Mac microphone, then retry once."
                        }
                    }
                    self.listening = true; self.starting = false; self.status = "Capture started — waiting for microphone frames"
                } catch { self.stop(); self.status = "Detector unavailable: \(error.localizedDescription)" }
    }
    func receive(_ phrase: String) {
        guard let intent = gate.accept(phrase, now: ProcessInfo.processInfo.systemUptime) else { return }
        lastDetection = "Detected: \(phrase)"
        add("\(phrase) → \(intent.rawValue)")
        requestReal(intent)
    }
}
struct Panel: View {
    @ObservedObject var model: Model
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Dot Wake").font(.title2.bold())
                    Spacer()
                    Image(systemName: "circle.fill").foregroundStyle(model.listening ? .green : .secondary)
                }
                Text(model.status).font(.callout)
                Button(model.listening || model.starting ? "Stop Listening" : "Start Listening") {
                    if model.listening || model.starting { model.stop() } else { model.start() }
                }.buttonStyle(.borderedProminent).controlSize(.large)
                if model.listening { ProgressView(value: Double(model.inputLevel)).tint(.green) }
                Text(model.callSummary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if model.lastDetection.hasPrefix("Detected:") { Text(model.lastDetection).font(.callout.bold()) }
                Divider()
                command("Hey \(model.name)", action: "Start / unmute")
                command("Mute \(model.name)", action: "Mute microphone")
                command("Bye \(model.name)", action: "End call")
                Divider()
                Picker("Microphone", selection: $model.selectedInput) {
                    ForEach(model.inputs) { input in Text(input.name + (input.builtIn ? " (recommended)" : "")).tag(input.id) }
                }.disabled(model.listening || model.starting)
                ExpandableSection(title: "Settings") {
                    TextField("Dot name", text: $model.name).textFieldStyle(.roundedBorder)
                        .disabled(model.listening || model.starting).onChange(of: model.name) { _ in model.nameChanged() }
                    Text("Use your dot’s actual name in ChatGPT. Commands locate it automatically. ChatGPT opens in the foreground only if it has no window.").font(.caption).foregroundStyle(.secondary)
                    Button("Refresh microphones") { model.refreshInputs() }.disabled(model.listening || model.starting)
                }
                ExpandableSection(title: "Activity") {
                    Text(model.diagnostics).font(.caption.monospaced()).fixedSize(horizontal: false, vertical: true)
                    ForEach(Array(model.log.enumerated()), id: \.offset) { _, entry in Text(entry).font(.caption).frame(maxWidth: .infinity, alignment: .leading) }
                    if !model.log.isEmpty { Button("Clear activity") { model.log.removeAll() } }
                }
                Text("Local audio processing. Nothing recorded.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Quit") { model.stop(); NSApplication.shared.terminate(nil) }
                }
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }.frame(width: 380, height: min(560, max(400, (NSScreen.main?.visibleFrame.height ?? 800) - 80)))
        .onAppear { model.refreshRealState() }
    }
    private func command(_ phrase: String, action: String) -> some View {
        HStack { Text(phrase).font(.callout.weight(.semibold)); Spacer(); Text(action).font(.callout).foregroundStyle(.secondary) }
    }
}
private struct ExpandableSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack {
                    Text(title)
                    Spacer()
                    Image(systemName: "chevron.right").rotationEffect(.degrees(expanded ? 90 : 0))
                }.padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(title).accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if expanded { content() }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
@main struct DotWakeApp: App {
    @StateObject private var model = Model()
    init() {
        #if DOT_WAKE_DIAGNOSTICS
        if CommandLine.arguments.contains("--offline-lifecycle") {
            do { try Detector.checkOfflineLifecycle(); exit(0) }
            catch { print("Offline lifecycle failed: \(error)"); exit(1) }
        }
        if CommandLine.arguments.contains("--idle-benchmark") {
            Thread.sleep(forTimeInterval: 15)
            print("Stopped diagnostic process: no GUI loop, model, capture or call action")
            exit(0)
        }
        if CommandLine.arguments.contains("--call-check") || CommandLine.arguments.contains("--call-intent") || CommandLine.arguments.contains("--navigate-dot") {
            let arguments = CommandLine.arguments
            let intent: CallIntent?
            if let index = arguments.firstIndex(of: "--call-intent") {
                guard arguments.count > index + 1, ["hey", "mute", "bye"].contains(arguments[index + 1]) else {
                    print("Expected --call-intent hey|mute|bye"); exit(2)
                }
                switch arguments[index + 1] {
                case "hey": intent = .startOrUnmute
                case "mute": intent = .mute
                default: intent = .end
                }
            } else { intent = nil }
            let targetName: String
            if let index = arguments.firstIndex(of: "--target"), arguments.count > index + 1 { targetName = arguments[index + 1] }
            else { targetName = UserDefaults.standard.string(forKey: "dotName") ?? "Lucy" }
            do { print(try LucyAXBackend(target: DotTarget(name: targetName), cancelled: { false }).perform(intent, navigateOnly: arguments.contains("--navigate-dot"))); exit(0) }
            catch { print("Call control error: \(error.localizedDescription)"); exit(1) }
        }
        if CommandLine.arguments.contains("--list-inputs") {
            for input in Detector.inputChoices() {
                let device = AVCaptureDevice(uniqueID: Detector.deviceUID(input.id))
                print("\(input.name): AVCaptureDevice mapped=\(device != nil), audio=\(device?.hasMediaType(.audio) ?? false), builtIn=\(input.builtIn)")
            }
            exit(0)
        }
        if CommandLine.arguments.count >= 4 && CommandLine.arguments[1] == "--check-file" {
            do {
                let start = ProcessInfo.processInfo.systemUptime
                let detector = Detector()
                if CommandLine.arguments.contains("--profile-hold") {
                    FileHandle.standardOutput.write(Data("PHASE before-model\n".utf8))
                    Thread.sleep(forTimeInterval: 12)
                }
                try detector.prepare(name: CommandLine.arguments[2])
                if CommandLine.arguments.contains("--profile-hold") {
                    FileHandle.standardOutput.write(Data("PHASE model-ready\n".utf8))
                    Thread.sleep(forTimeInterval: 12)
                }
                let rate = CommandLine.arguments.count > 4 ? Double(CommandLine.arguments[4]) : nil
                let hits = try detector.checkFile(URL(fileURLWithPath: CommandLine.arguments[3]), targetRate: rate, stereo: CommandLine.arguments.contains("--stereo"), paced: CommandLine.arguments.contains("--paced"))
                if CommandLine.arguments.contains("--profile-hold") {
                    FileHandle.standardOutput.write(Data("PHASE after-inference\n".utf8))
                    Thread.sleep(forTimeInterval: 12)
                }
                var gate = WakeGate(); gate.name = CommandLine.arguments[2]; gate.listening = true
                var intents: [String] = []
                for (index, label) in hits.enumerated() {
                    if let phrase = KeywordPhrases.phrase(for: label, name: gate.name),
                       let intent = gate.accept(phrase, now: Double(index) * 2) { intents.append(intent.rawValue) }
                }
                print("Hits: \(hits); Intents: \(intents); elapsed seconds: \(ProcessInfo.processInfo.systemUptime - start)")
                exit(hits.isEmpty ? 2 : 0)
            } catch { print("Detector check failed: \(error)"); exit(1) }
        }
        #endif
    }
    var body: some Scene {
        MenuBarExtra("Dot Wake", systemImage: "circle.dotted") { Panel(model: model) }.menuBarExtraStyle(.window)
    }
}
