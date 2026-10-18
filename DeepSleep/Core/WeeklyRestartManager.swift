//
//  WeeklyRestartManager.swift
//  Deep Sleep
//
//  每周指定时间重启 Mac：通过 launchd 写一个独立 plist 跑 `sudo shutdown -r now`。
//
//  设计选择：
//   - plist 写到用户自己的 ~/Library/LaunchAgents/，不影响其他用户；
//   - 真正能跑 `shutdown -r now` 需要 root，所以同时通过 helper 写
//     /etc/sudoers.d/deepsleep-weeklyrestart 给用户 NOPASSWD 权限
//     （限制仅这条命令，其他都要密码）；
//   - helper 负责所有 root 操作（写 sudoers / chown / launchctl bootstrap），
//     应用只下发参数；
//   - 配置存在 UserDefaults JSON；helper 每次跑前不读该 JSON —— 它每次启动
//     都是「该跑就重启」一次性脚本，所以 plist 自己就是状态。
//
//  不做的事：
//   - 不做开机自启动后的「开机一次」之类的高级日历选项；
//   - 不做「距离上次重启 N 天没重启则告警」之类的健康检查（属监控范畴）。
//

import Foundation

@MainActor
final class WeeklyRestartManager {

    static let shared = WeeklyRestartManager()

    private init() {}

    struct Config: Codable, Equatable {
        var enabled: Bool
        var weekday: Int   // 0=周日 ... 6=周六
        var hour: Int      // 0-23
        var minute: Int    // 0-59
    }

    static func makeDefault() -> Config {
        Config(enabled: false, weekday: 0, hour: 4, minute: 0)
    }

    private static let storageKey = "weeklyRestartConfig.v1"

    var current: Config {
        get {
            guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
                  let config = try? JSONDecoder().decode(Config.self, from: data) else {
                return WeeklyRestartManager.makeDefault()
            }
            return config
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    /// 把当前 config 推给 helper 安装 / 卸载。
    /// 安装失败会回滚 config（保持 .default），不让 UI 显示「已启用」但实际未生效。
    func apply() async -> Result<String, ErrorReason> {
        let config = current
        if config.enabled {
            let username = NSUserName()
            let response: HelperResponse
            do {
                response = try await HelperClient.shared.send(.init(
                    command: .installWeeklyRestart,
                    arguments: [
                        "weekday": String(config.weekday),
                        "hour": String(config.hour),
                        "minute": String(config.minute),
                        "username": username
                    ]
                ), timeout: 15)
            } catch {
                return .failure(.helperFailed(error.localizedDescription))
            }
            if response.success {
                return .success("周重启已启用：每周\(weekdayName(config.weekday)) \(String(format: "%02d:%02d", config.hour, config.minute))")
            }
            // 失败回滚
            current = WeeklyRestartManager.makeDefault()
            return .failure(.helperFailed(response.message))
        } else {
            let response: HelperResponse
            do {
                response = try await HelperClient.shared.send(.init(
                    command: .uninstallWeeklyRestart
                ), timeout: 15)
            } catch {
                return .failure(.helperFailed(error.localizedDescription))
            }
            if response.success {
                return .success("周重启已停用")
            }
            return .failure(.helperFailed(response.message))
        }
    }

    func weekdayName(_ index: Int) -> String {
        let names = ["日", "一", "二", "三", "四", "五", "六"]
        guard index >= 0, index < names.count else { return "?" }
        return "周" + names[index]
    }

    enum ErrorReason: Error, CustomStringConvertible {
        case helperFailed(String)
        case helperNotInstalled
        var description: String {
            switch self {
            case .helperFailed(let msg): return "助手拒绝：\(msg)"
            case .helperNotInstalled:    return "需要先启用「完全控制」"
            }
        }
    }
}
