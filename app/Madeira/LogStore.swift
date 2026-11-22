import Foundation
import SwiftUI
import Darwin

final class LogStore: ObservableObject {
    static let shared = LogStore()

    /// One row per unique signature — semantically identical events bucket here.
    @Published var entries: [LogEntry] = []

    private let logFileURL: URL
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    // Tail-file reader (background)
    private var tail: LogTail?
    // madeira-bcd: thermal transitions, logged whether or not the HUD is shown
    private var thermalObserver: NSObjectProtocol?
    // Signature → index into `entries` so we can update in O(1)
    private var sigToIndex: [String: Int] = [:]
    // Lock for sigToIndex + pending mutations
    private let stateLock = NSLock()
    // Pending batched diffs to apply on main thread
    private var pendingNew: [LogEntry] = []
    private var pendingUpdates: [(index: Int, count: Int, lastRaw: String, lastTimestamp: Date)] = []
    private var flushTimer: Timer?
    private var displaySuppressed = false

    func setDisplayActive(_ active: Bool) {
        let disabled = !MadeiraConfig.flag("MADEIRA_UI_LOG_IDLE")
        let suppress = !active && !disabled
        stateLock.lock(); displaySuppressed = suppress; stateLock.unlock()
        tail?.setDisplayPaused(suppress)
        fputs("[ui-log-idle] display parsing suspended=\(suppress ? 1 : 0); file capture unchanged\n", stderr)
    }

    /// When true, UI flushes slowly (1.5s) instead of normally (200ms). Used
    /// during Wine runtime so SwiftUI list churn doesn't drag frame pacing.
    /// Tail reader keeps running either way — pending entries just batch up
    /// longer before reaching @Published. Setting this restarts the timer.
    var uiPaused = false {
        didSet { if oldValue != uiPaused { rescheduleFlush() } }
    }

    // Flush intervals (seconds)
    private let fastFlushInterval: TimeInterval = 0.2
    private let slowFlushInterval: TimeInterval = 1.5

    // Cap on distinct entries kept in memory
    private let maxEntries = 200

    struct LogEntry: Identifiable {
        let id = UUID()
        var firstTimestamp: Date
        var lastTimestamp: Date
        var signature: String
        var lastRaw: String
        var count: Int
        var level: Level

        enum Level: String {
            case info = "INFO"
            case success = "OK"
            case error = "ERR"
            case debug = "DBG"
        }
    }

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        logFileURL = docs.appendingPathComponent("madeira-log.txt")

