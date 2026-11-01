//
//  test-diagnostic-rules2.swift
//  Deep Sleep
//
//  设备诊断**第二批扩展检查项**（系统隐藏配置 + 已安装软件 / 开发环境）的自测。
//
//  夹具全部是**本机真实采集到的命令输出**（2026-11-01，macOS 27.2 / arm64），
//  不是凭空编的格式 —— 格式编错了的话单测也一起错，挡不住问题。
//
//  运行： swiftc -parse-as-library Shared/DiagnosticModel.swift \
//                    DeepSleep/Core/DiagnosticsExtras.swift \
//                    DeepSleep/Core/DiagnosticsExtras2.swift \
//                    scripts/test-diagnostic-rules2.swift -o /tmp/t_diag2 && /tmp/t_diag2
//

import Foundation

@main
struct DiagnosticRuleTests2 {

    // MARK: - 真实采集的夹具

    /// sysctl：内核上限、TCP 缓冲区、CPU 拓扑（一次查完）。
    static let sysctlText = """
    kern.maxproc: 2000
    kern.maxfiles: 30720
    kern.maxfilesperproc: 10240
    kern.ipc.maxsockbuf: 8388608
    net.inet.tcp.sendspace: 131072
    net.inet.tcp.recvspace: 131072
    net.inet.tcp.autosndbufmax: 4194304
    net.inet.tcp.autorcvbufmax: 4194304
    hw.physicalcpu: 8
    hw.logicalcpu: 8
    """

    /// sysctl -n vm.swapusage
    static let swapText = """
    total = 9216.00M  used = 7839.00M  free = 1377.00M  (encrypted)
    """

    /// launchctl limit
    static let launchLimitText = """
    \tcpu         unlimited      unlimited
    \tfilesize    unlimited      unlimited
    \tdata        unlimited      unlimited
    \tstack       8372224        67092480
    \tcore        0              unlimited
    \trss         unlimited      unlimited
    \tmemlock     unlimited      unlimited
    \tmaxproc     1333           2000
    \tmaxfiles    256            unlimited
    """

    /// launchctl list（截取，含 Apple 自家与第三方的失败项）。
    static let launchListText = """
    PID\tStatus\tLabel
    -\t0\tcom.apple.SafariHistoryServiceAgent
    -\t-9\tcom.apple.progressd
    40013\t-9\tcom.apple.cloudphotod
    -\t1\torg.torproject.tor
    38053\t75\tai.hermes.gateway
    2890\t0\tcom.tencent.xinWeChat-sparkle-progress
    -\t0\tcom.valerijs.boguckis.TextSniper-setapp-LaunchAtLoginHelper
    """

    /// diskutil apfs listSnapshots /
    static let snapshotText = """
    Snapshots for disk3s1s1 (3 found)
    |
    +-- 09051DF9-4E94-44EB-BDB5-1CBFB71D8B8D
    |   Name:        com.apple.os.update-9A2FCB9915FEFB6C11A135DDA6372764F2D4BC9491728F99B1DA368520407E1C
    |   XID:         58001366
    |   Purgeable:   No
    |
    +-- A8755C05-A238-4E3E-AC29-5248159BF588
    |   Name:        com.apple.os.update-160CB66011296F47632E84D297EE2B18791B3C22AA4FA662D9C0AF5E1EBF6DA49DE7843FB8CD8E9F50DE837BFFD4B8E0
    |   XID:         58144648
    |   Purgeable:   No
    |
    +-- CD54BF75-1871-4455-A0C6-FD2F536669B1
        Name:        com.apple.os.update-MSUPrepareUpdate
        XID:         58144650
    """

    /// tmutil destinationinfo
    static let timeMachineDestinationText = """
    ====================================================
    Name          : Macintosh HD
    Kind          : Local
    ID            : C1795ECE-8E30-49C1-861F-F58BF1143DEF
    """

    /// tmutil listbackups（本机没有备份时的真实报错）。
    static let timeMachineBackupsText = """
    Failed to mount backup destination, error: Error Domain=com.apple.backupd.ErrorDomain Code=17 "Failed to mount destination." UserInfo={NSLocalizedDescription=Failed to mount destination.}
    """

    /// mdutil -s -a
    static let spotlightText = """
    /:
    \tIndexing disabled.
    /System/Volumes/Data:
    \tIndexing disabled.
    /System/Volumes/Data/Users/mofan/OrbStack:
    \tNo index.
    /System/Volumes/Preboot:
    \tIndexing disabled.
    """

    /// scutil --dns
    static let dnsText = """
    DNS configuration

    resolver #1
      nameserver[0] : 8.8.8.8
      nameserver[1] : 114.114.114.114
      nameserver[2] : 2400:3200:baba::1
      flags    : Request A records, Request AAAA records
      reach    : 0x00000002 (Reachable)

    resolver #2
      domain   : local
      options  : mdns
      timeout  : 5
      flags    : Request A records, Request AAAA records
      reach    : 0x00000000 (Not Reachable)
      order    : 300000

    resolver #3
      domain   : 254.169.in-addr.arpa
      options  : mdns
      timeout  : 5
      flags    : Request A records, Request AAAA records
      reach    : 0x00000000 (Not Reachable)
      order    : 300200

    resolver #4
      domain   : 8.e.f.ip6.arpa
      options  : mdns
      timeout  : 5
      flags    : Request A records, Request AAAA records
      reach    : 0x00000000 (Not Reachable)
      order    : 300300
    """

    /// system_profiler SPNetworkDataType（截取两个接口 + 一个不配代理的接口）。
    static let networkText = """
    Network:

        Ethernet Adapter (en3):

          Type: Ethernet
          Hardware: Ethernet
          BSD Device Name: en3
          IPv4:
              Configuration Method: DHCP
          Proxies:
              Exceptions List: 192.168.0.0/16, 10.0.0.0/8, 172.16.0.0/12, 127.0.0.1, localhost
              Exclude Simple Hostnames: 1
              HTTP Proxy Enabled: Yes
              HTTP Proxy Port: 7890
              HTTP Proxy Server: 127.0.0.1
              HTTPS Proxy Enabled: Yes
              HTTPS Proxy Port: 7890
              HTTPS Proxy Server: 127.0.0.1
              SOCKS Proxy Enabled: No
              SOCKS Proxy Port: 0
              SOCKS Proxy Server: 0

        Wi-Fi:

          Type: Wi-Fi
          BSD Device Name: en0
          Proxies:
              Exceptions List: localhost, 127.0.0.0/8, ::1
              Exclude Simple Hostnames: 1
              HTTP Proxy Enabled: No
              HTTP Proxy Port: 0
              HTTP Proxy Server: 0
              HTTPS Proxy Enabled: No
              HTTPS Proxy Port: 0
              HTTPS Proxy Server: 0
              SOCKS Proxy Enabled: No
              SOCKS Proxy Port: 0
              SOCKS Proxy Server: 0
    """

