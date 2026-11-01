//
//  test-hang-config.swift
//  Deep Sleep 回归测试
//
//  验证未响应检测的配置与过滤规则：
//  - 白名单命中的应用一律跳过
//  - 系统应用（bundle 在 /System 下）按开关过滤
//  - 「检测后台应用」开关前后，候选集合不一样
//  - 配置写进去能读回来
//  - 存档损坏时回落默认值
//
//  运行：
//  swiftc -parse-as-library \
//    DeepSleep/Core/HangDetectionConfig.swift \
//    scripts/test-hang-config.swift -o /tmp/t_hangcfg && /tmp/t_hangcfg
//

import Foundation

@main
struct HangConfigTests {

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

        func checkEqual<T: Equatable>(_ name: String, _ expected: T, _ actual: T) {
            check(name, expected == actual, "期望 \(expected)，实际 \(actual)")
        }

        // --------------------------------------------------- 独立 suite
        //
        // `hangDetectionConfig.v1` 是 App 真实在用的键名。拿 `.standard`
        // 去写，跑一次测试就把用户自己的设置改了（开关、白名单全丢）。
        //
        // suite 名通过环境变量注入：存储位置在**首次访问**时就定下来了，
        // 环境变量是唯一能在那之前把它定好的入口。所以这里用 setenv
        // 在 main 一进来就设好，之后任何一次访问都会拿到这个 suite。
        let suiteName = "com.skyc8266.deepsleep.tests.hang-config"
        setenv("DEEPSLEEP_HANG_CONFIG_SUITE", suiteName, 1)
        guard let suiteDefaults = UserDefaults(suiteName: suiteName) else {
            print("  [失败] 建不出独立的 UserDefaults suite")
            print("\n测试结论: 1 项失败")
            exit(1)
        }
        suiteDefaults.removePersistentDomain(forName: suiteName)

        check("配置落在独立 suite 里，没有碰用户自己的偏好设置",
              HangDetectionConfig.storage !== UserDefaults.standard)
        check("独立 suite 里没有残留存档",
              suiteDefaults.data(forKey: HangDetectionConfig.storageKey) == nil)

        // ------------------------------------------------------ 候选构造
        func candidate(_ pid: pid_t,
                       _ bundleID: String,
                       path: String? = "/Applications/Test.app",
                       foreground: Bool = false,
                       regular: Bool = true) -> HangCandidate {
            HangCandidate(pid: pid,
                          bundleID: bundleID,
                          appName: bundleID,
                          bundlePath: path,
                          isForeground: foreground,
                          isRegularActivationPolicy: regular)
        }

        // --------------------------------------------------------- 白名单
        print("== 白名单 ==")
        var config = HangDetectionConfig.default
        config.whitelistBundleIDs = ["com.example.noisy"]

        let withWhitelisted = [
            candidate(101, "com.example.noisy"),
            candidate(102, "com.example.quiet")
        ]
        let afterWhitelist = HangCandidateFilter.filter(withWhitelisted, config: config)
        checkEqual("白名单命中的应用被跳过，候选只剩 1 个", 1, afterWhitelist.count)
        check("白名单命中的那个确实不在候选里",
              !afterWhitelist.contains { $0.bundleID == "com.example.noisy" })
        check("不在白名单的应用照常检测",
              afterWhitelist.contains { $0.bundleID == "com.example.quiet" })

        // 白名单比对大小写不敏感：用户手抖打大写不该漏判。
        var upperConfig = HangDetectionConfig.default
        upperConfig.whitelistBundleIDs = ["COM.EXAMPLE.NOISY"]
        let afterUpper = HangCandidateFilter.filter(withWhitelisted, config: upperConfig)
        checkEqual("白名单大小写不敏感", 1, afterUpper.count)

        // ------------------------------------------------------ 系统进程
        print("\n== 系统进程过滤 ==")
        let systemApp = candidate(201, "com.apple.finder",
                                  path: "/System/Library/CoreServices/Finder.app")
        let userApp = candidate(202, "com.example.editor",
                                path: "/Applications/Editor.app")
        let systemAppsApp = candidate(203, "com.apple.terminal",
                                      path: "/System/Applications/Utilities/Terminal.app")

        var ignoringSystem = HangDetectionConfig.default
        ignoringSystem.ignoreSystemProcesses = true
        let ignored = HangCandidateFilter.filter([systemApp, systemAppsApp, userApp],
                                                 config: ignoringSystem)
        checkEqual("开启「忽略系统进程」后两个系统应用都被跳过", 1, ignored.count)
        check("留下的是用户应用",
              ignored.first?.bundleID == "com.example.editor")

        var keepingSystem = HangDetectionConfig.default
        keepingSystem.ignoreSystemProcesses = false
        let kept = HangCandidateFilter.filter([systemApp, systemAppsApp, userApp],
                                               config: keepingSystem)
        checkEqual("关掉「忽略系统进程」后系统应用也参与检测", 3, kept.count)

        check("bundle 在 /System/Applications 下也算系统应用",
              HangCandidateFilter.isSystemApp(bundlePath: "/System/Applications/Utilities/Terminal.app"))
        check("/System/Library 下也算系统应用",
              HangCandidateFilter.isSystemApp(bundlePath: "/System/Library/CoreServices/Finder.app"))
        check("/Applications 下不算系统应用",
              !HangCandidateFilter.isSystemApp(bundlePath: "/Applications/Safari.app"))
        check("没有路径时不算系统应用",
              !HangCandidateFilter.isSystemApp(bundlePath: nil))

