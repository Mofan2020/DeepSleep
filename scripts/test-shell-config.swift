//
//  test-shell-config.swift
//  DeepSleep
//
//  ShellConfigService 的自测。
//  测的是真实源码 DeepSleep/Core/ShellConfigService.swift。
//
//  **绝对不能碰用户真实的 ~/.zshrc**：
//  所有读写测试都在 FileManager.default.temporaryDirectory 下造一个假 HOME，
//  通过 candidates(home:) 注入。只有 candidates() 默认参数那一条会读真实家目录
//  的**目录列表**（只 stat、不读内容、不写），用来验证生产路径的候选顺序。
//
//  运行： bash scripts/test-shell-config.sh
//

import Foundation

@main
struct ShellConfigTests {

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

        // MARK: - 候选清单

        print("\n== 候选清单 ==")

        // 生产路径：真实家目录。只 stat 不读内容。
        let realCandidates = ShellConfigService.candidates()
        checkEqual("默认候选是 7 个", realCandidates.count, 7)
        checkEqual(
            "默认候选顺序",
            realCandidates.map(\.name),
            [".zshenv", ".zprofile", ".zshrc", ".zlogin", ".bash_profile", ".bashrc", ".profile"]
        )
        let realHome = FileManager.default.homeDirectoryForCurrentUser.path
        check(
            "默认候选路径都在家目录下",
            realCandidates.allSatisfy { $0.url.path.hasPrefix(realHome) },
            realCandidates.map(\.url.path).joined(separator: ", ")
        )
        checkEqual("zsh 文件归 zsh", ShellConfigService.shellKind(for: ".zshrc"), ShellConfigShell.zsh)
        checkEqual("bash 文件归 bash", ShellConfigService.shellKind(for: ".bashrc"), ShellConfigShell.bash)
        checkEqual(".profile 归 bash", ShellConfigService.shellKind(for: ".profile"), ShellConfigShell.bash)