    /// system_profiler SPNetworkDataType —— 同一份输出的另一个接口，没配代理。
    static let networkTextNoProxy = """
    Network:

        Wi-Fi:

          Type: Wi-Fi
          BSD Device Name: en0
          Proxies:
              Exceptions List: localhost, 127.0.0.0/8, ::1
              Exclude Simple Hostnames: 1
              HTTP Proxy Enabled: No
              HTTP Proxy Port: 0
              HTTP Proxy Server: 0
              HTTPS Proxy Enabled: No
              HTTPS Proxy Port: 0
              HTTPS Proxy Server: 0
              SOCKS Proxy Enabled: No
              SOCKS Proxy Port: 0
              SOCKS Proxy Server: 0
    """

    /// networksetup -listallnetworkservices
    static let networkServiceText = """
    An asterisk (*) denotes that a network service is disabled.
    Wi-Fi
    Thunderbolt Bridge
    """

    /// scutil --nc list
    static let vpnText = """
    Available network connection services in the current set (*=enabled):
    """

    /// systemextensionsctl list
    static let systemExtensionText = """
    5 extension(s)
    --- com.apple.system_extension.network_extension (Go to 'System Settings > General > Login Items & Extensions > Network Extensions' to modify these system extension(s))
    enabled\tactive\tteamID\tbundleID (version)\tname\t[state]
    *\t*\tMLZF7K7B5R\tat.obdev.littlesnitch.networkextension (6.5/7303)\tLittle Snitch Network Extension\t[activated enabled]
    \t*\tTC3Q7MAJXF\tcom.adguard.mac.adguard.network-extension (2.20/2626)\tAdGuard Network Extension\t[activated disabled]
    \t*\t4D7YV49724\tio.privado.main.wireguard (4.3.1/2864353452)\tWireGuard\t[activated disabled]
    \t*\t4D7YV49724\tio.privado.main.smartroute (2.1.3/11)\tSmartRoute\t[activated disabled]
    --- com.apple.system_extension.endpoint_security (Go to 'System Settings > General > Login Items & Extensions > Endpoint Security Extensions' to modify these system extension(s))
    enabled\tactive\tteamID\tbundleID (version)\tname\t[state]
    *\t*\tMLZF7K7B5R\tat.obdev.littlesnitch.endpointsecurity (6.5/7303)\tLittle Snitch Endpoint Security\t[activated enabled]
    """

    /// defaults read .../XProtect.bundle/Contents/Info
    static let xprotectText = """
    {
        BuildMachineOSBuild = 23A344017;
        CFBundleDevelopmentRegion = en;
        CFBundleExecutable = XProtect;
        CFBundleIdentifier = "com.apple.XProtect";
        CFBundleInfoDictionaryVersion = "6.0";
        CFBundleName = XProtect;
        CFBundlePackageType = BNDL;
        CFBundleShortVersionString = 5287;
        CFBundleSignature = "????";
        CFBundleSupportedPlatforms =     (
            MacOSX
        );
        CFBundleVersion = 1;
    }
    """

    /// profiles show -type configuration（截取两个描述文件）。
    static let profileText = """
    mofan[1] attribute: name: Sumeru Scribe
    mofan[1] attribute: configurationDescription: (null)
    mofan[1] attribute: installationDate: 2025-03-23 08:45:15 +0000
    mofan[1] attribute: organization: (null)
    mofan[1] attribute: profileIdentifier: CHEN-ZHANMING-2.CF5A0744-69FF-4A55-9A51-8678A317BF0B
    mofan[1] attribute: profileUUID: 85D8EAA5-F5FF-4621-B2A2-D92B06873DED
    mofan[1] attribute: profileType: Configuration
    mofan[1] attribute: removalDisallowed: FALSE
    mofan[1] attribute: version: 1
    mofan[1] attribute: containsComputerItems: FALSE
    mofan[1] attribute: installedByMDM: FALSE
    mofan[1] attribute: internaldata: TRUE
    mofan[1] payload count = 1
    mofan[1]            payload[1] name\t\t\t= 字体
    mofan[1]            payload[1] description\t\t\t= 配置字体设置
    mofan[1]            payload[1] type\t\t\t= com.apple.font
    mofan[1]            payload[1] organization\t\t\t= (null)
    mofan[1]            payload[1] identifier\t\t\t= com.apple.font.B1A63FDA-6BF0-4FC2-A7DF-F9056A9992D7
    mofan[2] attribute: name: Khaenriah Sun 2.003
    mofan[2] attribute: configurationDescription: (null)
    mofan[2] attribute: installationDate: 2025-03-23 08:44:40 +0000
    mofan[2] attribute: profileIdentifier: CHEN-ZHANMING-2.FA96225C-EBF2-4FF7-920D-F21209BF845D
    mofan[2] attribute: installedByMDM: FALSE
    mofan[2] payload count = 1
    mofan[2]            payload[1] type\t\t\t= com.apple.font
    """

    /// defaults read com.apple.HIToolbox AppleEnabledInputSources
    static let inputSourceText = """
    (
            {
            "Bundle ID" = "com.apple.CharacterPaletteIM";
            InputSourceKind = "Non Keyboard Input Method";
        },
            {
            "Bundle ID" = "com.apple.PressAndHold";
            InputSourceKind = "Non Keyboard Input Method";
        },
            {
            "Bundle ID" = "com.apple.inputmethod.SCIM";
            "Input Mode" = "com.apple.inputmethod.SCIM.ITABC";
            InputSourceKind = "Input Mode";
        },
            {
            "Bundle ID" = "com.apple.50onPaletteIM";
            InputSourceKind = "Non Keyboard Input Method";
        },
            {
            InputSourceKind = "Keyboard Layout";
            "KeyboardLayout ID" = 252;
            "KeyboardLayout Name" = ABC;
        },
            {
            "Bundle ID" = "com.apple.inputmethod.ironwood";
            InputSourceKind = "Non Keyboard Input Method";
        },
            {
            "Bundle ID" = "com.apple.inputmethod.SCIM";
            InputSourceKind = "Keyboard Input Method";
        },
            {
            "Bundle ID" = "com.apple.inputmethod.SCIM";
            InputSourceKind = "Non Keyboard Input Method";
        }
    )
    """

    /// system_profiler SPAudioDataType
    static let audioText = """
    Audio:

        Devices:

            MacBook Pro麦克风:

              Default Input Device: Yes
              Input Channels: 1
              Manufacturer: Apple Inc.
              Current SampleRate: 48000
              Transport: Built-in
              Input Source: MacBook Pro麦克风

            MacBook Pro扬声器:

              Default Output Device: Yes
              Default System Output Device: Yes
              Manufacturer: Apple Inc.
              Output Channels: 2
              Current SampleRate: 48000
              Transport: Built-in
              Output Source: MacBook Pro扬声器
    """

