import AppKit
import AudioToolbox
import Combine
import CoreAudio
import CruiseAudioAtomics
import CruiseCore
import Foundation
import Synchronization

/// Runs the independent audio routes inside Cruise Control. At 100% an app is never
/// intercepted. Below 100%, a non-muting probe first confirms that macOS is delivering
/// samples; only then is that app's own process audio muted and replayed through its gain.
final class AudioVolumeController: ObservableObject {
    static let preferencesKey = "CruiseControl.audioVolumePreferences.v1"

    @Published private(set) var preferences: AudioVolumePreferences
    @Published private(set) var statuses: [AudioVolumeTarget: String] = [:]

    private let routeQueue = DispatchQueue(label: "com.ilovespectra.cruisecontrol.audio", qos: .userInitiated)
    private var routeTimer: DispatchSourceTimer?
    private var terminationObserver: NSObjectProtocol?
    // Accessed only on routeQueue.
    private var queuedPreferences = AudioVolumePreferences()
    private var routes: [AudioVolumeTarget: AudioVolumeTapRoute] = [:]

    init(defaults: UserDefaults = .standard) {
        let loaded = Self.loadPreferences(from: defaults)
        preferences = loaded
        for target in AudioVolumeTarget.allCases {
            statuses[target] = loaded.volume(for: target) == 1
                ? "100% · follows desktop audio"
                : "Preparing an app-only audio route…"
        }

        routeQueue.async { [weak self] in
            guard let self else { return }
            self.queuedPreferences = loaded
            let timer = DispatchSource.makeTimerSource(queue: self.routeQueue)
            timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(500))
            timer.setEventHandler { [weak self] in self?.reconcileRoutes() }
            self.routeTimer = timer
            timer.resume()
            self.reconcileRoutes()
        }

        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.routeQueue.sync { self.stopAllRoutes() }
        }
    }

    func volume(for target: AudioVolumeTarget) -> Float {
        preferences.volume(for: target)
    }

    func status(for target: AudioVolumeTarget) -> String {
        statuses[target] ?? "Waiting for audio"
    }

    func setVolume(_ value: Float, for target: AudioVolumeTarget) {
        var next = preferences
        next.setVolume(value, for: target)
        guard next != preferences else { return }
        preferences = next
        Self.savePreferences(next)
        routeQueue.async { [weak self] in
            guard let self else { return }
            self.queuedPreferences = next
            self.reconcileRoutes()
        }
    }

    func resetToDesktopLevels() {
        let next = AudioVolumePreferences()
        preferences = next
        Self.savePreferences(next)
        routeQueue.async { [weak self] in
            guard let self else { return }
            self.queuedPreferences = next
            self.reconcileRoutes()
        }
    }

    private static func loadPreferences(from defaults: UserDefaults) -> AudioVolumePreferences {
        guard let data = defaults.data(forKey: preferencesKey),
              let saved = try? JSONDecoder().decode(AudioVolumePreferences.self, from: data) else {
            return AudioVolumePreferences()
        }
        return AudioVolumePreferences(
            heyClicky: saved.volume(for: .heyClicky),
            visualStudioCode: saved.volume(for: .visualStudioCode)
        )
    }

    private static func savePreferences(_ preferences: AudioVolumePreferences) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        UserDefaults.standard.set(data, forKey: preferencesKey)
    }

    private func reconcileRoutes() {
        guard queuedPreferences.hasAttenuation else {
            stopAllRoutes()
            for target in AudioVolumeTarget.allCases {
                publish("100% · follows desktop audio", for: target)
            }
            return
        }

        do {
            let output = try AudioVolumeHAL.defaultOutputDevice()
            let processObjects = try AudioVolumeHAL.processObjects()

            for target in AudioVolumeTarget.allCases {
                let gain = queuedPreferences.volume(for: target)
                guard gain < 1 else {
                    stopRoute(for: target)
                    publish("100% · follows desktop audio", for: target)
                    continue
                }

                let matchingObjects = processObjects
                    .filter { target.matches(bundleIdentifier: $0.bundleIdentifier) }
                    .map(\.objectID)
                    .sorted()

                guard !matchingObjects.isEmpty else {
                    stopRoute(for: target)
                    publish("Waiting for an app-owned audio process", for: target)
                    continue
                }

                if let current = routes[target],
                   current.processObjectIDs == matchingObjects,
                   current.outputUID == output.uid {
                    current.setGain(gain)
                    if current.stage == .probe && current.hasReceivedAudio {
                        current.stop()
                        routes.removeValue(forKey: target)
                        try startRoute(for: target, processObjects: matchingObjects,
                                       output: output, gain: gain, stage: .active)
                    } else if current.stage == .probe {
                        publish("Safe pass-through · waiting for permission and a sound", for: target)
                    } else {
                        publish("Live · app-only gain at \(Int(gain * 100))%", for: target)
                    }
                    continue
                }

                stopRoute(for: target)
                try startRoute(for: target, processObjects: matchingObjects,
                               output: output, gain: gain, stage: .probe)
                publish("Safe pass-through · waiting for permission and a sound", for: target)
            }
        } catch {
            for target in AudioVolumeTarget.allCases where queuedPreferences.volume(for: target) < 1 {
                stopRoute(for: target)
                publish("Route unavailable · original app audio left alone (\(error.localizedDescription))", for: target)
            }
        }
    }

    private func startRoute(for target: AudioVolumeTarget,
                            processObjects: [AudioObjectID],
                            output: AudioVolumeHAL.OutputDevice,
                            gain: Float,
                            stage: AudioVolumeTapRoute.Stage) throws {
        let route = AudioVolumeTapRoute(target: target,
                                        processObjectIDs: processObjects,
                                        outputDevice: output,
                                        gain: gain,
                                        stage: stage)
        do {
            try route.start()
            routes[target] = route
            if stage == .active {
                publish("Live · app-only gain at \(Int(gain * 100))%", for: target)
            }
        } catch {
            route.stop()
            throw error
        }
    }

    private func stopRoute(for target: AudioVolumeTarget) {
        routes.removeValue(forKey: target)?.stop()
    }

    private func stopAllRoutes() {
        for target in AudioVolumeTarget.allCases { stopRoute(for: target) }
    }

    private func publish(_ status: String, for target: AudioVolumeTarget) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.statuses[target] != status else { return }
            self.statuses[target] = status
        }
    }
}

