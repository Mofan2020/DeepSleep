//
//  BiometricAuth.swift
//  Deep Sleep
//
//  生物识别授权封装。
//
//  设计意图：用户明确要求「管理员密码只输一次，后续尽量用指纹」。
//  一次性安装助手之后，所有提权操作都改由这里做本地授权确认
//  （Touch ID 优先，失败可回退到登录密码），无需再输管理员密码。
//

import Foundation
import LocalAuthentication

enum BiometricAuth {

    /// 当前设备可用的授权方式描述，用于 UI 文案。
    static var availableMethodDescription: String {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return "登录密码"
        }
        switch context.biometryType {
        case .touchID:  return "Touch ID"
        case .faceID:   return "Face ID"
        case .opticID:  return "Optic ID"
        default:        return "登录密码"
        }
    }

    /// 是否存在可用的生物识别硬件且已录入。
    static var isBiometryAvailable: Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return false
        }
        return context.biometryType != .none
    }

    /// 弹出授权确认。`.deviceOwnerAuthentication` 会优先走生物识别，
    /// 失败次数过多时自动回退到登录密码，避免用户被彻底卡住。
    static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = "取消"
        context.localizedFallbackTitle = "输入登录密码"

        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // 既没有生物识别也没有可用的密码验证时，不能假装成功。
            return false
        }

        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }
}