        // 假 HOME：后面所有读写测试都在这里做。
        let fakeHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("deepsleep-shellcfg-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: fakeHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fakeHome) }

        let candidates = ShellConfigService.candidates(home: fakeHome)
        checkEqual("假 HOME 下候选也是 7 个", candidates.count, 7)
        check(
            "假 HOME 下路径都在假目录下",
            candidates.allSatisfy { $0.url.path.hasPrefix(fakeHome.path) }
        )
        check("假 HOME 里文件都不存在", candidates.allSatisfy { !$0.exists })
        checkEqual(
            "假 HOME 下候选顺序不变",
            candidates.map(\.name),
            [".zshenv", ".zprofile", ".zshrc", ".zlogin", ".bash_profile", ".bashrc", ".profile"]
        )

        // MARK: - 读

        print("\n== 读 ==")

        let missing = ShellConfigFile(url: fakeHome.appendingPathComponent(".zshrc"), exists: false)
        var readMissingThrew = false
        do {
            _ = try ShellConfigService.read(missing)
        } catch {
            readMissingThrew = true
        }
        check("读不存在的文件抛错（不返回空串）", readMissingThrew)

        let zshrc = ShellConfigFile(url: fakeHome.appendingPathComponent(".zshrc"), exists: false)
        try? "export DEEP_SLEEP_TEST=1\n".write(to: zshrc.url, atomically: true, encoding: .utf8)
        checkEqual(
            "读已存在的文件",
            (try? ShellConfigService.read(zshrc)) ?? "<读失败>",
            "export DEEP_SLEEP_TEST=1\n"
        )

        // MARK: - 写

        print("\n== 写 ==")

        let target = ShellConfigFile(url: fakeHome.appendingPathComponent(".zshrc"), exists: true)
        try? ShellConfigService.write("# 新内容\n", to: target)
        checkEqual(
            "写入后回读一致",
            (try? ShellConfigService.read(target)) ?? "<读失败>",
            "# 新内容\n"
        )
        check("写完文件确实在磁盘上", FileManager.default.fileExists(atPath: target.url.path))

        // 备份内容 = 写入**前**的旧内容
        let backupURL = ShellConfigService.backupURL(for: target)
        check("备份文件已生成", FileManager.default.fileExists(atPath: backupURL.path))
        checkEqual(
            "备份内容是写入前的旧内容",
            (try? String(contentsOf: backupURL, encoding: .utf8)) ?? "<读失败>",
            "export DEEP_SLEEP_TEST=1\n"
        )
        checkEqual("备份路径带 .deepsleep.bak 后缀", backupURL.lastPathComponent, ".zshrc.deepsleep.bak")
        check("hasBackup 识别得到备份", ShellConfigService.hasBackup(for: target))

        // 写不存在的文件 = 新建
        let fresh = ShellConfigFile(url: fakeHome.appendingPathComponent(".zprofile"), exists: false)
        try? ShellConfigService.write("export FRESH=1\n", to: fresh)
        check("写不存在的文件会新建", FileManager.default.fileExists(atPath: fresh.url.path))
        checkEqual(
            "新建文件回读一致",
            (try? ShellConfigService.read(fresh)) ?? "<读失败>",
            "export FRESH=1\n"
        )

        // 空内容写入是允许的（用户可能想清空）
        try? ShellConfigService.write("", to: fresh)
        checkEqual(
            "空内容写入后回读是空串",
            (try? ShellConfigService.read(fresh)) ?? "<读失败>",
            ""
        )

        // MARK: - 权限

        print("\n== 权限 ==")

        let permFile = ShellConfigFile(url: fakeHome.appendingPathComponent(".bashrc"), exists: false)
        try? "#!/bin/bash\n".write(to: permFile.url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: permFile.url.path
        )
        try? ShellConfigService.write("#!/bin/bash\necho hi\n", to: permFile)
        let permAttrs = try? FileManager.default.attributesOfItem(atPath: permFile.url.path)
        let permValue = (permAttrs?[.posixPermissions] as? NSNumber)?.intValue ?? -1
        checkEqual("原子写入保留原文件权限 0600", permValue, 0o600)

        let newPermFile = ShellConfigFile(url: fakeHome.appendingPathComponent(".zlogin"), exists: false)
        try? ShellConfigService.write("export NEW=1\n", to: newPermFile)
        let newPermAttrs = try? FileManager.default.attributesOfItem(atPath: newPermFile.url.path)
        let newPermValue = (newPermAttrs?[.posixPermissions] as? NSNumber)?.intValue ?? -1
        checkEqual("新建文件权限是 0644", newPermValue, 0o644)

        // 备份文件不该被写坏
        checkEqual(
            "备份文件内容仍然是旧内容",
            (try? String(contentsOf: ShellConfigService.backupURL(for: target), encoding: .utf8)) ?? "<读失败>",
            "export DEEP_SLEEP_TEST=1\n"
        )

        // MARK: - 恢复备份

        print("\n== 恢复备份 ==")

        try? ShellConfigService.write("# 又改了\n", to: target)
        checkEqual(
            "再次写入后当前内容变了",
            (try? ShellConfigService.read(target)) ?? "<读失败>",
            "# 又改了\n"
        )
        var restoreThrew = false
        do {
            try ShellConfigService.restoreBackup(for: target)
        } catch {
            restoreThrew = true
        }
        check("恢复备份不抛错", !restoreThrew)
        checkEqual(
            "恢复后退回上一次写入前的内容",
            (try? ShellConfigService.read(target)) ?? "<读失败>",
            "# 新内容\n"
        )
        checkEqual(
            "恢复本身不覆盖备份",
            (try? String(contentsOf: ShellConfigService.backupURL(for: target), encoding: .utf8)) ?? "<读失败>",
            "# 新内容\n"
        )

        // .profile 全程没被写过 → 没有任何备份
        let noBackup = ShellConfigFile(url: fakeHome.appendingPathComponent(".profile"), exists: false)
        var noBackupThrew = false
        do {
            try ShellConfigService.restoreBackup(for: noBackup)
        } catch {
            noBackupThrew = true
        }
        check("没有备份时恢复抛错", noBackupThrew)

        // MARK: - 语法检查

        print("\n== 语法检查 ==")

        // 记下运行前的临时目录清单，后面比「新增了哪些」而不是数总数 ——
        // 数总数会被并发的其它进程误伤。
        let checkDirsBefore = Set(
            (try? FileManager.default.contentsOfDirectory(
                atPath: FileManager.default.temporaryDirectory.path))?
                .filter { $0.hasPrefix("deepsleep-shellcheck-") } ?? []
        )

        checkEqual(
            "好语法返回 nil（zsh）",
            ShellConfigService.syntaxCheck(content: "export A=1\nalias ll='ls -l'\n", shell: .zsh) == nil,
            true
        )
        check(
            "坏语法返回错误信息（zsh）",
            ShellConfigService.syntaxCheck(content: "if [ ; then\n", shell: .zsh) != nil
        )
        check(
            "坏语法错误里有 parse error（zsh）",
            ShellConfigService.syntaxCheck(content: "if [ ; then\n", shell: .zsh)?.contains("parse error") == true
        )
        checkEqual(
            "好语法返回 nil（bash）",
            ShellConfigService.syntaxCheck(content: "export A=1\nif [ -f ~/.bashrc ]; then\n  . ~/.bashrc\nfi\n", shell: .bash) == nil,
            true
        )
        check(
            "坏语法返回错误信息（bash）",
            ShellConfigService.syntaxCheck(content: "for do done\n", shell: .bash) != nil
        )
        checkEqual(
            "空内容语法检查通过",
            ShellConfigService.syntaxCheck(content: "", shell: .zsh) == nil,
            true
        )
        let labeled = ShellConfigService.syntaxCheck(content: "if [ ; then\n", shell: .zsh, label: ".zshrc")
        check(
            "错误信息里的临时路径换成了文件名",
            labeled?.contains(".zshrc") == true && labeled?.contains("deepsleep-shellcheck") == false,
            labeled ?? "<nil>"
        )

        // 用假 HOME 里的真文件做检查
        let badFile = ShellConfigFile(url: fakeHome.appendingPathComponent(".zshenv"), exists: false)
        try? "if [ ; then\n".write(to: badFile.url, atomically: true, encoding: .utf8)
        check(
            "对文件做语法检查能查出问题",
            ShellConfigService.syntaxCheck(file: badFile) != nil
        )
        let goodFile = ShellConfigFile(url: fakeHome.appendingPathComponent(".zshenv"), exists: false)
        try? "export OK=1\n".write(to: goodFile.url, atomically: true, encoding: .utf8)
        checkEqual(
            "对文件做语法检查没问题的返回 nil",
            ShellConfigService.syntaxCheck(file: goodFile) == nil,
            true
        )

        // MARK: - 符号链接

        print("\n== 符号链接 ==")

        // .zshrc 可能是 dotfiles 工具建的软链。写入要落到真实文件上，
        // 否则 rename 会把链接换成普通文件，用户的 dotfiles 仓库就断了。
        let realTarget = fakeHome.appendingPathComponent("dotfiles-zshrc")
        let linkPath = fakeHome.appendingPathComponent(".zshrc.link")
        try? "export REAL=1\n".write(to: realTarget, atomically: true, encoding: .utf8)
        try? FileManager.default.createSymbolicLink(at: linkPath, withDestinationURL: realTarget)
        let linkFile = ShellConfigFile(url: linkPath, exists: true)
        try? ShellConfigService.write("export REAL=2\n", to: linkFile)
        checkEqual(
            "写软链时内容落到真实文件",
            (try? String(contentsOf: realTarget, encoding: .utf8)) ?? "<读失败>",
            "export REAL=2\n"
        )
        let linkAttrs = try? FileManager.default.attributesOfItem(atPath: linkPath.path)
        check(
            "软链本身没被换成普通文件",
            (linkAttrs?[.type] as? FileAttributeType) == .typeSymbolicLink
        )

        // MARK: - 临时文件不残留

        print("\n== 临时文件清理 ==")

        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: fakeHome.path))?
            .filter { $0.contains(".deepsleep.tmp.") } ?? []
        checkEqual("写入后没有残留临时文件", leftovers.count, 0)

        // 语法检查的临时目录也要清掉。
        // 只比「本次运行新增了哪些」—— 直接数目录里的总数会被并发的其它进程误伤。
        let checkDirsAfter = (try? FileManager.default.contentsOfDirectory(
            atPath: FileManager.default.temporaryDirectory.path))?
            .filter { $0.hasPrefix("deepsleep-shellcheck-") } ?? []
        let newCheckDirs = Set(checkDirsAfter).subtracting(checkDirsBefore)
        checkEqual("语法检查没留下临时目录", newCheckDirs.count, 0)

        print(failures == 0 ? "\n测试结论: 全部通过" : "\n测试结论: \(failures) 项失败")
        // 手动清理，不能靠 defer —— exit() 不执行 defer。
        try? FileManager.default.removeItem(at: fakeHome)
        exit(failures == 0 ? 0 : 1)
    }
}
