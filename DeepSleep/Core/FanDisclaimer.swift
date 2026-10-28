//
//  FanDisclaimer.swift
//  Deep Sleep
//
//  风扇控制（SMC 写入）的免责声明：同意状态、门禁判定、文案。
//
//  为什么要单独一层：助手权限与免责声明是两件事。
//    - 助手权限回答「技术上能不能写 SMC」；
//    - 免责声明回答「用户知不知道写坏了会怎样」。
//  两者都要过，缺一不可。应用侧拦不住「绕过界面直接构造协议包打 helper」，
//  所以助手侧还独立持久化了一份（契约 §7.2），同意状态通过
//  `setFanDisclaimerAccepted` 同步过去。
//
//  门禁语义：**未同意时，所有写风扇的操作一律拒绝**（不调用助手、不下发）。
//  闸门放在 FanController 而不是靠界面禁用控件 —— 界面禁用是「好用的做法」，
//  写操作真正的入口是 FanController，安全必须在入口处成立。
//

import Foundation

/// 风扇控制的免责声明：同意状态 + 门禁 + 文案。
enum FanDisclaimer {

    // MARK: - 键名（契约 §7.1 钉死）

    /// 是否已同意（Bool）。
    static let acceptedKey = "fanControl.disclaimerAccepted"
    /// 已同意的免责声明版本（Int）。正文有实质变化时把
    /// `FanControl.disclaimerVersion` +1，老用户要重新同意一次。
    static let versionKey = "fanControl.disclaimerVersion"

    // MARK: - 同意状态

    /// 用户是否已同意当前版本的免责声明。
    ///
    /// 判定：`accepted == true && version >= FanControl.disclaimerVersion`。
    /// 只看 accepted 不够 —— 正文改了以后，老用户的「同意」是对旧正文的同意。
    static var isAccepted: Bool {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: acceptedKey) else { return false }
        let acceptedVersion = defaults.object(forKey: versionKey) as? Int ?? 0
        return acceptedVersion >= FanControl.disclaimerVersion
    }

    /// 落盘「已同意」。调用方（FanController.acceptDisclaimer）负责同步给助手。
    static func accept() {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: acceptedKey)
        defaults.set(FanControl.disclaimerVersion, forKey: versionKey)
    }

    /// 清空同意状态（例如界面提供「撤销同意」）。
    static func revoke() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: acceptedKey)
        defaults.removeObject(forKey: versionKey)
    }

    // MARK: - 门禁

    /// 写风扇的前提条件是否满足。false 时所有写操作必须拒绝。
    static var allowsFanWrites: Bool { isAccepted }

    /// 未同意时给界面/错误信息用的提示语。
    static let consentRequiredMessage = "需先同意风扇控制免责声明"

    // MARK: - 文案

    /// 免责声明标题。
    static let title = "风扇控制免责声明"

    /// 免责声明正文。
    ///
    /// 刻意不写法律套话：用户要能一眼看懂「会发生什么、可能坏在哪」，
    /// 而不是读一页没人会看的条款。
    static let text = """
    风扇控制要写 SMC（非公开接口），不同机型行为不一致。

    • 写错风扇键或速度，可能让风扇停转或异常加速，损伤硬件，严重时过热。
    • 温度达到 90°C 时，应用会强制把所有风扇拉到最大转速。
    • 应用全程使用租约：应用崩溃或被结束后，助手会自动把风扇交回系统自动控制。
    """

    /// 同意按钮文案。
    static let acceptButtonTitle = "我已阅读并同意"

    /// 未同意时页面上那行入口的文案。
    static let consentEntryTitle = "使用风扇控制需先阅读并同意免责声明"

    /// 「查看免责声明」入口文案（已同意后仍可随时重看）。
    static let reviewEntryTitle = "查看免责声明"

    /// 关闭风扇控制时界面要显示的提示。
    static let handoverNotice = "将把风扇交回系统自动控制"
}