private final class AudioVolumeTapRoute {
    enum Stage: Equatable {
        case probe
        case active
    }

    let target: AudioVolumeTarget
    let processObjectIDs: [AudioObjectID]
    let outputDeviceID: AudioObjectID
    let outputUID: String
    let stage: Stage

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var ioBlock: AudioDeviceIOBlock?
    private var started = false
    private let renderState: OpaquePointer

    var hasReceivedAudio: Bool {
        CruiseAudioRenderStateHasReceivedAudio(renderState)
    }

    init(target: AudioVolumeTarget,
         processObjectIDs: [AudioObjectID],
         outputDevice: AudioVolumeHAL.OutputDevice,
         gain: Float,
         stage: Stage) {
        self.target = target
        self.processObjectIDs = processObjectIDs
        outputDeviceID = outputDevice.id
        outputUID = outputDevice.uid
        self.stage = stage
        guard let renderState = CruiseAudioRenderStateCreate(AudioVolumeMath.clampedGain(gain)) else {
            fatalError("Unable to allocate Cruise audio render state")
        }
        self.renderState = renderState
    }

    deinit {
        stop()
        CruiseAudioRenderStateDestroy(renderState)
    }

    func setGain(_ gain: Float) {
        CruiseAudioRenderStateSetGain(renderState, AudioVolumeMath.clampedGain(gain))
    }

    func start() throws {
        guard #available(macOS 14.2, *) else {
            throw AudioVolumeRouteError(operation: "Process audio taps require macOS 14.2 or later", status: -1)
        }

