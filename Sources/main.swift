import SwiftUI

// MARK: - Paths & identity
let HOME = FileManager.default.homeDirectoryForCurrentUser.path
let ME = NSUserName()                                   // current user — no hardcoding
let SUPPORT = HOME + "/Library/Application Support/SidecarTravel"
let ARMED = SUPPORT + "/armed"
let DEVICE_FILE = SUPPORT + "/device.txt"
let AGENT_LABEL = "io.github.sidecartravel.plug"
let AGENT_PLIST = HOME + "/Library/LaunchAgents/\(AGENT_LABEL).plist"
let APPLE_VID = 1452                                    // 0x05AC, Apple

// Headless screen keeper
let KEEP_FILE = SUPPORT + "/keepscreen"
let KEEP_LOG = SUPPORT + "/screen.log"
let SCREEN_NAME = "TravelScreen"
let LOGIN_LABEL = "io.github.sidecartravel.app"
let LOGIN_PLIST = HOME + "/Library/LaunchAgents/\(LOGIN_LABEL).plist"
let BG_FLAG = "--background"
let FIXUP_FLAG = "--fixup"                              // post-connect: break mirror + pin Sidecar res

// ctl.js lives in the app bundle; a copy is installed to SUPPORT for the launch agent.
let CTL_BUNDLE = Bundle.main.path(forResource: "ctl", ofType: "js") ?? ""
let CTL_INSTALLED = SUPPORT + "/ctl.js"
let PLUG_INSTALLED = SUPPORT + "/on-plug.sh"

func L(_ key: String) -> String { NSLocalizedString(key, comment: "") }