        // ml601: ROTATE, don't destroy.
        //
        // This used to truncate unconditionally, so relaunching the app before
        // pulling wiped the previous run. That cost us the first run in which
        // Steam's Library view actually rendered content (2026-08-09) — a result
        // we had never seen before and could not get back. Runs here are
        // expensive and often not reproducible on demand, so the previous log is
        // worth one file's worth of disk.
        //
        // Pull the previous run with the usual devicectl command, substituting
        // Documents/madeira-log.prev.txt for Documents/madeira-log.txt.
        let prevLogURL = docs.appendingPathComponent("madeira-log.prev.txt")
        if FileManager.default.fileExists(atPath: logFileURL.path) {
            try? FileManager.default.removeItem(at: prevLogURL)
            try? FileManager.default.moveItem(at: logFileURL, to: prevLogURL)
        }
        try? "".write(to: logFileURL, atomically: true, encoding: .utf8)
        // A session that never returned to the library (a crash, Force close) wrote
        // no madeira-summary.txt; summarize it now. A launch without a session
        // leaves the last summary in place (LogSummary.write).
        if FileManager.default.fileExists(atPath: prevLogURL.path) {
            LogSummary.writeLater(from: prevLogURL, source: "madeira-log.prev.txt (the previous run)")
        }
        // Madeira swiped away from the app switcher ends without returning to the
        // library: summarize the session so far whenever Madeira goes to the background.
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                               object: nil, queue: .main) { [logFileURL] _ in
            var task = UIBackgroundTaskIdentifier.invalid
            task = UIApplication.shared.beginBackgroundTask(withName: "madeira-summary") {
                guard task != .invalid else { return }
                let finished = task; task = .invalid
                UIApplication.shared.endBackgroundTask(finished)
            }
            DispatchQueue.global(qos: .utility).async {
                LogSummary.write(from: logFileURL, source: "madeira-log.txt (this session, up to when Madeira went to the background)")
                DispatchQueue.main.async {
                    guard task != .invalid else { return }
                    let finished = task; task = .invalid
                    UIApplication.shared.endBackgroundTask(finished)
                }
            }
        }

        // Start batch flush timer on main thread. Interval depends on uiPaused.
        DispatchQueue.main.async {
            self.rescheduleFlush()
        }

        // Tail the log file. Reads everything Wine + DXMT + FEX write via
        // dprintf(STDERR_FILENO, ...), wine_log_write, etc.
        tail = LogTail(path: logFileURL.path) { [weak self] line in
            self?.handleRawLine(line)
        }
        tail?.start()

        // Also accept programmatic logs from Swift/ObjC code via existing
        // C callbacks (kept for compatibility with code that doesn't write
        // to the log file).
        wine_set_ui_log_callback { cStr in
            guard let cStr = cStr else { return }
            let message = String(cString: cStr)
            LogStore.shared.handleRawLine(message)
        }
        jit_set_log_callback { cStr in
            guard let cStr = cStr else { return }
            let message = String(cString: cStr)
            LogStore.shared.handleRawLine(message)
            // ml359: also persist — jit_log lines (incl. the [no-footprint]
            // verdict) previously reached only the UI view, which dies with
            // the app; pulled logs never contained them.
            LogStore.shared.appendToFile(message, level: .info)
        }

        // madeira-bcd: the HUD logged thermal transitions only while it was on
        // screen, so build 442's GTA V gameplay at ~34 fps with the P cores at
        // 1.5-1.7 GHz ([xp] GHz P=, 3.8-4.1 at the start) could not say whether
        // the phone was throttling. Log every transition, with the time.
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { _ in
            let process = ProcessInfo.processInfo
            LogStore.shared.log("[thermal] now \(DeviceLoadDiagnostics.thermalName(process.thermalState)) "
                                + "(low-power=\(process.isLowPowerModeEnabled ? 1 : 0))")
        }

        // DeckRT: the M0 measurement probe (see the DeckRTProbe section below).
        DeckRTProbe.boot()
    }

    /// Documents/madeira-log.txt, this run's log.
    var logURL: URL { logFileURL }

    /// Keeps this session's log under the program's name as well:
    /// Documents/logs/<exe>-<yyyy-MM-dd_HH-mm-ss>.txt, e.g.
    /// Crysis64.exe-2026-09-26_12-05-00.txt, so a run can be found and sent
    /// without renaming madeira-log.txt by hand.
    ///
    /// A hard link, not a copy: Wine, wineserver and the app all append to
    /// madeira-log.txt through their own descriptors right up to a crash, and
    /// both names see every line. The next app launch rotates madeira-log.txt
    /// to a new file, which leaves this name holding the finished run. Keeps
    /// the newest `keep` runs. A Steam game started through Madeira Dock is
    /// named by ntdll instead (process_ios.c, madeira_steam_session_log).
    func startSessionLog(program: String, keep: Int = 40) {
        let fm = FileManager.default
        let dir = logFileURL.deletingLastPathComponent().appendingPathComponent("logs")
        try? fm.createDirectory(atPath: dir.path, withIntermediateDirectories: true, attributes: nil)
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let safe = program.map { "/\\:*?\"<>|".contains($0) ? "_" : $0 }
        let url = dir.appendingPathComponent(String(safe) + "-" + stamp.string(from: Date()) + ".txt")
        do {
            try fm.linkItem(at: logFileURL, to: url)
            log("Session log: logs/\(url.lastPathComponent)")
        } catch {
            log("Session log: could not link logs/\(url.lastPathComponent) (\(error.localizedDescription))", level: .error)
        }
        let runs = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "txt" }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }
        for old in runs.dropFirst(keep) { try? fm.removeItem(at: old) }
    }

    /// Once Wine points stderr at madeira-log.txt, the app's own log lines are
    /// written through stderr too (appendToFile); 0 keeps a per-call file handle.
    private static let viaStderr = MadeiraConfig.flag("MADEIRA_LOG_VIA_STDERR")

    /// Is fd 2 the log file itself (same device and inode)?
    private static func stderrIsFile(_ path: String) -> Bool {
        var err = stat(), file = stat()
        guard fstat(STDERR_FILENO, &err) == 0, stat(path, &file) == 0 else { return false }
        return err.st_dev == file.st_dev && err.st_ino == file.st_ino
    }

    /// Public entry point for Swift-side logging (kept for ContentView calls)
    func log(_ message: String, level: LogEntry.Level = .info) {
        handleRawLine(message)
        // Also append to the file so it shows up in pulled logs alongside Wine output
        appendToFile(message, level: level)
    }

    /// Called from tail-file callback (background queue) or C callback.
    private func handleRawLine(_ raw: String) {
        JITPoolMeter.note(raw)   // the overlay's JIT memory, also while the live log is hidden
        stateLock.lock(); let suppressed = displaySuppressed; stateLock.unlock()
        if suppressed { return }
        // Filter out lines we never want in UI (excessive byte spam, etc.)
        if shouldDropLine(raw) { return }

        let (sig, level) = LogPattern.canonicalize(raw)
        if sig.isEmpty { return }

        let now = Date()
        stateLock.lock()
        if let idx = sigToIndex[sig] {
            pendingUpdates.append((idx, 1, raw, now))
        } else {
            // Reserve an index slot — actual append happens on flush.
            // We can't know the true index here without holding entries,
            // so we'll resolve indices during flush.
            let entry = LogEntry(
                firstTimestamp: now,
                lastTimestamp: now,
                signature: sig,
                lastRaw: raw,
                count: 1,
                level: level
            )
            pendingNew.append(entry)
            // Map sig → -1 sentinel so subsequent same-sig lines from this
            // batch get treated as new too (will be merged during flush).
            sigToIndex[sig] = -1
        }
        stateLock.unlock()
    }

    /// Filter rules for raw lines. Anything that returns true is dropped
    /// before signature canonicalization.
    private func shouldDropLine(_ raw: String) -> Bool {
        // Drop Wine's `trace:file:WriteFile` / `NtWriteFile` / `SysCall` chatter
        // — these are amplified by our own logging path (every dprintf is
        // dup2'd to the log fd, which then goes through Wine's file trace).
        // The signal lives in the original log lines, not these wrappers.
        if raw.contains("trace:file:WriteFile") { return true }
        if raw.contains("trace:file:NtWriteFile") { return true }
        if raw.contains("SysCall  NtWriteFile") { return true }
        if raw.contains("SysCall  NtQueryPerformanceCounter") { return true }
        if raw.contains("SysRet   NtWriteFile") { return true }
        if raw.contains("SysRet   NtQueryPerformanceCounter") { return true }
        // Drop verbose IR dispatch (already silenced in FEX, but defensive)
        if raw.contains("[iOS] Arm64JIT: Dispatching Op") { return true }
        if raw.contains("[iOS] Decoder:") { return true }
        return false
    }

    /// Reschedule flush timer with the appropriate interval for the current
    /// uiPaused state. Always runs on main RunLoop.
    private func rescheduleFlush() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.flushTimer?.invalidate()
            let interval = self.uiPaused ? self.slowFlushInterval : self.fastFlushInterval
            self.flushTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                self?.flushPending()
            }
        }
    }

    /// Apply pending changes to @Published entries (main thread).
    /// Runs on main thread, interval determined by uiPaused.
    private func flushPending() {

        stateLock.lock()
        let newBatch = pendingNew
        let updateBatch = pendingUpdates
        pendingNew.removeAll(keepingCapacity: true)
        pendingUpdates.removeAll(keepingCapacity: true)
        stateLock.unlock()

        if newBatch.isEmpty && updateBatch.isEmpty { return }

        // Apply updates (existing entries: bump count, update timestamp)
        for u in updateBatch {
            // Some indices may have been the -1 sentinel — match by signature
            if u.index < 0 || u.index >= entries.count { continue }
            entries[u.index].count += u.count
            entries[u.index].lastTimestamp = u.lastTimestamp
            entries[u.index].lastRaw = u.lastRaw
        }

        // Apply news: dedup against in-batch sigs (so if 5 same-sig lines
        // arrived in one batch, we get one entry with count=5)
        var batchSigToBatchIdx: [String: Int] = [:]
        var collapsedNew: [LogEntry] = []
        for var entry in newBatch {
            if let i = batchSigToBatchIdx[entry.signature] {
                collapsedNew[i].count += 1
                collapsedNew[i].lastTimestamp = entry.lastTimestamp
                collapsedNew[i].lastRaw = entry.lastRaw
            } else {
                // Or against the live entries list (race with this same flush)
                if let existing = entries.firstIndex(where: { $0.signature == entry.signature }) {
                    entries[existing].count += 1
                    entries[existing].lastTimestamp = entry.lastTimestamp
                    entries[existing].lastRaw = entry.lastRaw
                    continue
                }
                batchSigToBatchIdx[entry.signature] = collapsedNew.count
                collapsedNew.append(entry)
            }
        }

        // Append new entries. sigToIndex is read/written by handleRawLine on
        // Wine threads, so every mutation of it here MUST hold stateLock —
        // the unlocked writes corrupted the dictionary and threw an
        // NSException on the wineserver thread (2026-07-03).
        stateLock.lock()
        for entry in collapsedNew {
            entries.append(entry)
            let newIndex = entries.count - 1
            sigToIndex[entry.signature] = newIndex
        }

        // Reindex if we evicted
        if entries.count > maxEntries {
            // Drop oldest by lastTimestamp
            entries.sort { $0.lastTimestamp < $1.lastTimestamp }
            let drop = entries.count - maxEntries
            let removed = entries.prefix(drop).map { $0.signature }
            entries.removeFirst(drop)
            for sig in removed { sigToIndex.removeValue(forKey: sig) }
            // Reindex remaining
            sigToIndex.removeAll()
            for (i, e) in entries.enumerated() { sigToIndex[e.signature] = i }
            // Sort back to insertion order (by firstTimestamp)
            entries.sort { $0.firstTimestamp < $1.firstTimestamp }
            sigToIndex.removeAll()
            for (i, e) in entries.enumerated() { sigToIndex[e.signature] = i }
        }
        stateLock.unlock()
    }

    /// Manual clear (used by UI button)
    func clear() {
        stateLock.lock()
        sigToIndex.removeAll()
        pendingNew.removeAll()
        pendingUpdates.removeAll()
        stateLock.unlock()
        entries.removeAll()
        try? "".write(to: logFileURL, atomically: true, encoding: .utf8)
    }

    /// Write to file (called from `log()` for Swift-side messages so they
    /// land in the file alongside Wine/FEX output, picked up by the tail
    /// reader).
    private func appendToFile(_ message: String, level: LogEntry.Level = .info) {
        let line = "[\(dateFormatter.string(from: Date()))] [\(level.rawValue)] \(message)\n"
        // Once Wine has pointed stderr at this same file (O_APPEND,
        // WineProcessBridge), write through it. Device logs kept not
        // one line from here after Wine started, while every stderr line
        // arrived; the per-call handle below is the only difference, so the
        // one writer that demonstrably works is used. The tail reader already
        // shows stderr lines in the UI, exactly as it showed this file before.
        // MADEIRA_LOG_VIA_STDERR=0 keeps the per-call handle.
        if Self.viaStderr && Self.stderrIsFile(logFileURL.path) {
            fputs(line, stderr)
            return
        }
        if let data = line.data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: logFileURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        }
    }
}