    /// system_profiler SPPrintersDataType（截取一台打印机）。
    static let printerText = """
    Printers:

        HP Inc. HP Laser MFP 136w:

          Status: Offline
          Print Server: Local
          Driver Version: 3.0
          Default: Yes
          System Printer Sharing: No
          PPD: HP Laser MFP 136w-AirPrint
    """

    /// system_profiler SPThunderboltDataType（截取一条总线）。
    static let thunderboltText = """
    Thunderbolt/USB4:

        Thunderbolt/USB4 Bus 1:

          Vendor Name: Apple Inc.
          Device Name: MacBook Pro
          UID: 0x05AC5DAE32EE1DF1
          Route String: 0
          Domain UUID: 198088FE-4E1C-4A14-AC6F-045EA519138A
          Port:
              Status: No device connected
              Link Status: 0x100
              Speed: Up to 40 Gb/s
              Receptacle: 2

        Thunderbolt/USB4 Bus 0:

          Vendor Name: Apple Inc.
          Device Name: MacBook Pro
          UID: 0x05AC5DAE32EE1DF0
          Route String: 0
          Domain UUID: 25CCF8BF-67DF-424F-820E-356337372000
          Port:
              Status: No device connected
              Link Status: 0x100
              Speed: Up to 40 Gb/s
              Receptacle: 1
    """

    /// system_profiler SPFontsDataType（截取两个字体文件）。
    static let fontText = """
    Fonts:

        Kokonor.ttf:

          Kind: TrueType
          Valid: Yes
          Enabled: Yes
          Location: /System/Library/Fonts/Supplemental/Kokonor.ttf
          Typefaces:
            Kokonor:
              Full Name: Kokonor Regular
              Family: Kokonor
              Style: 常规体

        JetBrainsMono-ExtraBold.ttf:

          Kind: TrueType
          Valid: Yes
          Enabled: Yes
          Location: /Users/mofan/Library/Fonts/JetBrainsMono-ExtraBold.ttf
          Typefaces:
            JetBrainsMono-ExtraBold:
              Full Name: JetBrains Mono ExtraBold
              Family: JetBrains Mono
              Style: 加粗体
    """

    /// ioreg -r -c AppleSmartBattery（截取关键字段）。
    static let batteryText = """
    +-o AppleSmartBattery  <class AppleSmartBattery, id 0x10000085d, registered, matched, active, busy 0 (4 ms), retain 9>
      | {
      |   "ExternalConnected" = Yes
      |   "MaxCapacity" = 100
      |   "CurrentCapacity" = 80
      |   "CycleCount" = 195
      |   "BatteryData" = {"CurrentCapacity"=80,"AppleRawMaxCapacity"=4323,"AbsoluteCapacity"=0,"DesignCapacity"=5103,"NominalChargeCapacity"=4456,"FullChargeCapacity"=4323,"MaxCapacity"=100,"FullyCharged"=0,"RemainingCapacity"=3379}
      |   "FullyCharged" = No
      |   "Serial" = "D862406A04KL3L2EK"
    """

    /// brew list --formula / --cask 的真实输出形态（各取几行）。
    static let brewFormulaText = """
    bash
    ca-certificates
    node
    openssl@3
    python@3.13
    """

    static let brewCaskText = """
    google-chrome
    iterm2
    visual-studio-code
    """

    /// npm ls -g --depth=0
    static let npmText = """
    /opt/homebrew/lib
    ├── dingtalk-workspace-cli@1.0.30
    ├── mcporter@0.7.3
    ├── npm@11.19.0
    ├── ntn@0.21.5
    ├── playwright@1.63.0
    └── wrangler@4.37.1
    """

    /// conda env list
    static let condaText = """

    # conda environments:
    #
    # * -> active
    # + -> frozen
    base                 *   /opt/anaconda3
    hermes                   /opt/anaconda3/envs/hermes
    xijianBase               /opt/anaconda3/envs/xijianBase
    xijian_realtest          /opt/anaconda3/envs/xijian_realtest
    xijian_test              /opt/anaconda3/envs/xijian_test
    """

    /// pkgutil --pkgs（截取，含第三方收据）。
    static let receiptText = """
    com.apple.pkg.CLTools_SDK_macOS13
    com.apple.pkg.MotionContent
    com.apple.metal
    fr.whitebox.pkg.Packages
    com.monter.AdobeIPCBox
    org.nodejs.npm.pkg
    io.continuum.pkg.run_installation
    com.hermes.j1game
    org.golang.go
    """

    /// kmutil showloaded（本机只有 Apple 自家的内核扩展）。
    static let kextText = """
    No variant specified, falling back to release
    Index Refs Address            Size       Wired      Name (Version) UUID <Linked Against>
        3  217 0                  0          0          com.apple.kpi.bsd (27.2.0) 014C0BA5-936D-3894-81D9-270BB9CD2798 <>
        4   12 0                  0          0          com.apple.kpi.dsep (27.2.0) 014C0BA5-936D-3894-81D9-270BB9CD2798 <>
        5  245 0                  0          0          com.apple.kpi.iokit (27.2.0) 014C0BA5-936D-3894-81D9-270BB9CD2798 <>
    """

    /// osascript 读 System Events 的登录项（真实输出）。
    static let loginItemText = """
    AlDente, Vitals, CleanShot X, Input Source Pro, OrbStack, Paste, LaunchOS, DroidPort, MiddleClick, Macs Fan Control
    """

    /// sfltool dumpbtm（截取前两条记录）。
    static let backgroundItemText = """
    ========================
     Records for UID -2 : FFFFEEEE-DDDD-CCCC-BBBB-AAAAFFFFFFFE
    ========================

     ServiceManagement migrated: true
     LaunchServices registered: false

     Items:

     #1:
                     UUID: 02F49B2E-9F6D-44D1-AB53-9C59E429336D
                     Name: Benjamin Fleischer
           Developer Name: Benjamin Fleischer
                     Type: developer (0x20)
                    Flags: [  ] (0)
              Disposition: [disabled, allowed, not notified] (0x2)
               Identifier: Benjamin Fleischer
                      URL: (null)
               Generation: 0
      Embedded Item Identifiers:
        #1: 16.io.macfuse.app.launchservice.daemon

     #2:
                     UUID: BA871F02-8844-4A5D-8A79-5A3DC2CE2E36
                     Name: io.macfuse.app.launchservice.daemon
           Developer Name: Benjamin Fleischer
          Team Identifier: 3T5GSNBU6W
                     Type: legacy daemon (0x10010)
                    Flags: [ legacy ] (0x1)
              Disposition: [enabled, allowed, notified] (0xb)
               Identifier: 16.io.macfuse.app.launchservice.daemon
                      URL: /Library/LaunchDaemons/io.macfuse.app.launchservice.daemon.plist
          Executable Path: /Library/PrivilegedHelperTools/io.macfuse.app.launchservice.daemon
               Generation: 1
        Parent Identifier: Benjamin Fleischer
    """

