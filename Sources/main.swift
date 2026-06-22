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
    let plug = """
    #!/bin/bash
    DIR="$HOME/Library/Application Support/SidecarTravel"
    [ -f "$DIR/armed" ] || exit 0
    DEV=$(cat "$DIR/device.txt" 2>/dev/null)
    [ -z "$DEV" ] && exit 0
    LOG="$DIR/plug.log"
    if /usr/bin/osascript -l JavaScript "$DIR/ctl.js" list 2>/dev/null | grep -q "connected=\\[\\"$DEV\\"\\]"; then exit 0; fi
    echo "$(date '+%F %T') iPad plugged -> connecting" >> "$LOG"
    for i in $(seq 1 30); do
      if /usr/bin/osascript -l JavaScript "$DIR/ctl.js" list 2>/dev/null | grep -q "connected=\\[\\"$DEV\\"\\]"; then
        echo "  connected (try $i)" >> "$LOG"; exit 0
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

@main struct SidecarTravelApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }.windowResizability(.contentSize)
    }
}