// MARK: - DeckRT measurement probe
//
// DeckRT's M0 measurement overlay (docs/measurements/M0.md). It writes one JSON
// object per line to Documents/deckrt/measure.jsonl so the host script
// (tools/measure.sh) can pull it with `xcrun devicectl device copy from` and
// report launch-to-first-frame, phys_footprint peak and thermal transitions
// without attaching a debugger. It changes no gameplay behaviour: the sampler is
// a main-queue timer (0.25 s while a launch is pending, then 2 s), and writes are
// append-only on a utility queue. It is DeckRT's own addition to the Madeira
// fork; upstream does not have it.

enum DeckRTProbe {
    private static let schemaVersion = 1

    private static let ioQueue = DispatchQueue(label: "deckrt.probe.io", qos: .utility)

    private static var timer: DispatchSourceTimer?
    private static var fileHandle: FileHandle?

    private static var sessionID: String?
    private static var sessionTitle = ""
    private static var sessionStart = Date()
    private static var frameBaseline: UInt64 = 0
    private static var lastFrames: UInt64 = 0
    private static var lastTick = Date()
    private static var sawFirstFrame = false
    private static var launchSlowNoted = false
    private static var interval: Double = 0.25
    private static var peakRSS = 0
    private static var peakVirtual = 0
    private static var thermalWorst = 0
    private static var sampleSeq = 0