    /// ~/.zshrc 的真实片段：zsh 数组写法的 PATH + 关掉证书校验的变量。
    static let shellConfigText = """
    # --- /Users/mofan/.zshrc ---
    export LANG=zh_CN.UTF-8
    export HOMEBREW_API_DOMAIN="https://mirrors.aliyun.com/homebrew/homebrew-bottles/api"
    # ----- 4. PATH 和 FPATH（包含你添加的所有目录）-----
    export -T PATH path=(
      /Users/mofan/.mavis/bin
      /opt/anaconda3/bin
      /opt/anaconda3/condabin
      /Applications/Xcode.app/Contents/Developer/usr/bin
      /opt/homebrew/bin
      /opt/homebrew/sbin
      /usr/local/bin
      /usr/bin
      /bin
      /usr/sbin
      /sbin
    )
    export COLORTERM=truecolor
    export NODE_TLS_REJECT_UNAUTHORIZED=0
    export npm_config_strict_ssl=false
    export GIT_SSL_NO_VERIFY=true
    export UV_INSECURE=1
    export UV_INSECURE_HOST="pypi.org files.pythonhosted.org github.com"
    export PYTHONHTTPSVERIFY=0
    export SSL_VERIFY=false
    """

    // MARK: - 主流程

    static func main() {
        var failures = 0

        func check(_ name: String, _ condition: Bool, _ actual: String = "") {
            if condition {
                print("  [通过] \(name)")
            } else {
                print("  [失败] \(name)" + (actual.isEmpty ? "" : " —— 实际: \(actual)"))
                failures += 1
            }
        }

        func checkEqual<T: Equatable>(_ name: String, _ lhs: T, _ rhs: T) {
            if lhs == rhs {
                print("  [通过] \(name)")
            } else {
                print("  [失败] \(name)：期望 \(rhs)，实际 \(lhs)")
                failures += 1
            }
        }

        func checkClose(_ name: String, _ lhs: Double, _ rhs: Double, tolerance: Double = 0.01) {
            if abs(lhs - rhs) <= tolerance {
                print("  [通过] \(name)")
            } else {
                print("  [失败] \(name)：期望 \(rhs)（±\(tolerance)），实际 \(lhs)")
                failures += 1
            }
        }

        func item(_ sections: [DiagnosticSection], _ id: String) -> DiagnosticItem? {
            for section in sections {
                if let found = section.items.first(where: { $0.id == id }) { return found }
            }
            return nil
        }

        // MARK: - 解析

        print("\n== 解析：内核与启动项 ==")

        let kernel = Dg2Extra.parseKeyValues(sysctlText)
        checkEqual("内核：进程数上限", kernel.int("kern.maxproc") ?? -1, 2000)
        checkEqual("内核：文件句柄总数上限", kernel.int("kern.maxfiles") ?? -1, 30720)
        checkEqual("内核：单进程句柄上限", kernel.int("kern.maxfilesperproc") ?? -1, 10240)
        checkEqual("内核：socket 缓冲区上限", kernel.int("kern.ipc.maxsockbuf") ?? -1, 8388608)
        checkEqual("内核：TCP 发送缓冲区", kernel.int("net.inet.tcp.sendspace") ?? -1, 131072)
        checkEqual("内核：TCP 自动调优接收上限", kernel.int("net.inet.tcp.autorcvbufmax") ?? -1, 4194304)
        check("内核：读不到的键返回 nil", kernel.int("kern.nosuchkey") == nil)
        check("内核：空输出解析不出东西", Dg2Extra.parseKeyValues("").values.isEmpty)

        let topology = Dg2Extra.parseCPUTopology(sysctlText)
        checkEqual("CPU：物理核", topology?.physicalCores ?? -1, 8)
        checkEqual("CPU：逻辑核", topology?.logicalCores ?? -1, 8)
        check("CPU：空输出解析不出东西", Dg2Extra.parseCPUTopology("") == nil)

        let swap = Dg2Extra.parseSwapCapacity(swapText)
        checkEqual("交换空间：总量（字节）", swap?.totalBytes ?? 0, 9_663_676_416)
        checkEqual("交换空间：已用（字节）", swap?.usedBytes ?? 0, 8_219_787_264)
        checkEqual("交换空间：剩余（字节）", swap?.freeBytes ?? 0, 1_443_889_152)
        check("交换空间：空输出解析不出东西", Dg2Extra.parseSwapCapacity("") == nil)
        checkEqual("交换空间：总量为 0 也算读到了",
                   Dg2Extra.parseSwapCapacity("total = 0.00M  used = 0.00M  free = 0.00M")?.totalBytes ?? UInt64.max, 0)

        let launchLimits = Dg2Extra.parseLaunchLimits(launchLimitText)
        checkEqual("launchd：句柄软上限", launchLimits.maxFilesSoft ?? "", "256")
        checkEqual("launchd：句柄硬上限", launchLimits.maxFilesHard ?? "", "unlimited")
        checkEqual("launchd：进程数软上限", launchLimits.maxProcSoft ?? "", "1333")
        checkEqual("launchd：进程数硬上限", launchLimits.maxProcHard ?? "", "2000")
        check("launchd：没有 maxfiles 时是 nil", Dg2Extra.parseLaunchLimits("cpu unlimited unlimited").maxFilesSoft == nil)

        let launch = Dg2Extra.parseLaunchList(launchListText)
        checkEqual("自启项：第三方失败项数量", launch.failures.count, 2)
        check("自启项：认出 tor 的失败项",
              launch.failures.contains { $0.label == "org.torproject.tor" && $0.exitCode == 1 },
              "\(launch.failures)")
        check("自启项：认出退出码 75 的失败项",
              launch.failures.contains { $0.label == "ai.hermes.gateway" && $0.exitCode == 75 },
              "\(launch.failures)")
        check("自启项：Apple 自家的 -9 不算失败",
              !launch.failures.contains { $0.label == "com.apple.progressd" })
        check("自启项：正常运行的第三方不算失败",
              !launch.failures.contains { $0.label == "com.tencent.xinWeChat-sparkle-progress" })
        check("自启项：第三方总数算进去了", launch.thirdPartyCount == 4, "\(launch.thirdPartyCount)")
        check("自启项：application.* 不算第三方", !Dg2Extra.isThirdPartyLabel("application.com.apple.Terminal.1"))
        check("自启项：com.apple.* 不算第三方", !Dg2Extra.isThirdPartyLabel("com.apple.progressd"))
        check("自启项：别的算第三方", Dg2Extra.isThirdPartyLabel("org.torproject.tor"))

        print("\n== 解析：磁盘与系统 ==")

        let snapshots = Dg2Extra.parseSnapshots(snapshotText)
        checkEqual("快照：数量", snapshots.count, 3)
        check("快照：名字读出来了",
              snapshots.names.contains("com.apple.os.update-MSUPrepareUpdate"),
              "\(snapshots.names)")
        check("快照：空输出是 0 个", Dg2Extra.parseSnapshots("").count == 0)

        let timeMachine = Dg2Extra.parseTimeMachine(destination: timeMachineDestinationText,
                                                     backups: timeMachineBackupsText)
        checkEqual("Time Machine：备份目标", timeMachine.destinations.joined(separator: ","), "Macintosh HD")
        check("Time Machine：挂载失败时没有最近备份", timeMachine.lastBackup == nil)
        check("Time Machine：挂载失败要记下原因",
              (timeMachine.lastBackupError ?? "").contains("挂载失败"),
              timeMachine.lastBackupError ?? "")
        let timeMachineWithBackup = Dg2Extra.parseTimeMachine(destination: timeMachineDestinationText,
                                                              backups: "2026-10-30-101010\n\tMacintosh HD")
        checkEqual("Time Machine：有备份时读出时间",
                   timeMachineWithBackup.lastBackup ?? "", "2026-10-30-101010")

        let spotlight = Dg2Extra.parseSpotlight(spotlightText)
        checkEqual("聚焦：卷的数量", spotlight.count, 4)
        check("聚焦：根卷索引被关掉了",
              spotlight.first { $0.path == "/" }?.indexingDisabled ?? false)
        check("聚焦：没有索引不算「被关闭」",
              !(spotlight.first { $0.path == "/System/Volumes/Data/Users/mofan/OrbStack" }?.indexingDisabled ?? true))

        print("\n== 解析：网络 ==")

        let dns = Dg2Extra.parseDNS(dnsText)
        checkEqual("DNS：服务器数量", dns.nameservers.count, 3)
        check("DNS：读出第一个服务器", dns.nameservers.first == "8.8.8.8", "\(dns.nameservers)")
        check("DNS：读出 IPv6 服务器", dns.nameservers.contains("2400:3200:baba::1"), "\(dns.nameservers)")
        checkEqual("DNS：mdns 解析器数量", dns.mdnsResolverCount, 3)
        check("DNS：搜索域读出来了", dns.domains.contains("local"), "\(dns.domains)")

        let interfaces = Dg2Extra.parseNetworkInterfaces(networkText)
        checkEqual("网络：配了代理的接口数量", interfaces.proxiedInterfaces.count, 1)
        check("网络：认得出 en3 配了代理",
              interfaces.proxiedInterfaces.contains("Ethernet Adapter (en3)"),
              "\(interfaces.proxiedInterfaces)")
        check("网络：没配代理的接口不算",
              !interfaces.proxiedInterfaces.contains("Wi-Fi"))

        let services = Dg2Extra.parseNetworkServiceList(networkServiceText)
        checkEqual("网络服务：数量", services.services.count, 2)
        check("网络服务：名字读出来", services.services.contains("Wi-Fi"), "\(services.services)")
        checkEqual("网络服务：没有禁用的服务", services.disabled.count, 0)
        let disabledServices = Dg2Extra.parseNetworkServiceList("An asterisk (*) denotes that a network service is disabled.\n*Ethernet Adapter\nWi-Fi")
        checkEqual("网络服务：带 * 的是禁用的", disabledServices.disabled.joined(separator: ","), "Ethernet Adapter")

        check("VPN：没有配置时是空列表", Dg2Extra.parseVPNList(vpnText).isEmpty)
        check("VPN：说明行不算配置", Dg2Extra.parseVPNList("Available network connection services in the current set (*=enabled):\ncom.example.vpn").count == 1)

        let networkExtensions = Dg2Extra.parseNetworkExtensions(systemExtensionText)
        checkEqual("网络扩展：数量", networkExtensions.count, 3)
        check("网络扩展：认出 Little Snitch",
              networkExtensions.contains { $0.bundleID == "at.obdev.littlesnitch.networkextension" },
              "\(networkExtensions)")
        check("网络扩展：AdGuard 被当成内容过滤器",
              networkExtensions.contains { $0.bundleID == "com.adguard.mac.adguard.network-extension" && $0.isFilter },
              "\(networkExtensions)")
        check("网络扩展：WireGuard 被当成隧道",
              networkExtensions.contains { $0.bundleID == "io.privado.main.wireguard" && $0.isTunnel },
              "\(networkExtensions)")
        check("网络扩展：端点安全扩展不算网络扩展",
              !networkExtensions.contains { $0.bundleID.contains("endpointsecurity") })

        print("\n== 解析：安全与外设 ==")

        checkEqual("XProtect：版本", Dg2Extra.parseXProtectVersion(xprotectText) ?? "", "5287")
        check("XProtect：读不到时是 nil", Dg2Extra.parseXProtectVersion("{}") == nil)

        let profiles = Dg2Extra.parseProfiles(profileText)
        checkEqual("描述文件：数量", profiles.count, 2)
        checkEqual("描述文件：第一个名字", profiles.first?.name ?? "", "Sumeru Scribe")
        checkEqual("描述文件：标识符",
                   profiles.first?.identifier ?? "",
                   "CHEN-ZHANMING-2.CF5A0744-69FF-4A55-9A51-8678A317BF0B")
        check("描述文件：不是 MDM 下发的", !(profiles.first?.installedByMDM ?? true))
        check("描述文件：读出载荷类型",
              profiles.first?.payloadTypes.contains("com.apple.font") ?? false,
              "\(profiles.first?.payloadTypes ?? [])")
        check("描述文件：字体类不是限制类", !(profiles.first?.restricted ?? true))

        // 安全客户端的关键词匹配：这台机器上没装，所以正向用例用一段
        // 只含关键字的短文本（匹配表本身不是命令输出，没有「格式」可言）。
        check("安全客户端：没装时是空列表",
              Dg2Extra.parseSecurityAgents(processText: "/sbin/launchd\n/usr/libexec/logd",
                                           appNames: ["Safari.app"]).isEmpty)
        check("安全客户端：能认出 Jamf",
              Dg2Extra.parseSecurityAgents(processText: "/Library/Application Support/JAMF/JAMFDaemon",
                                           appNames: []).contains("Jamf Pro（MDM）"))
        check("安全客户端：能认出 Defender",
              Dg2Extra.parseSecurityAgents(processText: "/opt/microsoft/ defender",
                                           appNames: ["Microsoft Defender for Endpoint.app"])
                .contains("Microsoft Defender for Endpoint"))

        let inputSources = Dg2Extra.parseInputSources(inputSourceText)
        checkEqual("输入法：总数", inputSources.total, 8)
        checkEqual("输入法：非键盘类数量", inputSources.nonKeyboard, 6)

        let audio = Dg2Extra.parseAudio(audioText)
        checkEqual("音频：设备数量", audio.deviceNames.count, 2)
        checkEqual("音频：默认输出", audio.defaultOutput ?? "", "MacBook Pro扬声器")
        checkEqual("音频：默认输入", audio.defaultInput ?? "", "MacBook Pro麦克风")

        let printers = Dg2Extra.parsePrinters(printerText)
        checkEqual("打印机：数量", printers.count, 1)
        checkEqual("打印机：名字", printers.first?.name ?? "", "HP Inc. HP Laser MFP 136w")
        checkEqual("打印机：状态", printers.first?.status ?? "", "Offline")

        let usb = Dg2Extra.parseThunderbolt(thunderboltText)
        checkEqual("雷雳：总线数量", usb.busCount, 2)
        checkEqual("雷雳：空闲口数量", usb.freePorts, 2)
        checkEqual("雷雳：占用口数量", usb.occupiedPorts, 0)

        let fonts = Dg2Extra.parseFonts(fontText)
        checkEqual("字体：文件数量", fonts.total, 2)
        checkEqual("字体：用户自装数量", fonts.userInstalled, 1)

        let battery = Dg2Extra.parseBattery(batteryText)
        checkEqual("电池：循环次数", battery?.cycleCount ?? -1, 195)
        checkEqual("电池：设计容量", battery?.designCapacity ?? -1, 5103)
        checkEqual("电池：满充容量", battery?.fullChargeCapacity ?? -1, 4323)
        checkEqual("电池：最大容量百分比", battery?.maxCapacityPercent ?? -1, 100)
        checkEqual("电池：当前电量", battery?.currentCapacityPercent ?? -1, 80)
        check("电池：接了电源", battery?.externallyConnected ?? false)
        check("电池：没充满", !(battery?.fullyCharged ?? true))
        checkClose("电池：健康度", battery?.healthPercent ?? 0, 4323.0 / 5103.0 * 100)
        check("电池：空输出解析不出东西", Dg2Extra.parseBattery("") == nil)

        print("\n== 解析：开发环境与软件 ==")

        let shell = Dg2Extra.parseShellConfig(shellConfigText)
        checkEqual("Shell：PATH 目录数量", shell.pathEntryCount, 11)
        checkEqual("Shell：关掉证书校验的变量数量", shell.insecureSettings.count, 6)
        check("Shell：认出 NODE_TLS_REJECT_UNAUTHORIZED",
              shell.insecureSettings.contains("NODE_TLS_REJECT_UNAUTHORIZED"),
              "\(shell.insecureSettings)")
        check("Shell：认出 UV_INSECURE", shell.insecureSettings.contains("UV_INSECURE"))
        check("Shell：问题出在 .zshrc",
              (shell.file ?? "").hasSuffix(".zshrc"), shell.file ?? "")
        check("Shell：没有重复目录", shell.duplicatePathEntries.isEmpty)

        let shellWithDuplicate = Dg2Extra.parseShellConfig("""
        # --- /Users/test/.zshrc ---
        export PATH=/usr/bin:/bin:/usr/bin:/usr/local/bin
        """)
        checkEqual("Shell：重复的 PATH 目录", shellWithDuplicate.duplicatePathEntries.joined(separator: ","), "/usr/bin")
        check("Shell：安全的变量不算异常",
              Dg2Extra.parseShellConfig("export NODE_TLS_REJECT_UNAUTHORIZED=1").insecureSettings.isEmpty)

        let brew = Dg2Extra.parseBrew(formulas: brewFormulaText, casks: brewCaskText)
        checkEqual("Homebrew：formula 数量", brew.formulaCount, 5)
        checkEqual("Homebrew：cask 数量", brew.caskCount, 3)

        let npm = Dg2Extra.parseNpm(npmText)
        checkEqual("npm：全局包数量", npm.packageCount, 6)
        checkEqual("npm：没有损坏包", npm.invalidPackages.count, 0)
        // 真实输出：软链接指向不存在的目录时，npm 只给出一个空版本号。
        let brokenNpm = Dg2Extra.parseNpm("""
        /tmp/npmprobe3/lib -> ./
        └── dangling@
        """)
        check("npm：认得出损坏的包", brokenNpm.invalidPackages.count == 1, "\(brokenNpm.invalidPackages)")
        check("npm：损坏的包也算进总数", brokenNpm.packageCount == 1, "\(brokenNpm.packageCount)")

        let conda = Dg2Extra.parseCondaEnvs(condaText)
        checkEqual("conda：环境数量", conda.count, 5)
        check("conda：读出环境名", conda.contains("hermes"), "\(conda)")

        let loginItems = Dg2Extra.parseLoginItems(loginItemText)
        checkEqual("登录项：数量", loginItems.count, 10)
        check("登录项：读出名字", loginItems.contains("CleanShot X"), "\(loginItems)")
        check("登录项：空输出是空列表", Dg2Extra.parseLoginItems("").isEmpty)
        check("登录项：只有一个时也不带逗号",
              Dg2Extra.parseLoginItems("AlDente").count == 1)

        let background = Dg2Extra.parseBackgroundItems(backgroundItemText)
        checkEqual("后台项：数量", background.names.count, 2)
        check("后台项：读出名字",
              background.names.contains("io.macfuse.app.launchservice.daemon"), "\(background.names)")
        check("后台项：Developer Name 不算成一项",
              !background.names.contains("Benjamin Fleischer") || background.names.count == 2,
              "\(background.names)")
        check("后台项：空输出是空的", Dg2Extra.parseBackgroundItems("").names.isEmpty)

        let receipts = Dg2Extra.parseReceipts(receiptText)
        checkEqual("收据：总数", receipts.total, 9)
        checkEqual("收据：第三方数量", receipts.thirdParty.count, 6)
        check("收据：第三方里不含 com.apple", !receipts.thirdParty.contains { $0.hasPrefix("com.apple.") })

        check("内核扩展：Apple 自家的不算第三方", Dg2Extra.parseKexts(kextText).isEmpty)
        check("内核扩展：能认出第三方的",
              Dg2Extra.parseKexts("""
              Index Refs Address            Size       Wired      Name (Version) UUID <Linked Against>
                  10    6 0xfffffe0007130000 0xab0c     0xab0c     org.virtualbox.kext.VBoxNetAdp (1) 0D989F5E-7FE0-3676-A8D8-177000616504 <6>
              """).contains("org.virtualbox.kext.VBoxNetAdp"))

        let duplicated = Dg2Extra.duplicateAppNames([
            Dg2AppEntry(name: "Foo.app", path: "/Applications/Foo.app", bundleID: "com.foo", brokenReason: nil),
            Dg2AppEntry(name: "Foo.app", path: "/Users/x/Applications/Foo.app", bundleID: "com.foo", brokenReason: nil),
            Dg2AppEntry(name: "Bar.app", path: "/Applications/Bar.app", bundleID: "com.bar", brokenReason: nil)
        ])
        checkEqual("重复应用：按名字与 bundle id 都算上", duplicated.joined(separator: ","), "Foo.app")

        // MARK: - 判定

        print("\n== 判定：读不到的事实 ==")

        let emptySections = Dg2Extra.sections(from: Dg2ExtraFacts())
        checkEqual("第二批：读不到时分成五组", emptySections.count, 5)
        check("第二批：读不到时不产生问题项",
              emptySections.flatMap(\.items).allSatisfy { $0.severity == .info })
        check("第二批：读不到时写明「无法读取」",
              emptySections.flatMap(\.items).allSatisfy { $0.value.contains("无法读取") })
        check("第二批：读不到时不给处理建议",
              emptySections.flatMap(\.items).allSatisfy { $0.suggestion == nil })
        check("第二批：读不到时仍然列出全部检查项",
              emptySections.flatMap(\.items).count >= 32,
              "实际 \(emptySections.flatMap(\.items).count)")

        print("\n== 判定：正常事实 ==")

        var good = Dg2ExtraFacts()
        good.kernelLimits = .value(Dg2Extra.parseKeyValues(sysctlText))
        good.launchLimits = .value(Dg2Extra.parseLaunchLimits(launchLimitText))
        good.tcpBuffers = .value(Dg2Extra.parseKeyValues(sysctlText))
        good.swapCapacity = .value(Dg2Extra.parseSwapCapacity(swapText)!)
        good.cpuTopology = .value(Dg2Extra.parseCPUTopology(sysctlText)!)
        good.launchFailures = .value([])
        good.launchThirdPartyCount = .value(4)
        good.snapshots = .value(Dg2Extra.parseSnapshots(snapshotText))
        good.timeMachine = .value(Dg2Extra.parseTimeMachine(destination: timeMachineDestinationText,
                                                            backups: "2026-10-30-101010"))
        good.spotlight = .value(Dg2Extra.parseSpotlight(spotlightText))
        good.dns = .value(Dg2Extra.parseDNS(dnsText))
        good.networkServices = .value(Dg2Extra.parseNetworkInterfaces(networkTextNoProxy))
        good.vpn = .value([])
        good.networkExtensions = .value(Dg2Extra.parseNetworkExtensions(systemExtensionText))
        good.xprotectVersion = .value(Dg2Extra.parseXProtectVersion(xprotectText) ?? "")
        good.profiles = .value(Dg2Extra.parseProfiles(profileText))
        good.securityAgents = .value([])
        good.protectedDirs = .value([Dg2ProtectedDir(name: "照片", path: "/Users/x/Library/Photos",
                                                    accessible: true, itemCount: 12, note: nil)])
        good.inputSources = .value(Dg2Extra.parseInputSources(inputSourceText))
        good.audio = .value(Dg2Extra.parseAudio(audioText))
        good.printers = .value(Dg2Extra.parsePrinters(printerText))
        good.usb = .value(Dg2Extra.parseThunderbolt(thunderboltText))
        good.fonts = .value(Dg2Extra.parseFonts(fontText))
        good.battery = .value(Dg2Extra.parseBattery(batteryText)!)
        good.shellConfig = .value(Dg2Extra.parseShellConfig("# --- /Users/x/.zshrc ---\nexport PATH=/usr/bin:/bin"))
        good.devPaths = .value([Dg2ToolPath(tool: "python3", paths: ["/opt/anaconda3/bin/python3", "/usr/bin/python3"])])
        good.containers = .value([Dg2ContainerRuntime(name: "Docker", version: "Docker version 29.4.0")])
        good.brew = .value(Dg2Extra.parseBrew(formulas: brewFormulaText, casks: brewCaskText))
        good.npm = .value(Dg2Extra.parseNpm(npmText))
        good.pythonEnvs = .value(Dg2Extra.parseCondaEnvs(condaText))
        good.apps = .value(Dg2Apps(entries: [
            Dg2AppEntry(name: "Safari.app", path: "/Applications/Safari.app",
                        bundleID: "com.apple.Safari", brokenReason: nil)
        ]))
        good.receipts = .value(Dg2Extra.parseReceipts(receiptText))
        good.kexts = .value([])
        good.loginItems = .value(Dg2Extra.parseLoginItems(loginItemText))
        good.backgroundItems = .value(Dg2Extra.parseBackgroundItems(backgroundItemText))

        let goodSections = Dg2Extra.sections(from: good)
        // 唯一的「正常但会提醒」项：Spotlight 索引被关掉 —— 那是本机的真实状态，
        // 这里换成索引正常的卷，避免混着测两种事。
        var goodNormal = good
        goodNormal.spotlight = .value([Dg2IndexState(path: "/", state: "Indexing enabled.", indexingDisabled: false)])
        let goodNormalSections = Dg2Extra.sections(from: goodNormal)

        check("第二批：正常事实不产生问题项（除了关掉的聚焦索引）",
              goodSections.flatMap(\.items).filter { $0.severity != .info }
                  .allSatisfy { $0.id == "dg2.spotlight" },
              goodSections.flatMap(\.items).filter { $0.severity != .info }.map(\.id).joined(separator: ","))
        check("第二批：索引正常时不产生问题项",
              goodNormalSections.flatMap(\.items).allSatisfy { $0.severity == .info },
              goodNormalSections.flatMap(\.items).filter { $0.severity != .info }.map(\.id).joined(separator: ","))
        check("第二批：正常项都不带处理建议",
              goodNormalSections.flatMap(\.items)
                  .filter { $0.severity == .info }
                  .allSatisfy { $0.suggestion == nil })
        checkEqual("第二批：内核上限的值",
                   item(goodSections, "dg2.kernel_limits")?.value ?? "", "进程数上限 2000 · 文件句柄总数上限 30720 · 单进程句柄上限 10240")
        checkEqual("第二批：XProtect 版本",
                   item(goodSections, "dg2.xprotect")?.value ?? "", "5287")
        checkEqual("第二批：Homebrew 包数",
                   item(goodSections, "dg2.brew")?.value ?? "", "5 个 formula · 3 个 cask")
        checkEqual("第二批：npm 全局包数",
                   item(goodSections, "dg2.npm")?.value ?? "", "6 个全局包")

        print("\n== 判定：坏事实 ==")

        var bad = good
        bad.kernelLimits = .value(Dg2Extra.parseKeyValues("""
        kern.maxproc: 2000
        kern.maxfiles: 4096
        kern.maxfilesperproc: 256
        """))
        bad.launchLimits = .value(Dg2Extra.parseLaunchLimits("maxfiles    64             unlimited"))
        bad.tcpBuffers = .value(Dg2Extra.parseKeyValues("""
        net.inet.tcp.sendspace: 8192
        net.inet.tcp.recvspace: 8192
        """))
        bad.swapCapacity = .value(Dg2SwapCapacity(totalBytes: 0, usedBytes: 0, freeBytes: 0))
        bad.launchFailures = .value([Dg2LaunchFailure(label: "org.torproject.tor", exitCode: 1, pid: "-")])
        bad.launchThirdPartyCount = .value(4)
        bad.snapshots = .value(Dg2Snapshots(count: 30, names: (0..<30).map { "snap-\($0)" }))
        bad.timeMachine = .value(Dg2Extra.parseTimeMachine(destination: timeMachineDestinationText,
                                                           backups: timeMachineBackupsText))
        bad.spotlight = .value([Dg2IndexState(path: "/", state: "Indexing disabled.", indexingDisabled: true)])
        bad.networkServices = .value(Dg2Extra.parseNetworkInterfaces(networkText))
        bad.networkExtensions = .value([Dg2NetworkExtension(name: "AdGuard", bundleID: "com.adguard.mac.adguard.network-extension",
                                                           enabled: true, state: "[activated disabled]",
                                                           isFilter: true, isTunnel: false)])
        bad.profiles = .value([Dg2Profile(name: "公司配置", identifier: "x", installedByMDM: true,
                                          payloadTypes: ["com.apple.restrictions"], restricted: true)])
        bad.protectedDirs = .value([Dg2ProtectedDir(name: "照片", path: "/Users/x/Library/Photos",
                                                    accessible: false, itemCount: 0, note: "读不到")])
        bad.audio = .value(Dg2Audio(deviceNames: [], defaultOutput: nil, defaultInput: nil))
        bad.battery = .value(Dg2Battery(cycleCount: 1200, designCapacity: 5103, fullChargeCapacity: 3000,
                                       maxCapacityPercent: 59, currentCapacityPercent: 40,
                                       externallyConnected: false, fullyCharged: false))
        bad.shellConfig = .value(Dg2Extra.parseShellConfig(shellConfigText))
        bad.npm = .value(Dg2Extra.parseNpm("""
        /tmp/npmprobe3/lib -> ./
        └── dangling@
        """))
        bad.apps = .value(Dg2Apps(entries: [
            Dg2AppEntry(name: "Broken.app", path: "/Applications/Broken.app",
                        bundleID: "com.broken", brokenReason: "缺少 Contents/Info.plist"),
            Dg2AppEntry(name: "Foo.app", path: "/Applications/Foo.app",
                        bundleID: "com.foo", brokenReason: nil),
            Dg2AppEntry(name: "Foo.app", path: "/Users/x/Applications/Foo.app",
                        bundleID: "com.foo", brokenReason: nil)
        ]))

        let badSections = Dg2Extra.sections(from: bad)

        checkEqual("坏事实：内核上限被调低是需要注意",
                   item(badSections, "dg2.kernel_limits")?.severity, .warning)
        check("坏事实：内核上限的建议提到 Too many open files",
              (item(badSections, "dg2.kernel_limits")?.suggestion ?? "").contains("Too many open files"),
              item(badSections, "dg2.kernel_limits")?.suggestion ?? "")
        checkEqual("坏事实：句柄软上限偏低是需要注意",
                   item(badSections, "dg2.launch_limits")?.severity, .warning)
        checkEqual("坏事实：TCP 缓冲区偏小是需要注意",
                   item(badSections, "dg2.tcp_buffers")?.severity, .warning)
        checkEqual("坏事实：没有交换空间是需要注意",
                   item(badSections, "dg2.swap_capacity")?.severity, .warning)
        checkEqual("坏事实：自启项失败是需要注意",
                   item(badSections, "dg2.launch_failures")?.severity, .warning)
        check("坏事实：自启项失败要列出名字",
              (item(badSections, "dg2.launch_failures")?.detail ?? "").contains("org.torproject.tor"),
              item(badSections, "dg2.launch_failures")?.detail ?? "")
        checkEqual("坏事实：快照过多是需要注意",
                   item(badSections, "dg2.snapshots")?.severity, .warning)
        checkEqual("坏事实：没有备份是需要注意",
                   item(badSections, "dg2.timemachine")?.severity, .warning)
        checkEqual("坏事实：聚焦索引被关掉是需要注意",
                   item(badSections, "dg2.spotlight")?.severity, .warning)
        checkEqual("坏事实：接口配了代理是需要注意",
                   item(badSections, "dg2.network_services")?.severity, .warning)
        checkEqual("坏事实：扩展开关不一致是需要注意",
                   item(badSections, "dg2.network_extensions")?.severity, .warning)
        checkEqual("坏事实：限制类描述文件是需要注意",
                   item(badSections, "dg2.profiles")?.severity, .warning)
        checkEqual("坏事实：受保护目录读不到是需要注意",
                   item(badSections, "dg2.protected_dirs")?.severity, .warning)
        checkEqual("坏事实：没有音频设备是需要注意",
                   item(badSections, "dg2.audio")?.severity, .warning)
        checkEqual("坏事实：电池健康度低是需要注意",
                   item(badSections, "dg2.battery_ioreg")?.severity, .warning)
        checkEqual("坏事实：关掉证书校验是需要注意",
                   item(badSections, "dg2.shell_config")?.severity, .warning)
        checkEqual("坏事实：npm 包损坏是需要注意",
                   item(badSections, "dg2.npm")?.severity, .warning)
        checkEqual("坏事实：应用损坏是需要注意",
                   item(badSections, "dg2.apps")?.severity, .warning)
        checkEqual("坏事实：重复安装是需要注意",
                   item(badSections, "dg2.app_duplicates")?.severity, .warning)

        check("坏事实：所有问题项都有非空建议",
              badSections.flatMap(\.items)
                  .filter { $0.severity != .info }
                  .allSatisfy { !($0.suggestion ?? "").isEmpty },
              badSections.flatMap(\.items)
                  .filter { $0.severity != .info && ($0.suggestion ?? "").isEmpty }
                  .map(\.id).joined(separator: ","))
        check("坏事实：问题项数量 > 0",
              badSections.flatMap(\.items).filter { $0.severity != .info }.count >= 15,
              "实际 \(badSections.flatMap(\.items).filter { $0.severity != .info }.count)")
        check("坏事实：条目 id 互不重复",
              Set(badSections.flatMap(\.items).map(\.id)).count == badSections.flatMap(\.items).count)

        print(failures == 0 ? "\n测试结论: 全部通过" : "\n测试结论: \(failures) 项失败")
        exit(failures == 0 ? 0 : 1)
    }
}
