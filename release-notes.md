## v1.8.1

修复 v1.8.0 带出的几个问题。

- AI 保活并发重复请求
  点「立即发送」原本不受正在进行的请求保护，连点或与定时发送撞上会重复发出去。现在同一任务同时只允许一个请求在飞。
- 工具箱排序数据
  `ToolboxLayout` 的 JSON 解码绕过了排序归一化，直接解码会拿到含未知工具或缺工具的数据。现在解码后也走一遍归一化。
- 配置写盘键序不固定
  保活配置与监控配置的 JSON 没有固定键序，「配置和默认值是否相同」的判断会随机出错。现在写盘固定键序，字节稳定。
- 结构体归位
  `MonitorConfig` 的定义搬到 `MonitorConfig.swift`，文件名和内容对上。
- 文档校验补盲区
  README 拆成中英双语后，AI 味检查的词表全是中文却去查英文 README，英文里的套话一条都拦不住。现在两份 README 都查，各用对应语言的词表；CLI 参数表也两份都查。
- 回归套件补全
  回归脚本之前漏掉 idle-time / selfupdate / auto-start-manager / cpu-temperature-decode / cgeventtap 五个既有功能的测试，现在一并收进 `scripts/run-all-tests.sh`。