    private static func fileURL() -> URL? {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let dir = docs.appendingPathComponent("deckrt", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("measure.jsonl")
    }

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func machine() -> String {
        var size = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.machine", &value, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: value)
    }

    /// phys_footprint is the number jetsam judges the app on (FPSOverlay's
    /// `readFootprintMB` reads the same task_info field); virtual_size is the
    /// mapped address space, which is what grows when the FEX arena and JIT pool
    /// are mapped.
    private static func vm() -> (rssMB: Int, virtMB: Int) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { raw in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), raw, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return (0, 0) }
        return (Int(info.phys_footprint / 1_048_576), Int(info.virtual_size / 1_048_576))
    }

    private static func jsonInt(_ value: Int?) -> Any {
        value.map { $0 as Any } ?? NSNull()
    }

    private static func write(_ event: [String: Any]) {
        guard let url = fileURL() else { return }
        var payload = event
        payload["schema"] = schemaVersion
        payload["at"] = iso(Date())
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return }
        ioQueue.async {
            if fileHandle == nil {
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                fileHandle = try? FileHandle(forWritingTo: url)
                fileHandle?.seekToEnd()
            }
            guard let handle = fileHandle else { return }
            var line = data
            line.append(0x0A)
            try? handle.write(contentsOf: line)
        }
    }

    /// Called once when the app's log store is built, i.e. at app launch.
    static func boot() {
        let (rss, virt) = vm()
        write([
            "event": "app_boot",
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
            "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?",
            "ios": UIDevice.current.systemVersion,
            "model": machine(),
            "rss_mb": rss,
            "virtual_mb": virt,
            "thermal": ProcessInfo.processInfo.thermalState.rawValue,
            "extended_va": checkAppEntitlement("com.apple.developer.kernel.extended-virtual-addressing"),
            "increased_memory": checkAppEntitlement("com.apple.developer.kernel.increased-memory-limit"),
            "debugger": isDebuggerAttached()
        ])
    }

    /// Called from `LibraryController.begin`, immediately after `launchStarted`.
    /// That is the tap: the elapsed time to `first_frame` is the plan's first-frame metric.
    static func sessionBegin(title: String, steamID: Int?, bits: Int, entryID: String) {
        sessionID = UUID().uuidString
        sessionTitle = title
        sessionStart = Date()
        frameBaseline = madeira_shown_frame_count()
        lastFrames = frameBaseline
        lastTick = sessionStart
        sawFirstFrame = false
        launchSlowNoted = false
        interval = 0.25
        sampleSeq = 0
        let (rss, virt) = vm()
        peakRSS = rss
        peakVirtual = virt
        thermalWorst = ProcessInfo.processInfo.thermalState.rawValue
        let pool = JITPoolMeter.current
        write([
            "event": "session_begin",
            "session": sessionID ?? "",
            "game": title,
            "steam_app_id": jsonInt(steamID),
            "bits": bits,
            "entry": entryID,
            "rss_mb": rss,
            "virtual_mb": virt,
            "thermal": thermalWorst,
            "jit_pool_mb": jsonInt(pool.sizeMB),
            "jit_pool_used": Int(pool.used),
            "jit_pool_exhausted": pool.exhausted,
            "frames": frameBaseline
        ])
        startTimer(interval)
    }

    /// Called from `LibraryController.finish`.
    static func sessionEnd(reason: String) {
        guard let sid = sessionID else { return }
        timer?.cancel()
        timer = nil
        let (rss, virt) = vm()
        write([
            "event": "session_end",
            "session": sid,
            "game": sessionTitle,
            "reason": reason,
            "elapsed_ms": Int(Date().timeIntervalSince(sessionStart) * 1000),
            "rss_mb": rss,
            "virtual_mb": virt,
            "peak_rss_mb": peakRSS,
            "peak_virtual_mb": peakVirtual,
            "thermal_worst": thermalWorst,
            "saw_first_frame": sawFirstFrame
        ])
        sessionID = nil
    }

    private static func startTimer(_ seconds: Double) {
        timer?.cancel()
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + seconds, repeating: seconds, leeway: .milliseconds(50))
        source.setEventHandler { tick() }
        source.resume()
        timer = source
    }

    private static func tick() {
        let now = Date()
        let frames = madeira_shown_frame_count()
        let elapsed = now.timeIntervalSince(lastTick)
        let frameDelta = frames &- lastFrames
        let (rss, virt) = vm()
        if rss > peakRSS { peakRSS = rss }
        if virt > peakVirtual { peakVirtual = virt }
        let thermal = ProcessInfo.processInfo.thermalState.rawValue
        if thermal > thermalWorst { thermalWorst = thermal }
        lastFrames = frames
        lastTick = now

        guard let sid = sessionID else { return }

        let sinceBegin = now.timeIntervalSince(sessionStart)
        if !sawFirstFrame, frames >= frameBaseline + 1 {
            sawFirstFrame = true
            write([
                "event": "first_frame",
                "session": sid,
                "game": sessionTitle,
                "elapsed_ms": Int(sinceBegin * 1000),
                "sampling_ms": Int(interval * 1000)
            ])
            interval = 2.0
            startTimer(interval)
        } else if !sawFirstFrame, !launchSlowNoted, sinceBegin > 30 {
            launchSlowNoted = true
            write([
                "event": "launch_slow",
                "session": sid,
                "game": sessionTitle,
                "elapsed_ms": Int(sinceBegin * 1000)
            ])
        }

        sampleSeq += 1
        write([
            "event": "sample",
            "session": sid,
            "n": sampleSeq,
            "rss_mb": rss,
            "virtual_mb": virt,
            "thermal": thermal,
            "frames": frames,
            "fps": elapsed > 0 ? Double(frameDelta) / elapsed : 0,
            "elapsed_ms": Int(sinceBegin * 1000)
        ])
    }
}
