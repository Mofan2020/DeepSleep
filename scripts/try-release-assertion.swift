// 以「外部进程」身份尝试释放 Deep Sleep 持有的 assertion，
// 用于确认 IOKit 是否允许跨进程释放。
import Foundation
import IOKit.pwr_mgt

guard CommandLine.arguments.count > 1, let raw = UInt32(CommandLine.arguments[1]) else {
    print("用法: try-release <assertionID>")
    exit(2)
}

let identifier = IOPMAssertionID(raw)
print("本进程 pid=\(getpid()) 尝试释放 assertion id=\(identifier)（由另一个进程创建）")

let result = IOPMAssertionRelease(identifier)
let status: String
switch result {
case kIOReturnSuccess:           status = "kIOReturnSuccess（看起来成功了）"
case kIOReturnNotPermitted:      status = "kIOReturnNotPermitted（被拒绝）"
case kIOReturnNotFound:          status = "kIOReturnNotFound（找不到该 assertion）"
case kIOReturnNotPrivileged:     status = "kIOReturnNotPrivileged（权限不足）"
default:                         status = "其他返回码 0x\(String(result, radix: 16))"
}
print("IOPMAssertionRelease 返回: \(status)")