// MARK: - Shell helpers
@discardableResult
func sh(_ cmd: String) -> String {
    let p = Process(); p.launchPath = "/bin/bash"; p.arguments = ["-lc", cmd]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
    try? p.run(); p.waitUntilExit()
    let d = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

func osaAdmin(_ inner: String) -> String {
    let esc = inner.replacingOccurrences(of: "\"", with: "\\\"")
    return sh("/usr/bin/osascript -e 'do shell script \"\(esc)\" with administrator privileges'")
}

func ctl(_ args: String) -> String {
    sh("/usr/bin/osascript -l JavaScript '\(CTL_BUNDLE)' \(args) 2>/dev/null")
}

func ensureSupportDir() { try? FileManager.default.createDirectory(atPath: SUPPORT, withIntermediateDirectories: true) }

// MARK: - Sidecar device list parsing
// ctl.js list -> devices=["A","B"] connected=["A"]
func parseList() -> (all: [String], connected: [String]) {
    let s = ctl("list")
    func arr(_ field: String) -> [String] {
        guard let r = s.range(of: "\(field)=", options: []) else { return [] }
        let tail = String(s[r.upperBound...])
        guard let close = tail.range(of: "]") else { return [] }
        let json = String(tail[..<close.upperBound])
        guard let data = json.data(using: .utf8),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return list
    }
    return (arr("devices"), arr("connected"))
}

func savedDevice() -> String {
    if let d = try? String(contentsOfFile: DEVICE_FILE, encoding: .utf8) {
        let t = d.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
    }
    return UserDefaults.standard.string(forKey: "deviceName") ?? ""
}

func setDevice(_ name: String) {
    ensureSupportDir()
    try? name.write(toFile: DEVICE_FILE, atomically: true, encoding: .utf8)
    UserDefaults.standard.set(name, forKey: "deviceName")
}

// MARK: - App state
struct AppState {
    var devices: [String] = []
    var connected: [String] = []
    var device = ""
    var autologin = false
    var armed = false
    var agentLoaded = false
    var keepScreen = false
    var bdAvailable = false
    var physicalCount = 0
    var screenAttached = false
    var loginAgent = false
    var ipadConnected: Bool { !device.isEmpty && connected.contains(device) }
    var ipadVisible: Bool { !device.isEmpty && devices.contains(device) }
}

func readState() -> AppState {
    var s = AppState()
    let l = parseList()
    s.devices = l.all; s.connected = l.connected
    s.device = savedDevice()
    if s.device.isEmpty, let first = l.all.first { s.device = first; setDevice(first) }
    s.autologin = sh("/usr/bin/defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null") == ME
    s.armed = FileManager.default.fileExists(atPath: ARMED)
    s.agentLoaded = sh("/bin/launchctl print gui/$(id -u)/\(AGENT_LABEL) 2>/dev/null | grep -c 'state = '") != "0"
    s.keepScreen = ScreenKeeper.shared.enabled
    s.bdAvailable = bdPath() != nil
    s.physicalCount = s.bdAvailable ? physicalDisplayCount() : onlineDisplays().count
    s.screenAttached = s.bdAvailable && travelScreenAttached()
    s.loginAgent = loginAgentInstalled()
    return s
}

// MARK: - Background trigger (LaunchAgent) install/remove
// Detect the connected iPad's USB product id so the IOKit match is precise;
// fall back to vendor-only matching (still safe: on-plug.sh guards on device name + armed flag).
func detectIPadProductID() -> Int? {
    let out = sh("/usr/sbin/system_profiler SPUSBDataType 2>/dev/null")
    // crude scan: find an entry that looks like an iPad with a Product ID
    let lines = out.components(separatedBy: "\n")
    var lastPID: Int? = nil
    for line in lines {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("Product ID:") {
            let hex = t.replacingOccurrences(of: "Product ID:", with: "").trimmingCharacters(in: .whitespaces)
            if hex.hasPrefix("0x"), let v = Int(hex.dropFirst(2), radix: 16) { lastPID = v }
        }
        if t.lowercased().contains("ipad"), let pid = lastPID { return pid }
    }
    return nil
}

func installTrigger() -> String {
    ensureSupportDir()
    // copy ctl.js + write on-plug.sh into SUPPORT so the agent path is stable regardless of .app location
    try? FileManager.default.removeItem(atPath: CTL_INSTALLED)
    try? FileManager.default.copyItem(atPath: CTL_BUNDLE, toPath: CTL_INSTALLED)
    let exe = Bundle.main.executablePath ?? ""
    let plug = """
    #!/bin/bash
    DIR="$HOME/Library/Application Support/SidecarTravel"
    [ -f "$DIR/armed" ] || exit 0
    DEV=$(cat "$DIR/device.txt" 2>/dev/null)
    [ -z "$DEV" ] && exit 0
    LOG="$DIR/plug.log"
    FIXUP="\(exe)"
    # After connect: break the mirror Sidecar tends to set up and pin the iPad to 960x704.
    fixup() { [ -x "$FIXUP" ] && "$FIXUP" \(FIXUP_FLAG) >> "$LOG" 2>&1; }
    if /usr/bin/osascript -l JavaScript "$DIR/ctl.js" list 2>/dev/null | grep -q "connected=\\[\\"$DEV\\"\\]"; then fixup; exit 0; fi
    echo "$(date '+%F %T') iPad plugged -> connecting" >> "$LOG"
    for i in $(seq 1 30); do
      if /usr/bin/osascript -l JavaScript "$DIR/ctl.js" list 2>/dev/null | grep -q "connected=\\[\\"$DEV\\"\\]"; then
        echo "  connected (try $i)" >> "$LOG"; sleep 1; fixup; exit 0
      fi
      /usr/bin/osascript -l JavaScript "$DIR/ctl.js" connect "$DEV" >/dev/null 2>&1
      sleep 2
    done
    echo "  gave up after 60s" >> "$LOG"
    """
    try? plug.write(toFile: PLUG_INSTALLED, atomically: true, encoding: .utf8)
    sh("/bin/chmod +x '\(PLUG_INSTALLED)'")

    let pid = detectIPadProductID()
    let matchInner: String
    if let pid = pid {
        matchInner = "<key>idVendor</key><integer>\(APPLE_VID)</integer>\n        <key>idProduct</key><integer>\(pid)</integer>"
    } else {
        matchInner = "<key>idVendor</key><integer>\(APPLE_VID)</integer>"
    }
    let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key><string>\(AGENT_LABEL)</string>
      <key>ProgramArguments</key>
      <array><string>\(PLUG_INSTALLED)</string></array>
      <key>LaunchEvents</key>
      <dict>
        <key>com.apple.iokit.matching</key>
        <dict>
          <key>iPadPlug</key>
          <dict>
            <key>IOProviderClass</key><string>IOUSBHostDevice</string>
            \(matchInner)
          </dict>
        </dict>
      </dict>
      <key>ThrottleInterval</key><integer>30</integer>
    </dict>
    </plist>
    """
    try? plist.write(toFile: AGENT_PLIST, atomically: true, encoding: .utf8)
    sh("/bin/launchctl bootout gui/$(id -u)/\(AGENT_LABEL) 2>/dev/null; /bin/launchctl bootstrap gui/$(id -u) '\(AGENT_PLIST)' 2>/dev/null")
    return pid != nil ? "ok-pid" : "ok-vid"
}

func removeTrigger() {
    sh("/bin/launchctl bootout gui/$(id -u)/\(AGENT_LABEL) 2>/dev/null")
    try? FileManager.default.removeItem(atPath: AGENT_PLIST)
}

// MARK: - Headless screen keeper
//
// Without any display attached a Mac has no framebuffer, so screen sharing shows black.
// The fix is a BetterDisplay virtual screen that stands in for the missing monitor.
//
// The hard part is knowing WHEN to do that. An earlier version of this ran on a 5-minute
// timer and blindly re-attached the virtual screen. Every attach is a display
// reconfiguration, so a real monitor plugged into HDMI would re-sync its picture every
// 5 minutes, forever. The timer is gone: we react to display changes instead, and we do
// nothing at all while a physical monitor is present.

let BD_CANDIDATES = ["/usr/local/bin/betterdisplaycli", "/opt/homebrew/bin/betterdisplaycli"]
let SIDECAR_VENDOR: UInt32 = 1633775724                 // 'aapl' — Sidecar/AirPlay displays

func bdPath() -> String? { BD_CANDIDATES.first { FileManager.default.isExecutableFile(atPath: $0) } }

func klog(_ msg: String) {
    let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let line = "\(df.string(from: Date())) \(msg)\n"
    ensureSupportDir()
    if let h = FileHandle(forWritingAtPath: KEEP_LOG) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
    } else {
        try? line.write(toFile: KEEP_LOG, atomically: true, encoding: .utf8)
    }
}

@discardableResult
func bd(_ args: String) -> String {
    guard let cli = bdPath() else { return "" }
    return sh("'\(cli)' \(args) 2>/dev/null")
}

struct BDDevice { let name: String; let type: String; let displayID: CGDirectDisplayID }

// `betterdisplaycli get --identifiers` prints comma-separated JSON objects, not a JSON
// array — wrap it before decoding.
func bdDevices() -> [BDDevice] {
    let out = bd("get --identifiers")
    guard !out.isEmpty, let data = ("[" + out + "]").data(using: .utf8),
          let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else { return [] }
    return arr.map { d in
        BDDevice(name: d["name"] as? String ?? "",
                 type: d["deviceType"] as? String ?? "",
                 displayID: CGDirectDisplayID(Int(d["displayID"] as? String ?? "0") ?? 0))
    }
}

// BD answers the CLI only once it is fully up; "Default Group" always exists when it is.
func bdReady() -> Bool { bdDevices().contains { $0.type == "DisplayGroup" } }

func bdRunning() -> Bool {
    !sh("/usr/bin/pgrep -f 'BetterDisplay.app/Contents/MacOS/BetterDisplay'").isEmpty
}

func onlineDisplays() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    CGGetOnlineDisplayList(16, nil, &count)
    guard count > 0 else { return [] }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetOnlineDisplayList(count, &ids, &count)
    return Array(ids.prefix(Int(count)))
}

// A real monitor = an online display that is neither one of BD's virtual screens nor a
// Sidecar/AirPlay display. If BD isn't ready we can't identify its virtual screens, so its
// screen counts as physical — that errs toward doing nothing, which is the safe direction.
func physicalDisplayCount() -> Int {
    let virtual = Set(bdDevices().filter { $0.type == "VirtualScreen" && $0.displayID != 0 }.map(\.displayID))
    return onlineDisplays().filter { !virtual.contains($0) && CGDisplayVendorNumber($0) != SIDECAR_VENDOR }.count
}

// displayID is 0 while a virtual screen exists but is detached.
func travelScreens() -> [BDDevice] { bdDevices().filter { $0.type == "VirtualScreen" && $0.name == SCREEN_NAME } }
func travelScreenAttached() -> Bool { travelScreens().contains { $0.displayID != 0 } }

// Mirroring a virtual screen onto Sidecar costs ~40% CPU in BD plus ~70% in WindowServer on
// an Intel GPU, and flickers. Keep every display extended instead. No-op if nothing mirrors.
func breakMirror() {
    let ids = onlineDisplays()
    guard ids.count >= 2, ids.contains(where: { CGDisplayMirrorsDisplay($0) != kCGNullDirectDisplay }) else { return }
    var cfg: CGDisplayConfigRef?
    CGBeginDisplayConfiguration(&cfg)
    for id in ids { CGConfigureDisplayMirrorOfDisplay(cfg, id, kCGNullDirectDisplay) }
    let err = CGCompleteDisplayConfiguration(cfg, .permanently)
    klog("broke mirror (err=\(err.rawValue))")
}

// When Sidecar attaches, macOS often picks 1152x720 (16:10) and letterboxes the 4:3 iPad.
// Pin it to 960x704 HiDPI, which fills the panel minus sidebar + Touch Bar. Idempotent;
// no-op if no Sidecar display is present or it's already correct. This is the one thing the
// old auto-connect script did that the connect step alone doesn't, folded into the app.
func pinSidecarResolution() {
    for id in onlineDisplays() where CGDisplayVendorNumber(id) == SIDECAR_VENDOR {
        if let cur = CGDisplayCopyDisplayMode(id), cur.width == 960, cur.height == 704 { continue }
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(id, opts) as? [CGDisplayMode] else { continue }
        let want = modes.filter { $0.width == 960 && $0.height == 704 && $0.isUsableForDesktopGUI() }
        guard let m = want.max(by: { $0.pixelWidth < $1.pixelWidth }) else { continue }
        var cfg: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&cfg)
        CGConfigureDisplayWithDisplayMode(cfg, id, m, nil)
        let err = CGCompleteDisplayConfiguration(cfg, .permanently)
        klog("pinned Sidecar \(m.width)x\(m.height) (err=\(err.rawValue))")
    }
}

// Runs on `--fixup`, invoked by on-plug.sh right after a Sidecar connect.
func runFixup() {
    breakMirror()
    pinSidecarResolution()
}

private func reconfigCallback(_ display: CGDirectDisplayID,
                              _ flags: CGDisplayChangeSummaryFlags,
                              _ userInfo: UnsafeMutableRawPointer?) {
    // Ignore the "about to change" half of every event pair — act on the settled state.
    guard !flags.contains(.beginConfigurationFlag) else { return }
    ScreenKeeper.shared.schedule("display change")
}

final class ScreenKeeper {
    static let shared = ScreenKeeper()
    private let q = DispatchQueue(label: "io.github.sidecartravel.keeper")
    private var pending: DispatchWorkItem?
    private var registered = false
    private var working = false                          // our own attach/detach re-enters the callback

    var enabled: Bool { FileManager.default.fileExists(atPath: KEEP_FILE) }

    func setEnabled(_ on: Bool) {
        ensureSupportDir()
        if on {
            FileManager.default.createFile(atPath: KEEP_FILE, contents: nil)
            klog("keeper enabled")
            start()
            schedule("enabled", delay: 0)
        } else {
            try? FileManager.default.removeItem(atPath: KEEP_FILE)
            klog("keeper disabled")
        }
    }

    func start() {
        guard !registered else { return }
        CGDisplayRegisterReconfigurationCallback(reconfigCallback, nil)
        registered = true
        // Cover boot: BetterDisplay can come up after we do, and that may not raise an event.
        schedule("startup", delay: 5)
    }

    // Display changes arrive in bursts (unplug fires several); collapse them.
    func schedule(_ reason: String, delay: TimeInterval = 3) {
        guard enabled else { return }
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.reconcile(reason) }
        pending = item
        q.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func reconcile(_ reason: String) {
        guard enabled, !working, bdPath() != nil else { return }
        working = true
        defer { working = false }

        if !bdRunning() {
            klog("[\(reason)] BetterDisplay not running -> launching")
            sh("/usr/bin/open -ga BetterDisplay")
        }
        // Never decide anything until BD confirms it is up: asking too early returns an empty
        // list, which used to read as "no virtual screen" and spawn duplicate ghost screens.
        for _ in 0..<30 {
            if bdReady() { break }
            Thread.sleep(forTimeInterval: 2)
        }
        guard bdReady() else {
            klog("[\(reason)] BetterDisplay silent after 60s -> leaving displays alone")
            return
        }

        // A real monitor is doing the job — stay out of the way. This is the branch that
        // makes the app safe to leave switched on at home.
        if physicalDisplayCount() > 0 {
            if travelScreenAttached() {
                klog("[\(reason)] physical monitor present -> detaching \(SCREEN_NAME)")
                bd("set --name=\(SCREEN_NAME) --connected=off")
            }
            return
        }

        // Headless: make sure exactly one virtual screen exists and is attached.
        let existing = travelScreens()
        if existing.count > 1 {
            klog("[\(reason)] \(existing.count) ghost virtual screens -> clearing")
            bd("discard --type=VirtualScreen")
            Thread.sleep(forTimeInterval: 4)
        }
        if travelScreens().isEmpty {
            klog("[\(reason)] no \(SCREEN_NAME) -> creating")
            // 15:11 matches the iPad's native 1920x1408; a 16:9 screen letterboxes on it.
            bd("create --type=VirtualScreen --virtualScreenName=\(SCREEN_NAME) "
               + "--aspectWidth=15 --aspectHeight=11 --useResolutionList=on "
               + "--resolutionList=1920x1408,1440x1056,1020x748")
            Thread.sleep(forTimeInterval: 5)
        }
        if !travelScreenAttached() {
            klog("[\(reason)] \(SCREEN_NAME) detached -> attaching")
            bd("set --name=\(SCREEN_NAME) --connected=on")
            Thread.sleep(forTimeInterval: 4)
        }
        // Resolution is deliberately left alone: when Sidecar is live the iPad dictates
        // scaling, and forcing a mode here would tear the picture on the iPad.
        breakMirror()
    }
}

// MARK: - Run at login
// A LaunchAgent rather than SMAppService: this bundle is ad-hoc signed, and the keeper has
// to be running before anyone can see a screen to launch it by hand.
func loginAgentInstalled() -> Bool { FileManager.default.fileExists(atPath: LOGIN_PLIST) }

func installLoginAgent() {
    let exe = Bundle.main.executablePath ?? ""
    let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key><string>\(LOGIN_LABEL)</string>
      <key>ProgramArguments</key>
      <array><string>\(exe)</string><string>\(BG_FLAG)</string></array>
      <key>RunAtLoad</key><true/>
      <key>KeepAlive</key>
      <dict><key>SuccessfulExit</key><false/></dict>
    </dict>
    </plist>
    """
    try? plist.write(toFile: LOGIN_PLIST, atomically: true, encoding: .utf8)
    sh("/bin/launchctl bootout gui/$(id -u)/\(LOGIN_LABEL) 2>/dev/null; /bin/launchctl bootstrap gui/$(id -u) '\(LOGIN_PLIST)' 2>/dev/null")
}

func removeLoginAgent() {
    sh("/bin/launchctl bootout gui/$(id -u)/\(LOGIN_LABEL) 2>/dev/null")
    try? FileManager.default.removeItem(atPath: LOGIN_PLIST)
}

// MARK: - Views
struct Row: View {
    let label: String; let on: Bool
    var body: some View {
        HStack {
            Circle().fill(on ? Color.green : Color.secondary.opacity(0.4)).frame(width: 9, height: 9)
            Text(label).font(.system(size: 13))
            Spacer()
            Text(on ? L("yes") : L("no")).font(.system(size: 12, weight: .medium))
                .foregroundColor(on ? .primary : .secondary)
        }
    }
}

struct ContentView: View {
    @State var st = readState()
    @State var busy = false

    func refresh() { st = readState() }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "ipad.landscape").font(.system(size: 26))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Sidecar Travel").font(.system(size: 17, weight: .semibold))
                    Text(L("app.subtitle")).font(.system(size: 11)).foregroundColor(.secondary)
                }
            }

            // iPad picker
            HStack {
                Text(L("device.label")).font(.system(size: 13))
                Spacer()
                if st.devices.isEmpty {
                    Text(L("device.none")).font(.system(size: 11)).foregroundColor(.secondary)
                } else {
                    Picker("", selection: Binding(get: { st.device }, set: { setDevice($0); refresh() })) {
                        ForEach(st.devices, id: \.self) { Text($0).tag($0) }
                    }.labelsHidden().frame(maxWidth: 180)
                }
            }

            GroupBox {
                VStack(spacing: 9) {
                    Row(label: L("row.connected"), on: st.ipadConnected)
                    Row(label: L("row.available"), on: st.ipadVisible)
                    Row(label: L("row.trigger"), on: st.agentLoaded)
                }.padding(.vertical, 4)
            }

            Toggle(isOn: Binding(get: { st.autologin }, set: { v in
                busy = true
                DispatchQueue.global().async {
                    if v {
                        let r = osaAdmin("if [ -f /etc/kcpassword ]; then defaults write /Library/Preferences/com.apple.loginwindow autoLoginUser \(ME); echo OK; else echo NOKC; fi")
                        if r.hasSuffix("NOKC") {
                            DispatchQueue.main.async {
                                let a = NSAlert(); a.messageText = L("alert.nokc.title")
                                a.informativeText = String(format: L("alert.nokc.body"), ME)
                                a.alertStyle = .warning; a.runModal()
                            }
                        }
                    } else {
                        _ = osaAdmin("defaults delete /Library/Preferences/com.apple.loginwindow autoLoginUser")
                    }
                    DispatchQueue.main.async { busy = false; refresh() }
                }
            })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(String(format: L("autologin.title"), ME)).font(.system(size: 13, weight: .medium))
                    Text(L("autologin.subtitle")).font(.system(size: 10)).foregroundColor(.secondary)
                }
            }.toggleStyle(.switch)

            Toggle(isOn: Binding(get: { st.armed }, set: { v in
                ensureSupportDir()
                if v { sh("/usr/bin/touch '\(ARMED)'") } else { sh("/bin/rm -f '\(ARMED)'") }
                refresh()
            })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("armed.title")).font(.system(size: 13, weight: .medium))
                    Text(L("armed.subtitle")).font(.system(size: 10)).foregroundColor(.secondary)
                }
            }.toggleStyle(.switch)

            Divider()

            Toggle(isOn: Binding(get: { st.keepScreen }, set: { v in
                ScreenKeeper.shared.setEnabled(v)
                refresh()
            })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("keep.title")).font(.system(size: 13, weight: .medium))
                    Text(L("keep.subtitle")).font(.system(size: 10)).foregroundColor(.secondary)
                }
            }.toggleStyle(.switch).disabled(!st.bdAvailable)

            if !st.bdAvailable {
                Text(L("keep.needsBD")).font(.system(size: 10)).foregroundColor(.orange)
            } else if st.keepScreen {
                // Spell out which branch the keeper is in — the whole point is that it stays
                // idle while a monitor is attached, and that is otherwise invisible.
                Text(st.physicalCount > 0
                     ? L("keep.idle")
                     : (st.screenAttached ? L("keep.active") : L("keep.waiting")))
                    .font(.system(size: 10))
                    .foregroundColor(st.physicalCount > 0 ? .secondary : .green)
            }

            Toggle(isOn: Binding(get: { st.loginAgent }, set: { v in
                if v { installLoginAgent() } else { removeLoginAgent() }
                refresh()
            })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("login.title")).font(.system(size: 13, weight: .medium))
                    Text(L("login.subtitle")).font(.system(size: 10)).foregroundColor(.secondary)
                }
            }.toggleStyle(.switch)

            Divider()

            HStack {
                Button(st.agentLoaded ? L("btn.removeTrigger") : L("btn.installTrigger")) {
                    busy = true
                    DispatchQueue.global().async {
                        if st.agentLoaded { removeTrigger() } else { _ = installTrigger() }
                        DispatchQueue.main.async { busy = false; refresh() }
                    }
                }
                Spacer()
                if busy { ProgressView().scaleEffect(0.5).frame(width: 16, height: 16) }
            }

            HStack {
                Button(st.ipadConnected ? L("btn.disconnect") : L("btn.connect")) {
                    busy = true
                    DispatchQueue.global().async {
                        let act = st.ipadConnected ? "disconnect" : "connect"
                        _ = ctl("\(act) \"\(st.device)\"")
                        usleep(1_500_000)
                        DispatchQueue.main.async { busy = false; refresh() }
                    }
                }.disabled(st.device.isEmpty)
                Spacer()
                Button(L("btn.refresh")) { refresh() }
            }

            if st.autologin && st.armed {
                Text(L("ready")).font(.system(size: 11)).foregroundColor(.green)
            }
        }
        .padding(20)
        .frame(width: 370)
    }
}

// MARK: - App
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var isBackground: Bool { CommandLine.arguments.contains(BG_FLAG) }

    func applicationDidFinishLaunching(_ note: Notification) {
        // One-shot: called by the auto-connect trigger after Sidecar attaches. Do the CG
        // fixups and exit without ever showing UI.
        if CommandLine.arguments.contains(FIXUP_FLAG) {
            NSApp.setActivationPolicy(.prohibited)
            runFixup()
            exit(0)
        }
        ScreenKeeper.shared.start()
        if Self.isBackground {
            // Launched at login with no one watching: no Dock icon, no window, just the keeper.
            NSApp.setActivationPolicy(.accessory)
            DispatchQueue.main.async { NSApp.windows.forEach { $0.close() } }
        }
    }

    // Closing the window must not kill the keeper it was configuring.
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool {
        !ScreenKeeper.shared.enabled
    }
}

@main struct SidecarTravelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup { ContentView() }.windowResizability(.contentSize)
    }
}