        do {
            try createTap()
            try createAggregateDevice()
            try startIO()
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if started, let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            started = false
        }
        if let ioProcID {
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        ioBlock = nil
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if #available(macOS 14.2, *), tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    @available(macOS 14.2, *)
    private func createTap() throws {
        let description = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        description.name = "Cruise Control · \(target.title)"
        description.uuid = UUID()
        description.isPrivate = true
        description.deviceUID = outputUID
        description.stream = 0
        // Probe taps never mute. The app is only intercepted after real samples prove
        // capture permission is active, so a denied TCC grant cannot silence it.
        description.muteBehavior = stage == .active ? .muted : .unmuted

        let status = AudioHardwareCreateProcessTap(description, &tapID)
        try AudioVolumeHAL.check(status, operation: "Create process audio tap")
    }

    private func createAggregateDevice() throws {
        let tapUID = try AudioVolumeHAL.stringProperty(tapID, selector: kAudioTapPropertyUID)
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Cruise · \(target.title)",
            kAudioAggregateDeviceUIDKey: "com.ilovespectra.cruisecontrol.audio.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUID,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        let status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID)
        try AudioVolumeHAL.check(status, operation: "Create private audio route")
        try AudioVolumeHAL.waitUntilAlive(aggregateID)
    }

    private func startIO() throws {
        let tapFormat = try AudioVolumeHAL.streamFormat(tapID, selector: kAudioTapPropertyFormat)
        let outputFormat = try AudioVolumeHAL.aggregateOutputFormat(aggregateID)
        guard tapFormat.isFloat32, outputFormat.isFloat32,
              tapFormat.mChannelsPerFrame > 0, outputFormat.mChannelsPerFrame > 0 else {
            throw AudioVolumeRouteError(
                operation: "This audio device does not expose a supported 32-bit float stream",
                status: kAudioHardwareUnsupportedOperationError
            )
        }

        let inputBufferOffset = try AudioVolumeHAL.inputBufferCount(for: outputDeviceID)
        let state = renderState
        let stage = stage
        let block: AudioDeviceIOBlock = { _, inputData, _, outputData, _ in
            Self.render(input: inputData,
                        inputFormat: tapFormat,
                        inputBufferOffset: inputBufferOffset,
                        output: outputData,
                        outputFormat: outputFormat,
                        state: state,
                        probeOnly: stage == .probe)
        }
        ioBlock = block

        var createdProc: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(&createdProc, aggregateID, nil, block)
        try AudioVolumeHAL.check(createStatus, operation: "Create audio render callback")
        ioProcID = createdProc
        let startStatus = AudioDeviceStart(aggregateID, createdProc)
        try AudioVolumeHAL.check(startStatus, operation: "Start private audio route")
        started = true
    }

    /// Realtime callback: only fixed buffers, atomics and float math; no allocation,
    /// logging, locks, file I/O or UI work. Probe mode reads a peak only and writes
    /// silence into the private aggregate while the original app path remains audible.
    private static func render(input: UnsafePointer<AudioBufferList>,
                               inputFormat: AudioStreamBasicDescription,
                               inputBufferOffset: Int,
                               output: UnsafeMutablePointer<AudioBufferList>,
                               outputFormat: AudioStreamBasicDescription,
                               state: OpaquePointer,
                               probeOnly: Bool) {
        let inputList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputList = UnsafeMutableAudioBufferListPointer(output)
        for buffer in outputList {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }

        let inputChannels = Int(inputFormat.mChannelsPerFrame)
        let outputChannels = Int(outputFormat.mChannelsPerFrame)
        let inputNonInterleaved = inputFormat.isNonInterleaved
        let outputNonInterleaved = outputFormat.isNonInterleaved
        let inputBuffersNeeded = inputNonInterleaved ? inputChannels : 1
        let outputBuffersNeeded = outputNonInterleaved ? outputChannels : 1
        guard inputList.count >= inputBufferOffset + inputBuffersNeeded,
              outputList.count >= outputBuffersNeeded,
              inputFormat.mBytesPerFrame > 0,
              outputFormat.mBytesPerFrame > 0,
              let firstInput = inputList[inputBufferOffset].mData,
              let firstOutput = outputList[0].mData else { return }

        let inputFrames = Int(inputList[inputBufferOffset].mDataByteSize) / Int(inputFormat.mBytesPerFrame)
        let outputFrames = Int(outputList[0].mDataByteSize) / Int(outputFormat.mBytesPerFrame)
        let frameCount = min(inputFrames, outputFrames)
        guard frameCount > 0 else { return }

        @inline(__always)
        func inputSample(channel: Int, frame: Int) -> Float {
            if inputNonInterleaved {
                guard let data = inputList[inputBufferOffset + channel].mData else { return 0 }
                return data.assumingMemoryBound(to: Float.self)[frame]
            }
            return firstInput.assumingMemoryBound(to: Float.self)[frame * inputChannels + channel]
        }

        var peak: Float = 0
        for frame in 0..<frameCount {
            for channel in 0..<inputChannels {
                peak = max(peak, abs(inputSample(channel: channel, frame: frame)))
            }
        }
        if peak > 0.00001 { CruiseAudioRenderStateSetReceivedAudio(state) }
        guard !probeOnly else { return }

        let gain = AudioVolumeMath.clampedGain(CruiseAudioRenderStateGetGain(state))
        @inline(__always)
        func writeSample(_ sample: Float, channel: Int, frame: Int) {
            let value = AudioVolumeMath.scaledSample(sample, gain: gain)
            if outputNonInterleaved {
                guard let data = outputList[channel].mData else { return }
                data.assumingMemoryBound(to: Float.self)[frame] = value
            } else {
                firstOutput.assumingMemoryBound(to: Float.self)[frame * outputChannels + channel] = value
            }
        }

        for channel in 0..<outputChannels {
            let sourceChannel = channel % inputChannels
            for frame in 0..<frameCount {
                writeSample(inputSample(channel: sourceChannel, frame: frame), channel: channel, frame: frame)
            }
        }
    }
}

private struct AudioVolumeRouteError: LocalizedError {
    let operation: String
    let status: OSStatus