        // ------------------------------------------------- 后台开关差异
        print("\n== 「检测后台应用」开关 ==")
        let foregroundApp = candidate(301, "com.example.front", foreground: true)
        let backgroundApp = candidate(302, "com.example.back", foreground: false)

        var checkingAll = HangDetectionConfig.default
        checkingAll.checkBackgroundApps = true
        let allCandidates = HangCandidateFilter.filter([foregroundApp, backgroundApp],
                                                       config: checkingAll)
        checkEqual("开着后台检测时前台后台都进候选", 2, allCandidates.count)

        var foregroundOnly = HangDetectionConfig.default
        foregroundOnly.checkBackgroundApps = false
        let frontCandidates = HangCandidateFilter.filter([foregroundApp, backgroundApp],
                                                         config: foregroundOnly)
        checkEqual("关掉后台检测时只剩前台应用", 1, frontCandidates.count)
        check("留下的是前台应用",
              frontCandidates.first?.bundleID == "com.example.front")

        // ------------------------------------------------- 其它过滤条件
        print("\n== 其它过滤条件 ==")
        var plain = HangDetectionConfig.default
        plain.checkBackgroundApps = true

        let mixed = [
            candidate(401, "com.skyc8266.deepsleep"),          // 本应用自己
            candidate(402, "com.skyc8266.deepsleep.helper"),   // 特权助手
            candidate(403, ""),                                // 没有 bundle id
            candidate(404, "com.example.agent", regular: false), // 后台 agent
            candidate(405, "com.example.real")
        ]
        let filtered = HangCandidateFilter.filter(mixed, config: plain)
        checkEqual("自己、助手、无 bundle id、后台 agent 全部跳过", 1, filtered.count)
        check("留下的是正常应用",
              filtered.first?.bundleID == "com.example.real")

        // ------------------------------------------------------ 落盘往返
        print("\n== 落盘往返 ==")
        suiteDefaults.removeObject(forKey: HangDetectionConfig.storageKey)
        check("没有记录时读回默认配置", HangDetectionConfig.load() == HangDetectionConfig.default)

        var custom = HangDetectionConfig.default
        custom.enabled = false
        custom.checkBackgroundApps = false
        custom.ignoreSystemProcesses = false
        custom.whitelistBundleIDs = ["com.a.one", "com.b.two"]
        custom.detectionIntervalSeconds = 30
        custom.saveIfNotDefault()
        check("非默认值会写进 UserDefaults",
              suiteDefaults.data(forKey: HangDetectionConfig.storageKey) != nil)

        let loaded = HangDetectionConfig.load()
        checkEqual("读回后的总开关一致", false, loaded.enabled)
        checkEqual("读回后的后台开关一致", false, loaded.checkBackgroundApps)
        checkEqual("读回后的系统进程开关一致", false, loaded.ignoreSystemProcesses)
        checkEqual("读回后的白名单一致", ["com.a.one", "com.b.two"], loaded.whitelistBundleIDs)
        checkEqual("读回后的检测间隔一致", 30, loaded.detectionIntervalSeconds)

        // 写回默认值会删掉 key，不留一份默认值副本在磁盘上。
        HangDetectionConfig.default.saveIfNotDefault()
        check("写回默认值后 key 被删掉",
              suiteDefaults.data(forKey: HangDetectionConfig.storageKey) == nil)
        check("删掉后读回仍是默认配置", HangDetectionConfig.load() == HangDetectionConfig.default)

        // ------------------------------------------------------ 数据损坏
        print("\n== 数据损坏 ==")
        suiteDefaults.set(Data("这不是 JSON".utf8), forKey: HangDetectionConfig.storageKey)
        check("数据损坏时读回默认配置", HangDetectionConfig.load() == HangDetectionConfig.default)

        // 只缺一个字段的存档不该整份作废：白名单还在。
        let partial = """
        {"enabled":false,"checkBackgroundApps":true,"ignoreSystemProcesses":true,\
        "whitelistBundleIDs":["com.keep.me"]}
        """
        suiteDefaults.set(Data(partial.utf8), forKey: HangDetectionConfig.storageKey)
        let partialLoaded = HangDetectionConfig.load()
        checkEqual("缺检测间隔字段时用默认值补上", 15, partialLoaded.detectionIntervalSeconds)
        checkEqual("缺字段的白名单仍然读得出来", ["com.keep.me"], partialLoaded.whitelistBundleIDs)
        check("缺字段的总开关读得出来", !partialLoaded.enabled)

        // --------------------------------------------------- 间隔取值范围
        print("\n== 检测间隔取值范围 ==")
        checkEqual("间隔小于下限时被夹到下限",
                   HangDetectionConfig.intervalRange.lowerBound,
                   HangDetectionConfig(enabled: true, checkBackgroundApps: true,
                                       ignoreSystemProcesses: true,
                                       whitelistBundleIDs: [], detectionIntervalSeconds: 1)
                       .detectionIntervalSeconds)
        checkEqual("间隔大于上限时被夹到上限",
                   HangDetectionConfig.intervalRange.upperBound,
                   HangDetectionConfig(enabled: true, checkBackgroundApps: true,
                                       ignoreSystemProcesses: true,
                                       whitelistBundleIDs: [], detectionIntervalSeconds: 99999)
                       .detectionIntervalSeconds)

        // -------------------------------------------------- 清理与汇总
        suiteDefaults.removePersistentDomain(forName: suiteName)
        check("测试结束后独立 suite 已清干净",
              UserDefaults(suiteName: suiteName)?.data(forKey: HangDetectionConfig.storageKey) == nil)

        print(failures == 0 ? "\n测试结论: 全部通过" : "\n测试结论: \(failures) 项失败")
        exit(failures == 0 ? 0 : 1)
    }
}