    var errorDescription: String? { "\(operation) (Core Audio status \(status))" }
}

private enum AudioVolumeHAL {
    struct OutputDevice {
        let id: AudioObjectID
        let uid: String
        let name: String
    }

    struct ProcessObject {
        let objectID: AudioObjectID
        let processID: pid_t
        let bundleIdentifier: String
    }

    static func defaultOutputDevice() throws -> OutputDevice {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objectID)
        try check(status, operation: "Read default output device")
        guard objectID != AudioObjectID(kAudioObjectUnknown) else {
            throw AudioVolumeRouteError(operation: "No default output device is available", status: kAudioHardwareBadDeviceError)
        }
        return OutputDevice(id: objectID,
                            uid: try stringProperty(objectID, selector: kAudioDevicePropertyDeviceUID),
                            name: try stringProperty(objectID, selector: kAudioObjectPropertyName))
    }

    static func processObjects() throws -> [ProcessObject] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = propertyAddress(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size)
        try check(sizeStatus, operation: "List app audio processes")
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }

        var ids = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        let readStatus = ids.withUnsafeMutableBufferPointer { buffer in
            AudioObjectGetPropertyData(system, &address, 0, nil, &size, buffer.baseAddress!)
        }
        try check(readStatus, operation: "Read app audio processes")

        return ids.compactMap { id in
            guard let bundle = try? stringProperty(id, selector: kAudioProcessPropertyBundleID),
                  let pid = try? processID(id) else { return nil }
            return ProcessObject(objectID: id, processID: pid, bundleIdentifier: bundle)
        }
    }

    static func processID(_ objectID: AudioObjectID) throws -> pid_t {
        var address = propertyAddress(kAudioProcessPropertyPID)
        var pid: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &pid)
        try check(status, operation: "Read app process ID")
        return pid
    }

    static func stringProperty(_ objectID: AudioObjectID,
                               selector: AudioObjectPropertySelector) throws -> String {
        var address = propertyAddress(selector)
        var value = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer)
        }
        try check(status, operation: "Read Core Audio string property")
        return value as String
    }

    static func streamFormat(_ objectID: AudioObjectID,
                             selector: AudioObjectPropertySelector) throws -> AudioStreamBasicDescription {
        var address = propertyAddress(selector)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &format)
        try check(status, operation: "Read audio stream format")
        return format
    }

    static func aggregateOutputFormat(_ deviceID: AudioObjectID) throws -> AudioStreamBasicDescription {
        let streams = try streamIDs(deviceID, scope: kAudioDevicePropertyScopeOutput)
        guard let first = streams.first else {
            throw AudioVolumeRouteError(operation: "The output device has no output stream", status: kAudioHardwareUnsupportedOperationError)
        }
        return try streamFormat(first, selector: kAudioStreamPropertyVirtualFormat)
    }

    static func inputBufferCount(for deviceID: AudioObjectID) throws -> Int {
        var address = propertyAddress(kAudioDevicePropertyStreamConfiguration,
                                      scope: kAudioDevicePropertyScopeInput)
        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
        try check(sizeStatus, operation: "Read output-device input layout")
        guard size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let readStatus = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw)
        try check(readStatus, operation: "Read output-device input layout")
        let buffers = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.count
    }

    static func waitUntilAlive(_ deviceID: AudioObjectID) throws {
        var address = propertyAddress(kAudioDevicePropertyDeviceIsAlive)
        for _ in 0..<30 {
            var alive: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &alive)
            if status == noErr && alive != 0 { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw AudioVolumeRouteError(operation: "The private audio route did not become ready", status: kAudioHardwareBadDeviceError)
    }

    private static func streamIDs(_ deviceID: AudioObjectID,
                                  scope: AudioObjectPropertyScope) throws -> [AudioObjectID] {
        var address = propertyAddress(kAudioDevicePropertyStreams, scope: scope)
        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
        try check(sizeStatus, operation: "List aggregate streams")
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var ids = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        let readStatus = ids.withUnsafeMutableBufferPointer { buffer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, buffer.baseAddress!)
        }
        try check(readStatus, operation: "Read aggregate streams")
        return ids
    }

    static func check(_ status: OSStatus, operation: String) throws {
        guard status == noErr else { throw AudioVolumeRouteError(operation: operation, status: status) }
    }

    private static func propertyAddress(_ selector: AudioObjectPropertySelector,
                                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }
}

private extension AudioStreamBasicDescription {
    var isFloat32: Bool {
        mFormatID == kAudioFormatLinearPCM
            && (mFormatFlags & kAudioFormatFlagIsFloat) != 0
            && mBitsPerChannel == 32
    }

    var isNonInterleaved: Bool {
        (mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
    }
}
