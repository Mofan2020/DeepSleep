# DeepSleep v1.9 界面规格：温度监控 / 风扇控制 / 自定义告警规则 / 外部磁盘防休眠

> 产出人：designer（UI 设计师）
> 上游依据：`docs/protocol-contract-v1.9.md` §6 / §7 / §8 / §9 / §11（产品契约已钉死，本文只做界面规格，不重新定义需求）
> 既有设计语言来源：`DeepSleep/Views/Components.swift`、`MonitoringView.swift`、`ControlView.swift`、`PowerSettingsView.swift`、`AutomationView.swift`、`ContentView.swift`、`ToolboxView.swift`、`DashboardView.swift`
> 适用范围：四个界面（三个新页面 + 电源设置页新增一张卡）。全部复用既有组件，不新增设计体系。
> 目标平台：macOS 26.0（`project.yml` deploymentTarget），SwiftUI。

---

## 0. 实测事实（本规格的事实基线）

设计前在本机（macOS 27.2 / M2）跑了一遍温度通道，代码见 `docs/protocol-contract-v1.9.md` §3 的路径，结果如下：

| 项 | 实测值 | 对 UI 的含义 |
| --- | --- | --- |
| `PrimaryUsagePage 0xFF00` + `PrimaryUsage 5` 命中的 HID 服务数 | **132** | 命中集远大于温度传感器，UI 不能假设「返回的每一条都是温度」 |
| 返回非零温度读数的通道数 | **38** | 与契约里「38 个传感器」一致 —— 指的是**有效读数条数**，不是唯一名字数 |
| 按 `Product` 名去重后的传感器条目 | **33** | 界面按去重后的条目渲染（`gas gauge battery` 一个名字对应 6 条通道） |
| 返回 0.00 的通道 | 94 条 | 是电压/电流/角度/加速度类通道（`PMU ildo*` / `PMU vldo*` / `PMU ibuck*` / `PMU vbuck*` / `gyro` / `accel` / `als` / `wakehint` / `Headset` / `Apple Internal Keyboard / Trackpad` / `TouchBarUserDevice` / `devmotion*`），**不是温度** |
| 负读数 | `PMU tdev4 = -1.59`、`PMU tdev5 = -1.68` | 负值是无效读数，UI 必须显示「无有效读数」而不是把负温度画出来 |
| 温度区间 | 本次采样最低 28.00（电池）/ 最高 51.85（`PMU tcal`） | 常态远低于 75°C，所以阈值配色要能在 28–55 区间内也分出层次（分档不能只在 85+ 生效） |
| 风扇 | 本机 `FNum = 1`（`F0Mn = 1171.0`、`F0Mx = 7296.0`） | 滑杆区间必须来自 `FanState.Fan.minRPM/maxRPM`，不能写死 |

**共享常量（`Shared/FanModels.swift`，2026-10-27 读到的版本）** —— UI 直接引用，不复制数值：

| 常量 | 值 | 位置 | UI 用途 |
| --- | --- | --- | --- |
| `FanControl.leaseSeconds` | 15 | `Shared/FanModels.swift:30` | 兜底与回退卡里的租约说明 |
| `FanControl.emergencyTemperatureCelsius` | 90.0 | `Shared/FanModels.swift:39` | 紧急阈值（强制不可调） |
| `FanControl.minRpmSafetyRatio` | 0.95 | `Shared/FanModels.swift:45` | 写入转速下限系数 |
| `FanControl.emergencyCooldownSeconds` | 60.0 | `Shared/FanModels.swift:52` | **兜底解除冷却期** —— 温度掉到 90°C 以下后仍保持最大转速 60 秒再恢复原模式，UI 必须显示这个冷却倒计时 |
| `FanControl.disclaimerVersion` | 1 | `Shared/FanModels.swift:55` | 免责声明版本号（与契约 §7 一致） |

**由此产生的两条硬性实现约束**（写进规格，工程师照做）：

1. **过滤**：只把读数 `> 0.5` 的通道当温度传感器；其余丢弃，不进 UI，不进 `TemperatureSnapshot.readings`。
2. **合并**：同一 `Product` 名的多条通道合并成一行，取其中的**最高读数**作为显示值，行尾用 meta 标注「N 个通道」。

> 说明：契约 §2.2 写「读不到就是缺失，不许写 0」——0 在这里是「这个通道不是温度」，不是「读数是 0°C」。UI 层按上面两条处理即可，协议层不动。

---

## 1. 全局设计语言（沿用既有实现，不另起炉灶）

四个界面全部落在既有节奏上，工程师不要发明新数值：

| 项 | 值 | 出处 |
| --- | --- | --- |
| 页面内边距 | 22pt | `Components.swift:242` `pageLayout(maxWidth:)` |
| 内容最大宽度 | 760pt（工具箱 980pt） | `Components.swift:242`、`ContentView.swift:151` |
| 卡片之间垂直间距 | 16pt | `ContentView.swift:148` 的 `VStack(spacing: 16)` |
| 卡片内边距 | 18pt | `Components.swift:38` |
| 卡片圆角 | 16pt（continuous） | `Components.swift:40` |
| 卡片底纹 / 描边 | `.regularMaterial` + `Color.primary.opacity(0.08)` 描边 | `Components.swift:40-44` |
| 卡片标题 / 图标 | `.headline` / 15pt semibold，图标色 = `accent` | `Components.swift:20-29` |
| 卡片内元素间距 | 14pt（SectionCard 自身） | `Components.swift:19` |
| 小标签 `Tag` | 10pt semibold，内边距 7/2.5，胶囊，底色 `color.opacity(0.16)` | `Components.swift:49-61` |
| 状态胶囊 `StatusPill` | 圆点 8pt + 12pt medium 文字，内边距 10/5，底色 `opacity(0.14)` | `Components.swift:64-94` |
| 顶部横幅 `BannerView` | 圆角 12，内边距 14/11，底色 `opacity(0.12)` + 描边 `opacity(0.28)` | `Components.swift:191-235` |
| 强调色 | 系统语义色：`.accentColor` / `.orange` / `.purple` / `.indigo` / `.red` / `.green` / `.yellow` / `.pink` | 全项目通用 |
| 数值字体 | `.system(.title3, design: .monospaced).weight(.semibold)` + `.monospacedDigit()` | `MonitoringView.swift:159` |
| 辅助文字 | `.caption` / `.caption2` + `.secondary` / `.tertiary` | 全项目通用 |

**新增组件只有 5 个**（其余一律复用既有组件）：

| 新组件 | 用途 | 落点 |
| --- | --- | --- |
| `ThresholdDot` | 温度分档小圆点（正常/偏高/过高/紧急） | `DeepSleep/Views/ThermalView.swift`（实现侧已建） |
| `SensorRow` | 单个传感器读数行 | 同上 |
| `SensorGroupSection` | 一个分组的 `DisclosureGroup` + 行列表 | 同上 |
| `FanModePicker` | 自动/固定/规则 三段选择 | 风扇页视图文件（建议 `DeepSleep/Views/FanControlView.swift`） |
| `AlertRuleRow` / `AlertRuleEditorView` | 告警规则行 + 编辑 sheet | 告警规则页视图文件 |

> 命名对齐：实现侧已并行建出 `ThermalView.swift` / `AlertRule.swift` / `AlertRuleEngine.swift` / `FanDisclaimer.swift`。规格里给的类型名只是建议，**以既有实现为准，不要为了对齐规格去重命名已有文件**。

> 契约 §11 明确要求「沿用现有 `SectionCard` / `Tag` / `StatusPill` / `SettingRow` / `BannerView`，不要另起一套」。

---

## 2. 信息层级（跨页）

四级，跨四个界面统一：

1. **L1 状态**（一眼可判）：当前是否处于紧急降速、免责声明是否已同意、规则是否启用。
2. **L2 主数值**：最高温、当前转速、规则命中与否。
3. **L3 明细**：38 条读数、每个风扇的 min/max、规则的三个字段。
4. **L4 解释与边界**：90°C 兜底说明、租约说明、断言防什么不防什么。

**颜色不是唯一区分手段**（无障碍要求）：每一处分档同时给文字（正常 / 偏高 / 过高 / 紧急）。

---

## 3. 页面一：温度监控

### 3.1 侧边栏入口

- 位置：**侧边栏「诊断」段第一项**（`systemMonitor` 之前）。
- 理由：诊断段里其它三项（外部活动 / 运行日志 / 系统监控）都要读日志或扫进程；温度是纯读数、打开成本最低、也最常看，放段首。
- `SidebarItem` 新增：

```swift
case thermal        // 诊断段
var title: String { case .thermal: return "温度监控" }
var symbol: String { case .thermal: return "thermometer.medium" }
```

- `ContentView.swift` 改法（诊断段）：

```swift
Section("诊断") {
    Label(SidebarItem.thermal.title, systemImage: SidebarItem.thermal.symbol)
        .tag(SidebarItem.thermal)
    Label(SidebarItem.external.title, systemImage: SidebarItem.external.symbol)
        .tag(SidebarItem.external)
    Label(SidebarItem.log.title, systemImage: SidebarItem.log.symbol)
        .tag(SidebarItem.log)
    Label(SidebarItem.systemMonitor.title, systemImage: SidebarItem.systemMonitor.symbol)
        .tag(SidebarItem.systemMonitor)
}
```

- `detailContent` 增加 `case .thermal: ThermalMonitorView()`。
- 宽度：该页要放两列传感器网格，`ContentView.swift:151` 的宽度判断改为
  `selection == .toolbox ? 980 : (selection == .thermal ? 880 : 760)`。
  880 是本规格新增的唯一一处宽度偏离，理由见 §3.3。

### 3.2 页面结构图

```
┌ 温度监控 ──────────────────────────────────────────────────────────────┐
│ ┌ SectionCard「温度总览」───────────────────────────────────────────┐ │
│ │  subtitle: 33 个传感器 · 38 条有效读数 · 每 3 秒刷新 · 14:22:31   │ │
│ │                                                                   │ │
│ │  ┌──────────┐  ┌────┐  ┌──────────┐  ┌────┐  ┌──────────┐        │ │
│ │  │ 48.9 °C  │  │    │  │ 47.6 °C  │  │    │  │ 29.8 °C  │        │ │
│ │  │ 最高温    │  │    │  │ SoC 最高 │  │    │  │ 电池     │        │ │
│ │  │ 正常      │  │    │  │ 正常     │  │    │  │ 正常     │        │ │
│ │  └──────────┘  └────┘  └──────────┘  └────┘  └──────────┘        │ │
│ │  （GPU 最高 / 存储 两格按存在与否显示；分隔线用 Divider height 36） │ │
│ │                                                                   │ │
│ │  [StatusPill 紧急降速中 / 正常]      [Tag 阈值 75°C / 85°C]       │ │
│ └───────────────────────────────────────────────────────────────────┘ │
│                                                                           │
│ ┌ SectionCard「安全兜底 · 90°C 强制最大转速」 accent=orange ──────────┐ │
│ │  Label(icon)  任一传感器达到 90°C 时，所有风扇立即拉到最大转速，   │ │
│ │               并压过你设置的任何模式与规则。降温后有 60 秒冷却期。 │ │
│ │  状态行：StatusPill「未触发」/「已触发 · 正在降速」/「降温中 · 冷却 42 秒」 │
│ │  命中传感器：Tag「PMU tdie5 92.4°C」                              │ │
│ └───────────────────────────────────────────────────────────────────┘ │
│                                                                           │
│ ┌ SectionCard「传感器」 subtitle: 按类别分组 ─────────────────────────┐ │
│ │  ▾ SoC 与芯片 (31)          ← DisclosureGroup，默认展开           │ │
│ │      ○ 电源管理芯片 die 1     47.6 °C     正常                   │ │
│ │      ○ 电源管理芯片 die 2     46.0 °C     正常                   │ │
│ │      ...                                                            │ │
│ │  ▸ GPU (0)                  ← 空组整体不渲染                        │ │
│ │  ▾ 电池 (1)                                                       │ │
│ │      ○ 电池                  29.8 °C     正常   6 个通道           │ │
│ │  ▾ 存储 (1)                                                      │ │
│ │      ○ 固态硬盘              38.0 °C     正常                     │ │
│ │  （其它 0 条 → 整组不渲染）                                       │ │
│ └───────────────────────────────────────────────────────────────────┘ │
│                                                                           │
│ ┌ SectionCard「阈值」 accent=orange ────────────────────────────────┐ │
│ │  提示阈值   75 °C   [Slider 50…89]                                 │ │
│ │  过热阈值   85 °C   [Slider 60…89]                                 │ │
│ │  紧急阈值   90 °C   固定不可改（Tag「固定值」）                    │ │
│ └───────────────────────────────────────────────────────────────────┘ │
└───────────────────────────────────────────────────────────────────────┘
```

### 3.3 布局与视觉规格

**A. 温度总览卡**

- 复用 `MonitoringView.swift:74` `liveStatusCard` 的 `metricBlock` 模式：标题 `.caption` / `.secondary`，数值 `.system(.title3, design: .monospaced).weight(.semibold)`，说明 `.caption2` / `.tertiary`。
- 数值下方多一行**状态词**（`正常` / `偏高` / `过高` / `紧急`），`.caption2`，颜色同数值 —— 这是「颜色不是唯一区分手段」的落点。
- 格子之间用 `Divider().frame(height: 36)`，与 `MonitoringView.swift:86` 一致。
- 格子顺序固定：**最高温 → SoC 最高 → GPU 最高 → 电池 → 存储**。某类无传感器时该格整体不渲染（不留空格）。
- 「最高温」 = 全部有效读数的最大值（不是某类的），与 `TemperatureSnapshot.maxCelsius` 一致。
- 右侧不放按钮。刷新是自动的；需要手动刷新时用 `StatusPill` 右侧一个 `.controlSize(.small)` 的 `Label("刷新", systemImage: "arrow.clockwise")` 按钮（图标风格与 `AutomationView.swift:70` 一致）。
- 底部一行 `StatusPill`（正常 / 紧急降速中）+ 两个 `Tag`（提示阈值 / 过热阈值）。

**B. 安全兜底卡（90°C）**

- 这张卡**永远渲染**，不随状态隐藏 —— 用户要随时能看到「兜底存在、当前有没有在用」。
- accent 固定 `.orange`（与 `ControlView.swift:100` 「完全禁止系统睡眠」的警示色一致）。
- 标题：`安全兜底 · 90°C 强制最大转速`。
- 正文一行（`.caption` / `.secondary`）：`任一传感器达到 90°C 时，所有风扇立即拉到各自最大转速，并压过你设置的任何模式与规则。温度回落后有 60 秒冷却期，冷却结束才恢复原模式。`
- 状态行：
  - 未触发 → `StatusPill(text: "未触发", isActive: false)`（灰点）
  - 已触发 → `StatusPill(text: "已触发 · 正在强制降速", isActive: true, color: .red)`
  - 降温冷却中 → `StatusPill(text: "降温中 · 冷却 42 秒", isActive: true, color: .orange)` + 旁注 `.caption2` / `.secondary`：`冷却期结束前仍保持最大转速，避免在阈值附近反复启停。`（60 秒来自 `FanControl.emergencyCooldownSeconds`）
  - 命中传感器用 `Tag(text: "PMU tdie5 92.4°C", color: .red)`，多个则并列，最多显示 3 个 + `Tag("另有 2 个", color: .red)`。
- 触发时整张卡的描边换成 `.red.opacity(0.28)`（`.orange` → `.red`），卡片底色不变。

**C. 传感器分组卡**

- 一个 `SectionCard(title: "传感器", subtitle: "按类别分组。超出提示阈值会标黄，超出过热阈值会标红。")` 装全部分组。
- 分组用 `DisclosureGroup`，`DisclosureGroup` 的 label = `HStack { Text("SoC 与芯片").font(.subheadline.weight(.medium)); Tag(text: "24", color: .secondary) }`。
- **默认展开规则**：SoC 与芯片、电池、存储 默认展开；GPU、其它 默认折叠（量大且次要）。用户展开状态不持久化（每次进页回到默认）。
- **空组不渲染**（本机实测：GPU 0 条、其它 0 条 → 这两组整组不出现，不显示「GPU (0)」）。
- 组内行 = `SensorRow`，行高最小 28pt（`@Environment(\.dynamicTypeSize)` 变大时自适应增高，不裁切）。
- 行结构：

```
HStack(spacing: 10) {
    ThresholdDot(level: .normal)              // 8pt 圆点
    VStack(alignment: .leading, spacing: 1) {
        Text("电源管理芯片 die 1").font(.body)      // 可读名
        Text("PMU tdie1").font(.caption2).foregroundStyle(.tertiary)  // 原始名
    }
    Spacer(minLength: 8)
    Text("47.6").font(.system(.body, design: .monospaced).weight(.semibold)).monospacedDigit()
    Text("°C").font(.caption2).foregroundStyle(.secondary)
    Text("正常").font(.caption2)
}
```

- 原始名（`PMU tdie1`）**保留**在可读名下面一行 `.caption2` / `.tertiary` —— 用户报障时会用到原始名，但不该抢主视觉。
- 数值与状态词的着色见 §3.5 分档表。
- 「N 个通道」meta 放行尾 `.caption2` / `.tertiary`，仅在合并过通道时出现。
- 行**不排序随温度跳动**：组内按 `原始名` 稳定排序（`tdie1 < tdie2 < … < tdie8`；字母序不能把 `tdie10` 排在 `tdie2` 前面 —— 排序键用「前缀 + 数字」解析，数字部分按整数比）。

**D. 传感器名映射表（原始名 → 可读名 + 分组）**

分组枚举固定 5 个：`SoC 与芯片` / `GPU` / `电池` / `存储` / `其它`。

| 原始名模式 | 可读名 | 分组 |
| --- | --- | --- |
| `PMU tdie<N>` | 电源管理芯片 die <N> | SoC 与芯片 |
| `PMU2 tdie<N>` | 电源管理芯片 2 die <N> | SoC 与芯片 |
| `PMU tdev<N>` | 芯片温度传感器 <N> | SoC 与芯片 |
| `PMU2 tdev<N>` | 芯片温度传感器 2 <N> | SoC 与芯片 |
| `PMU tcal` / `PMU2 tcal` | 芯片校准温度 | SoC 与芯片 |
| `SOC MTR Temp Sensor<N>` | SoC 传感器 <N> | SoC 与芯片 |
| `eACC MTR Temp Sensor<N>` | CPU 能效核封装 <N> | SoC 与芯片 |
| `pACC MTR Temp Sensor<N>` | CPU 性能核封装 <N> | SoC 与芯片 |
| `ANE MTR Temp Sensor1` | 神经网络引擎 | SoC 与芯片 |
| `ISP MTR Temp Sensor5` | 图像信号处理器 | SoC 与芯片 |
| `PMGR SOC Die Temp Sensor<N>` | 电源管理 SoC die <N> | SoC 与芯片 |
| `GPU MTR Temp Sensor<N>` | GPU 传感器 <N> | GPU |
| `GPU ...`（其余 GPU 前缀） | GPU <原始名后缀> | GPU |
| `gas gauge battery` | 电池 | 电池 |
| `Charger TQ0d` | 充电器 | 其它 |
| `NAND CH0 temp` | 固态硬盘 | 存储 |
| `SSD ...` / `NVMe ...` | 固态硬盘 <后缀> | 存储 |
| 其它 | 原始名原样（不做翻译） | 其它 |

- 映射**按表逐条匹配，命中即停**；表里没有的原样显示，**不要显示成「未知」**。
- 规则里出现的「可读名」是 UI 层的展示映射（放在 UI 侧字典），不进 `TemperatureSnapshot` —— 协议层字段不变。

**E. 阈值卡**

- 复用 `MonitoringView.swift:245` 阈值卡的写法：`HStack { Text("提示阈值"); Spacer(); Text("75 °C").monospacedDigit() }` + `Slider`。
- `Slider(value:in:)` 范围：
  - 提示阈值 `50...89`，步进 1
  - 过热阈值 `60...89`，步进 1
- **约束**：过热阈值必须 > 提示阈值。改动时若新过热阈值 ≤ 提示阈值，把提示阈值自动压到 `过热阈值 - 1`（不弹窗、不报错，直接夹住）。
- 紧急阈值 90°C：`Slider` 禁用 + `.constant(90)`，旁边 `Tag(text: "固定值", color: .secondary)`，下方 `.caption2` / `.secondary` 一句：`90°C 来自安全兜底，不在此处调整。`
- 阈值改动立即生效并落盘（沿用 `MonitorConfig` 的 `saveIfNotDefault()` 写法，见 `MonitoringView.swift:318`）。

### 3.4 数据流与刷新

| 项 | 值 | 依据 |
| --- | --- | --- |
| 数据源 | 应用侧 IOHID 直读（**不走助手**，不需要 root） | 契约 §3 |
| 刷新间隔 | 3 秒（与 `SystemMonitor` tick 一致） | `MonitoringView.swift:175` |
| UI 刷新 | 每秒 tick 拉一次内存快照，绘制不重排列表 | `MonitoringView.swift:61-68` |
| 读数时间戳 | 显示「更新于 HH:mm:ss」 | `MonitoringView.swift:170-176` |
| 过期 | 超过 10 秒未刷新 → 卡片底部 `.caption2` / `.tertiary`：`数据未刷新（温度读取不可用）` | 同 `MonitoringView.swift:143` |

### 3.5 分档表（颜色 + 文字双编码）

| 档 | 条件 | 数值色 | 状态词 | 圆点 |
| --- | --- | --- | --- | --- |
| 正常 | `< 提示阈值` | `.primary` | 正常 | `.green` |
| 偏高 | `≥ 提示阈值` 且 `< 过热阈值` | `.yellow` | 偏高 | `.yellow` |
| 过高 | `≥ 过热阈值` 且 `< 90` | `.orange` | 过高 | `.orange` |
| 紧急 | `≥ 90` | `.red` | 紧急 | `.red` |
| 无效 | 读数 ≤ 0.5 或缺失 | `.secondary` | 无有效读数 | `.secondary.opacity(0.5)` |

- 颜色语义沿用 `MonitoringView.swift:178-205`（正常 `.primary`，超阈 `.orange`，磁盘 75–90% `.yellow`）。
- 「无效」档只在传感器**名字在映射表里但读数不可用**时出现（例如 `PMU tdev4` 读到 -1.59）—— 过滤阶段已经丢掉的电压通道不会进这里。
- 提示/过热阈值变化 → 所有行重新分档（视觉上即时生效，不重排）。

### 3.6 状态矩阵（温度页）

| 组件 | 默认 | 悬停 | 按下 | 禁用 | 加载 | 空态 | 错误 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 顶部「刷新」按钮 | `.bordered` + 小号 | 系统高亮 | 系统按压 | 读取进行中 → disabled | 转圈 `ProgressView().controlSize(.small)` | — | 读取失败 → disabled + `BannerView` 错误 |
| 分组 `DisclosureGroup` 箭头 | 展开态 ▼ | 系统高亮 | 展开/折叠动画 | — | — | 空组不渲染 | — |
| 传感器行 | 可读名 + 数值 + 状态词 | 行底 `.primary.opacity(0.04)` 高亮（`onHover`） | 同悬停但更浅 | 无（纯只读） | 首次读数前显示 `—` 与 `.secondary` | 无 | 通道读数无效 → 「无有效读数」 |
| 阈值 `Slider` | 可拖 | 滑块放大 1.15 | 拖动中 | 紧急阈值恒禁用 | — | — | — |
| 兜底卡 | 橙描边 + 「未触发」 | 不可交互 | — | — | — | — | 读不到温度 → 卡片下方加 `.caption2` / `.tertiary`：`兜底判定依赖温度读取，当前不可用` |

**页面级状态**

| 状态 | 判定 | 呈现 |
| --- | --- | --- |
| 加载中 | 首次读数未返回 | 总览卡数值显示 `—`；传感器分组卡显示 `ProgressView` + `正在读取温度传感器…`（`.caption` / `.secondary`） |
| 空态 | 有效读数 = 0 | 传感器卡内容区：`Image(systemName: "thermometer.slash")` 36pt `.secondary` + `当前读不到任何温度传感器` + `.caption` 说明 `这台机器可能不提供 IOHID 温度通道。` |
| 温度不可用 | 通道不可用或全部读数无效 | 同空态，文案区分「通道不可用」与「读数无效」 |
| 助手未就绪 | `helperState.isReady == false` | **温度页完全不受影响**（温度不走助手）。页面上**不出现**「需要完全控制」提示。只有兜底卡在温度不可用时提示。 |
| 紧急降速中 | 任一读数 ≥ 90 | 总览卡最高温格转 `.red` + 「紧急」；兜底卡转红并显示命中传感器；页面顶部出现 `BannerView(text: "已触发 90°C 强制最大转速，所有风扇已拉到最高转速。", level: .error)`（复用 `Components.swift:191`，`level: .error` → 红） |
| 数据过期 | > 10 秒未刷新 | 每张卡底部 `.caption2` / `.tertiary`：`数据未刷新（温度读取不可用）` |

---

## 4. 页面二：风扇控制

### 4.1 侧边栏入口

- 位置：**侧边栏「系统控制」段，紧跟「完全控制」之后**。
- 理由：写风扇转速要特权助手（SMC 写入走助手），顺序上「先授权 → 再调风扇」形成因果链，段内顺序即操作顺序。
- `SidebarItem` 新增：

```swift
case fanControl      // 系统控制段
var title: String { case .fanControl: return "风扇控制" }
var symbol: String { case .fanControl: return "fan" }
```

- `ContentView.swift` 系统控制段改法：

```swift
Section("系统控制") {
    ForEach([SidebarItem.control, .power, .fanControl, .schedule]) { item in
        Label(item.title, systemImage: item.symbol).tag(item)
    }
    Label(SidebarItem.serverMode.title, systemImage: SidebarItem.serverMode.symbol)
        .tag(SidebarItem.serverMode)
}
```

- `detailContent` 增加 `case .fanControl: FanControlView()`。
- 宽度：默认 760（单列内容足够）。

### 4.2 页面结构图

```
┌ 风扇控制 ──────────────────────────────────────────────────────────────┐
│ ┌ SectionCard「风扇安全须知」 accent=orange（未同意时置顶、橙底感）───┐ │
│ │  ⚠︎ 手动控制风扇有风险：写错转速或应用异常退出可能导致散热不足。   │ │
│ │  Deep Sleep 会用 15 秒租约兜底，租约到期自动交回系统自动控制。    │ │
│ │  [ 我已阅读并同意，开始使用手动控制 ]   ← 未同意时显示             │ │
│ │  （已同意时）[ 查看说明 ]  + Tag「已同意 v1」                      │ │
│ └───────────────────────────────────────────────────────────────────┘ │
│                                                                           │
│ ┌ SectionCard「风扇」 subtitle: 1 个风扇 · 当前：手动 ──────────────┐ │
│ │  ┌ 风扇 0（左侧散热） ─────────────────────────────────────────┐  │ │
│ │  │  HStack: 「风扇 0」 .body.weight(.medium)                   │  │ │
│ │  │         Tag「手动」(.orange)                                │  │ │
│ │  │         Spacer()                                           │  │ │
│ │  │         「3 200 RPM」 .system(.title3, design:.monospaced)  │  │ │
│ │  │  caption: 可用范围 1 171 – 7 296 RPM · 目标 3 200 RPM      │  │ │
│ │  │                                                             │  │ │
│ │  │  Picker 分段: [自动] [固定] [规则]                          │  │ │
│ │  │                                                             │  │ │
│ │  │  ── 固定模式 ──                                             │  │ │
│ │  │  HStack: 「目标转速」 [Slider 1171…7296]  「3 200 RPM」    │  │ │
│ │  │  caption: 松手后生效，写入时按 95% 下限兜底（≥ 1 112 RPM）  │  │ │
│ │  │                                                             │  │ │
│ │  │  ── 规则模式 ──                                             │  │ │
│ │  │  目标风扇  [Picker: 风扇 0]                                 │  │ │
│ │  │  最低温度  [Stepper 60…89] 「60 °C」                       │  │ │
│ │  │  最高温度  [Stepper 61…89] 「85 °C」                       │  │ │
│ │  │  ┌ 规则预览（.caption + 进度条）────────────────────────┐    │  │ │
│ │  │  │ 当前 47.6 °C → 目标 3 200 RPM                        │    │  │ │
│ │  │  │ [60 °C ├──────────● 85 °C]  映射到 1 112 – 7 296 RPM │    │  │ │
│ │  │  └─────────────────────────────────────────────────────┘    │  │ │
│ │  └─────────────────────────────────────────────────────────────┘  │ │
│ │  （多风扇时，每个风扇一块，块间 Divider）                          │ │
│ └───────────────────────────────────────────────────────────────────┘ │
│                                                                           │
│ ┌ SectionCard「温度规则」 subtitle: 1 条 · 启用 1 条 ────────────────┐ │
│ │  ● 风扇 0   60 °C → 85 °C   [Toggle 开]   [编辑] [删除]           │ │
│ │  （无规则时）空态：还没有温度规则。用下方「新建温度规则」把某个    │ │
│ │   风扇按温度区间调速。                                              │ │
│ │  [新建温度规则]                                                     │ │
│ └───────────────────────────────────────────────────────────────────┘ │
│                                                                           │
│ ┌ SectionCard「兜底与回退」 accent=orange ─────────────────────────┐ │
│ │  • 90°C 强制最大转速压过本页任何设置（见「温度监控」页）。         │ │
│ │  • 降温后有 60 秒冷却期，冷却结束才恢复你原来的模式。            │ │
│ │  • 租约 15 秒：应用退出后助手会在租约到期时把风扇交回系统自动控制。│ │
│ │  • 写入顺序由助手保证：先写模式键，再写目标键。                     │ │
│ │  • 应用启动时先释放上一次残留的控制权。                             │ │
│ └───────────────────────────────────────────────────────────────────┘ │
└───────────────────────────────────────────────────────────────────────┘
```

### 4.3 布局与视觉规格

**A. 风扇安全须知卡（免责声明）**

- 呈现方式：**页内警示卡 + 显式同意按钮**，不是弹窗。理由：契约 §7 要求「未经同意所有 `setFanSpeed` 一律拒绝，UI 上写风扇的控件禁用并显示『需先同意免责声明』」—— 弹窗式的一次性确认无法承载「禁用所有控件 + 持久化版本」的语义。
- 卡标题 `风扇安全须知`，accent `.orange`（与 `ControlView.swift:100` 一致）。
- 正文两条（`.caption` / `.secondary`）：
  1. `手动控制风扇有风险：写错转速或应用异常退出，可能导致散热不足。`
  2. `Deep Sleep 用 15 秒租约兜底，租约到期会自动把风扇交回系统自动控制。`
- 未同意时：
  - 底部一枚 `.borderedProminent` 按钮 `我已阅读并同意，开始使用手动控制`（点击 = 写 `fanControl.disclaimerAccepted = true` + `fanControl.disclaimerVersion = 1`）。
  - 卡片外描边 `.orange.opacity(0.28)`（默认描边就是 `primary.opacity(0.08)`，这里换成 orange）。
  - 卡片下面所有风扇控件 disabled。
- 已同意时：
  - 卡片压缩成一行：`.caption` 文本 `已同意风扇手动控制（版本 1）。` + `Tag(text: "已同意", color: .green)` + 一个 `.controlSize(.small)` 的 `Button("查看说明")` 重新展开全文。
  - 卡片默认折叠（正文隐藏），点「查看说明」展开。展开状态不持久化。
- 版本变更：契约 §7 说正文语义变化要把 `disclaimerVersion` +1，老用户下次进入要重新同意 —— UI 侧表现为：读到的 `disclaimerVersion > 已存的版本` 时，卡片自动回到「未同意」形态，按钮文案不变。

**B. 风扇块（每个风扇一块）**

- 卡片内标题行：`风扇 0`（`.body.weight(.medium)`）。名字来源：`FanState.Fan.name`（SMC 里的名字，读不到时是 `"Fan N"`）。显示时前缀统一成 `风扇 0`？ —— **不**：直接显示 `fan.name`，读不到时显示 `风扇 0`（契约给的就是 `"Fan N"`，`Shared/FanModels.swift:65`）。
- 标题行右侧：`Tag(text: "手动", color: .orange)` 或 `Tag(text: "自动", color: .secondary)`，来源 `FanState.Fan.isManual`。手动时额外 `Tag(text: "受控", color: .accentColor)`。
- 标题行最右：当前转速 `3 200` + `RPM`。
  - 数值用 `.system(.title3, design: .monospaced).weight(.semibold)` + `.monospacedDigit()`，与总览卡一致。
  - 单位 `RPM` 用 `.caption` / `.secondary`。
- 第二行 `.caption2` / `.tertiary`：`可用范围 1 171 – 7 296 RPM`（千分位分隔，`NumberFormatter`）。
- 模式选择：`Picker` + `.pickerStyle(.segmented)`，三项 `自动` / `固定` / `规则`，`.labelsHidden()`，宽度撑满。
  - 切换模式是**本地状态**，提交时才写 SMC（见 §4.6 提交语义）。
- **固定模式**：
  - `HStack { Text("目标转速"); Slider(value:in: minRPM...maxRPM, step: 10); Text("3 200 RPM") }`
  - `Slider` 的 `in:` **必须**用该风扇实测的 `minRPM...maxRPM`（本机 1171...7296），不写死。
  - 步长：`(maxRPM - minRPM) > 4000 ? 10 : 1`。
  - 下方 `.caption2` / `.secondary`：`松手后生效。写入时不低于 1 112 RPM（minRPM 的 95%）。` —— 95% 来自 `FanControl.minRpmSafetyRatio`（`Shared/FanModels.swift:45`），文案里的数字按当前风扇 minRPM 动态算。
- **规则模式**：三行，每行 `HStack { 标签(固定宽 64pt, .leading) ; 控件 ; Spacer() }`
  - `目标风扇` → `Picker`（`.pickerStyle(.menu)`，宽度 160pt）：列出本机全部风扇（`风扇 0` / `风扇 1`…）。默认当前风扇。
  - `最低温度` → `Stepper`（`in: 30...89`，`step: 1`），右侧显示 `60 °C`。
  - `最高温度` → `Stepper`（`in: 31...100`，`step: 1`），右侧显示 `85 °C`。
  - 约束：
    - 最高温度必须 > 最低温度，否则最高温度自动抬到 `最低温度 + 1`。
    - **最高温度上限 89**（不是 100）：超过 89 的话 90°C 兜底会先于规则触发，规则形同虚设。这是本规格加的一条约束，理由写在这里给工程师看。
  - 三个字段的控件 disabled 条件：免责声明未同意 / 助手未就绪 / 兜底正在接管。
- **规则预览**（`.caption` + 进度条，规则模式才显示）：
  - 一句话：`当前 47.6 °C → 目标 3 200 RPM`
    - 当前温度取**芯片组最高温**（与规则引擎取同一个值，见 §4.7）。
    - 目标转速按 §4.7 的映射算。
  - 一条水平刻度条：
    - 左端标签 `60 °C`（最低温度），右端 `85 °C`（最高温度）。
    - 一个圆点标出当前温度在区间中的位置；当前温度 < 最低时圆点贴左并标 `低于区间`；> 最高时贴右标 `高于区间`。
    - 条下标注 `映射到 1 112 – 7 296 RPM`。
  - 当前温度读不到时，预览区显示 `.caption2` / `.tertiary`：`当前温度不可用，无法计算目标转速。`

**C. 温度规则卡**

- 复用 `AutomationView.swift:77-134` 「规则」卡的写法（`SectionCard` + 行 + `Divider` + 底部按钮）。
- 行内容：`StatusPill` 不用；用 `HStack`：
  - 目标风扇名 `.body.weight(.medium)`
  - `Tag(text: "60 → 85 °C", color: .accentColor)`
  - `Tag(text: "已启用", color: .green)` / `Tag(text: "已停用", color: .secondary)`
  - 右侧 `Toggle`（`.toggleStyle(.switch)` + `.controlSize(.small)`）+ `Button("编辑")` + `Button(role: .destructive) { Image(systemName: "trash") }`
  - 编辑/删除按钮样式照抄 `AutomationView.swift:489-512`（`.buttonStyle(.borderless)`），但**图标按钮补命中区**（见 §9 触控热区）。
- 底部 `Button { Label("新建温度规则", systemImage: "plus") }` `.borderedProminent`。
- 空态文案：`还没有温度规则。用「新建温度规则」让某个风扇按温度区间自动调速。`（`.callout` / `.secondary`，与 `AutomationView.swift:85` 的「暂无规则」同风格）。
- **冲突规则**：同一个风扇不允许两条启用规则。创建第二条指向同一风扇时，编辑器的「目标风扇」Picker 里该风扇不可选（置灰 + 尾注 `已被另一条规则占用`）。

**D. 兜底与回退卡**

- 4 条 `BulletLine`（复用 `ControlView.swift:393` 的 `BulletLine` 组件），内容见结构图。
- 这是**说明卡**，永远渲染，accent `.orange`。

### 4.4 三个模式的确切语义

| 模式 | UI | 写入行为 | 退出/异常时 |
| --- | --- | --- | --- |
| 自动 | Picker 选「自动」 | 写 `rpm = 0`（契约 §1：0 表示交回系统自动控制），写 `F<n>Md = 0` | 系统自己管 |
| 固定 | 滑杆定一个 rpm | 写 `F<n>Md = 1` → 写 `F<n>Tg = rpm`（顺序由助手保证，契约 §4） | 租约 15 秒到期 → 助手写 `Md = 0` |
| 规则 | 三个字段 | 引擎按温度算 rpm，每次 tick 写一次（带租约） | 同上 |

- 三种模式互斥：一个风扇同一时刻只有一种模式。
- 选「自动」= 交回系统，**不需要免责声明已同意**（不写转速）。但页面上其它风扇若在手动模式，免责声明未同意时那些风扇的控件仍 disabled。**判定以「页面是否存在手动风扇」为准**：免责声明未同意 → 固定/规则不可用，自动仍可用。

### 4.5 状态矩阵（风扇页）

| 组件 | 默认 | 悬停 | 按下 | 禁用 | 加载 | 空态 | 错误 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 「我已阅读并同意」按钮 | `.borderedProminent` | 系统高亮 | 系统按压 | 写入偏好中 → disabled | 转圈 | — | 写入失败 → `BannerView` 错误，按钮恢复可点 |
| 模式 `Picker`（分段） | 选中当前模式 | 系统高亮 | 系统按压 | 兜底接管中 → 整组 disabled + 灰 | 提交中 → 禁用 | 无风扇时整卡不渲染 | 写入失败 → 回滚到旧模式 + `BannerView` |
| 固定模式 `Slider` | 停在当前目标 rpm | 滑块放大 | 拖动中 1:1 跟随 | 兜底接管 / 助手未就绪 / 未同意免责声明 | 提交中 → 禁用 | — | 写失败 → 滑杆回弹到读回值 |
| 规则三字段 | 显示当前值 | 系统高亮 | 系统按压 | 同上 | — | 无规则时字段区不渲染 | — |
| 规则行 `Toggle` | 开关态 | 系统高亮 | 系统按压 | 兜底接管中 | 提交中 → 禁用 | 规则为空 → 空态文案 | 写失败 → 回滚开关 |
| 规则行 编辑/删除按钮 | borderless 图标 | 背景高亮 | 按压 | 兜底接管中 | — | — | 删除失败 → `BannerView` |
| 兜底接管横幅（页面级） | 不显示 | — | — | — | — | — | `BannerView(level: .error)`：`已触发 90°C 强制最大转速，风扇已被接管，模式选择暂不可用。` |

**页面级状态**

| 状态 | 判定 | 呈现 |
| --- | --- | --- |
| 助手未就绪 | `helperState.isReady == false` | 风扇卡 subtitle：`当前为只读模式。启用完全控制后才能修改风扇。`；所有写入控件 disabled；卡内 `.caption` / `.orange`：`需要先启用完全控制。` |
| 免责声明未同意 | `fanControl.disclaimerAccepted != true \|\| version < 1` | 安全须知卡置顶展开；固定/规则控件 disabled + `.caption2` / `.orange`：`需先同意免责声明`（与契约 §7 文案一致） |
| 无风扇 | `FanState.fans.isEmpty` | 风扇卡内容区：`Image(systemName: "fan")` 36pt `.secondary` + `没有检测到可控制的风扇` + `.caption` `这台机器可能没有独立风扇，或 SMC 未暴露风扇键。` |
| 风扇区间非法 | `minRPM <= 0 \|\| maxRPM <= minRPM` | 该风扇块显示 `.caption` / `.orange`：`无法读取该风扇的转速范围，为安全起见不允许写入。` + 整块控件 disabled（对应 `FanState.writableFan(at:)` 返回 nil，`Shared/FanModels.swift:100`） |
| 读数失败 | 读取 `getFanState` 报错 | 风扇卡内容区显示上次值 + `.caption2` / `.tertiary`：`读不到风扇状态（上次更新 14:22:31）。` |
| 兜底接管中 | 任一传感器 ≥ 90 | 页面顶部 `BannerView(level: .error)`；每个风扇块内追加 `Tag(text: "兜底接管", color: .red)`；模式 Picker 与滑杆 disabled；「固定/规则」区加 `.caption2` / `.orange`：`降温后会自动恢复你原来的模式。` |
| 兜底冷却中 | 温度已回落但未过 60 秒冷却期 | 顶部 `BannerView(level: .info)`：`降温中，冷却 42 秒后恢复原模式。`；风扇仍处于接管态（控件保持 disabled），`Tag(text: "兜底接管", color: .orange)`（橙，不是红） |
| 写入中 | — | 受影响控件 disabled + `ProgressView().controlSize(.small)` |

### 4.6 提交语义（滑杆与切换）

- **滑杆拖动**：1:1 跟随本地值（不写 SMC）。松手（`Slider` 的 `onEditingChanged(false)`）才写一次。
- **写失败**：读回真实值，滑杆弹回读回值（弹簧动画，见 §8），同时 `BannerView(level: .error)` 显示原因。
- **租约刷新**：每次写都带 `lease = 15`（`FanControl.leaseSeconds`），应用侧还要周期性重发（契约 §5）。UI 不展示租约倒计时，只在兜底与回退卡里说明机制。

### 4.7 规则 → 转速的映射（预览与引擎必须一致）

规则字段：目标风扇 F、最低温度 Tmin、最高温度 Tmax。当前温度 T（取**芯片组最高温**，与 `TemperatureSnapshot` 里 SoC/芯片类的最大值一致）。

```
若 T <= Tmin  → 目标 = round(minRPM × 0.95)          // 安全下限
若 T >= Tmax  → 目标 = maxRPM
否则          → 目标 = round(minRPM×0.95 + (maxRPM − minRPM×0.95) × (T − Tmin) / (Tmax − Tmin))
```

- 映射用**线性插值**，与 UI 预览条一致。
- 写入前再夹一次下限：`max(目标, minRPM × 0.95)`。
- 预览条上「映射到 1 112 – 7 296 RPM」两个数字就是插值区间的两端。

### 4.8 侧边栏入口之外的联动

- 侧边栏底部 `SidebarFooter`（`ContentView.swift:210`）**不改** —— 风扇不属于 assertion（assertion 是「不让睡」，风扇是「散热」），放进去会误导。
- 「温度监控」页与「风扇控制」页共享同一份 `TemperatureSnapshot` 与同一个 3 秒 tick 源，避免两条通道各读一次。

---

## 5. 页面三：自定义告警规则

### 5.1 侧边栏入口

- 位置：**侧边栏「自动化」段，「自动化」之后、「快速退出」之前**。
- 理由：告警规则是「条件成立 → 通知」，与「自动化」同属事件驱动；放段内第二项，跟在总览性的「自动化」后面。
- `SidebarItem` 新增：

```swift
case alertRules     // 自动化段
var title: String { case .alertRules: return "告警规则" }
var symbol: String { case .alertRules: return "bell.badge" }
```

- `ContentView.swift` 自动化段改法：

```swift
Section("自动化") {
    Label(SidebarItem.automation.title, systemImage: SidebarItem.automation.symbol)
        .tag(SidebarItem.automation)
    Label(SidebarItem.alertRules.title, systemImage: SidebarItem.alertRules.symbol)
        .tag(SidebarItem.alertRules)
    Label(SidebarItem.quickQuit.title, systemImage: SidebarItem.quickQuit.symbol)
        .tag(SidebarItem.quickQuit)
}
```

- `detailContent` 增加 `case .alertRules: AlertRulesView()`。
- 侧边栏标题用 **「告警规则」**（3+2 字，比「自定义告警规则」短，侧边栏宽度 190–250pt 放得下且不挤）。页面内 `navigationTitle` 显示「告警规则」，页内首个 `SectionCard` 标题写「自定义告警规则」，产品全名不丢。

### 5.2 页面结构图

```
┌ 告警规则 ──────────────────────────────────────────────────────────────┐
│ ┌ SectionCard「自定义告警规则」 subtitle: 3 条 · 启用 2 条 ──────────┐ │
│ │  ┌ 行 ─────────────────────────────────────────────────────────┐   │ │
│ │  │ [图标] CPU 持续过高                          Tag「CPU」   │   │ │
│ │  │        高于 90 % · 持续 60 秒 · 通知+邮件                   │   │ │
│ │  │                        [Toggle 开] [✎] [🗑]                │   │ │
│ │  └────────────────────────────────────────────────────────────┘   │ │
│ │  Divider                                                            │ │
│ │  ┌ 行 ─────────────────────────────────────────────────────────┐   │ │
│ │  │ [图标] 内存接近上限（已停用）              Tag「RAM」       │   │ │
│ │  │        高于 85 % · 持续 30 秒 · 仅通知        Tag「已停用」 │   │ │
│ │  │                        [Toggle 关] [✎] [🗑]                │   │ │
│ │  └────────────────────────────────────────────────────────────┘   │ │
│ │  Divider                                                            │ │
│ │  [新建规则]（.borderedProminent）                                    │ │
│ └───────────────────────────────────────────────────────────────────┘ │
│                                                                           │
│ ┌ SectionCard「规则说明」 ────────────────────────────────────────────┐ │
│ │  • 持续时间：条件连续成立多少秒才告警，避免瞬时尖峰误报。          │ │
│ │  • 同一规则两次告警之间有 5 分钟冷却。                              │ │
│ │  • 温度类指标依赖温度通道可用；邮件动作依赖「完全控制」页的邮件配置。│ │
│ │  • 告警规则不会结束或冻结任何进程。                                │ │
│ └───────────────────────────────────────────────────────────────────┘ │
└───────────────────────────────────────────────────────────────────────┘
```

### 5.3 布局与视觉规格

**A. 规则卡**

- 完全照抄 `AutomationView.swift:77-134` 的结构：`SectionCard` + `ForEach` 行 + 行间 `Divider` + 底部 `HStack` 按钮区。
- 行 = `AlertRuleRow`（新组件，结构照 `AutomationView.swift:451` `RuleRow`）：
  - 左侧 24pt 宽图标，图标颜色：`启用且条件成立` → `.purple`（与 `RuleRow` 一致）；`启用但未成立` → `.accentColor`；`停用` → `.secondary`。
    - 指标图标：`cpuPercent` → `cpu`；`ramPercent` → `memorychip`；`singleProcessRAMGB` → `shippingbox`（用 `app.badge`？—— 统一用 `square.stack.3d.up` 表达「单进程」）；`cpuTemperature` → `thermometer.medium`；`diskUsagePercent` → `internaldrive`。
  - 主标题：规则名 `.body.weight(.medium)`，后跟 `Tag`：
    - 指标标签 `Tag(text: "CPU", color: .accentColor)` / `Tag(text: "RAM", color: .accentColor)` / `Tag(text: "单进程 RAM", color: .accentColor)` / `Tag(text: "CPU 温度", color: .orange)` / `Tag(text: "磁盘占用", color: .accentColor)`
    - `Tag(text: "已停用", color: .secondary)`（未启用时）
    - `Tag(text: "条件成立", color: .purple)`（运行中且当前条件已满足）
    - `Tag(text: "冷却中", color: .orange)`（刚触发过，5 分钟冷却窗口内）
  - 第二行 `.caption` / `.secondary`：`高于 90 % · 持续 60 秒 · 通知+邮件`
    - 比较符中文：`高于` / `低于`
    - 动作中文：`仅通知` / `仅邮件` / `通知+邮件`
    - 阈值带单位：% 指标带 `%`，单进程 RAM 带 ` GB`，温度带 ` °C`
  - 右侧：`Toggle`（`.toggleStyle(.switch)` + `.controlSize(.small)`）+ 编辑（`Image(systemName: "pencil")`）+ 删除（`Image(systemName: "trash")`，`role: .destructive`），全部 `.buttonStyle(.borderless)`，与 `RuleRow` 一致。
  - **邮件通道未配置**时，若该规则动作含邮件 → 行尾追加 `Tag(text: "邮件未配置", color: .orange)`。

**B. 规则编辑器（sheet）**

- 呈现方式：**sheet**，与 `AutomationView.swift:414-427` 一致（`.sheet(isPresented: $showEditor)` + `RuleEditorView` 模式）。不 inline —— inline 会把 6 个字段塞进列表行，列表行高度不可控，且保存/取消没有明确边界。
- sheet 尺寸：`.padding(22).frame(width: 480)`（同 `AutomationView.swift:619-620`）。
- 字段从上到下：

| 字段 | 控件 | 取值 | 校验 |
| --- | --- | --- | --- |
| 规则名称 | `TextField("例如：CPU 持续过高", text:)` `.textFieldStyle(.roundedBorder)` | 任意文本 | 空 → 保存按钮 disabled |
| 指标 | `Picker` `.pickerStyle(.menu)` | 5 项（见下表） | — |
| 比较 | `Picker` `.pickerStyle(.segmented)` | `高于` / `低于` | — |
| 阈值 | `Stepper` + 右侧数值 | 按指标定范围（见下表），步进 1（GB 步进 0.1） | 越界自动夹住 |
| 持续时间 | `Stepper`（秒） | `0...3600`，步进 10 | — |
| 动作 | `Picker` `.pickerStyle(.segmented)` | `仅通知` / `仅邮件` / `通知+邮件` | — |

- 每个字段上方一行 `.caption` / `.secondary` 的字段名（照 `RuleEditorView.swift:553-556` 的写法）。
- **阈值字段旁显示当前实测值**：`阈值 90 %（当前 23 %）`，当前值 `.caption2` / `.tertiary`；当前值读不到时写 `（当前读不到）`。
- 指标切换时，阈值范围、单位、默认值全部跟着换：
  - 切到新指标时，阈值重置到该指标的默认值（而不是保留上一个指标的数值 —— 单位不同，留着会出错）。

| 指标 | 中文 | 单位 | 阈值范围 | 默认 | 步进 | 图标 |
| --- | --- | --- | --- | --- | --- | --- |
| `cpuPercent` | CPU 使用率 | % | 1...100 | 90 | 1 | `cpu` |
| `ramPercent` | 内存使用率 | % | 1...100 | 85 | 1 | `memorychip` |
| `singleProcessRAMGB` | 单进程内存 | GB | 0.5...64 | 8 | 0.1 | `square.stack.3d.up` |
| `cpuTemperature` | CPU 温度 | °C | 40...105 | 85 | 1 | `thermometer.medium` |
| `diskUsagePercent` | 磁盘占用 | % | 1...100 | 90 | 1 | `internaldrive` |

- 持续时间下方加一行快捷 chip：`0` / `30` / `60` / `300` 秒（`.controlSize(.mini)` 小按钮，横排），点一下直接设值。默认 60 秒。
- 底部：`HStack { Spacer(); Button("取消") { }.keyboardShortcut(.cancelAction); Button(rule == nil ? "添加" : "保存") { }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }`（同 `RuleEditorView.swift:607-617`）。
- 保存按钮 disabled 条件：名称为空 **或** 阈值非法。
- 编辑已有规则时 sheet 标题：`编辑告警规则`；新建时：`新建告警规则`（`.title3.weight(.semibold)`，同 `RuleEditorView.swift:551-553`）。
- **动作含邮件但邮件通道未配置**时，sheet 里动作 Picker 下方显示 `.caption2` / `.orange`：`邮件通道未配置，邮件动作不会发出。邮件设置在「完全控制」页。`（不阻止保存 —— 用户可能稍后才配）。

**C. 说明卡**

- `SectionCard(title: "规则说明", symbol: "info.circle")` + 4 条 `BulletLine`（复用 `ControlView.swift:393`），内容见结构图。
- 「5 分钟冷却」来自契约 §8「沿用 `SystemMonitor` 的既有做法」。

### 5.4 状态矩阵（告警规则页）

| 组件 | 默认 | 悬停 | 按下 | 禁用 | 加载 | 空态 | 错误 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 规则行 `Toggle` | 反映 `isEnabled` | 系统高亮 | 系统按压 | 引擎未运行时 disabled | 保存中 disabled | 无规则时整行不渲染 | 写偏好失败 → 回滚 + `BannerView` |
| 规则行 编辑/删除按钮 | borderless 图标 | 背景高亮 | 按压 | 引擎未运行时 disabled | — | — | 删除失败 → `BannerView` |
| 「新建规则」按钮 | `.borderedProminent` | 系统高亮 | 系统按压 | — | — | — | — |
| 编辑 sheet 字段 | 见 §5.3 | 系统高亮 | 系统按压 | 指标不支持的字段 disabled（如温度指标无邮件配置则提示不禁用） | 保存中底部按钮转圈 | — | 校验失败在字段下方 `.caption` / `.red` |
| sheet 底部「保存」 | `.borderedProminent` | 系统高亮 | 系统按压 | 名称空 / 阈值非法 → disabled | 转圈 | — | 失败 → sheet 保持打开 + 顶部 `.caption` / `.red` 说明 |

**页面级状态**

| 状态 | 判定 | 呈现 |
| --- | --- | --- |
| 空态 | `rules.isEmpty` | 规则卡内容区：`Image(systemName: "bell.slash")` 36pt `.secondary` + `还没有自定义告警规则` + `.caption` / `.secondary` `固定阈值在「系统监控」页。这里可以按指标、持续时间和通知方式自由组合。` |
| 引擎未运行 | 监控总开关关闭 | 规则卡 subtitle：`系统监控未启用，规则不会触发。`（`.caption` / `.orange`）；行内 Toggle disabled |
| 温度不可用 | 温度通道不可用 | 含 `cpuTemperature` 指标的行追加 `Tag(text: "温度不可用", color: .orange)` |
| 邮件未配置 | 邮件渠道未配置 | 含邮件动作的行追加 `Tag(text: "邮件未配置", color: .orange)` |

---

## 6. 页面四：外部磁盘防休眠（开关）

### 6.1 放在哪：结论与理由

**结论：放在「电源设置」页（`PowerSettingsView`），新增一张独立的 `SectionCard`；不在总览页重复。**

理由三条：

1. **语义归属**：`PreventDiskIdle` 是电源/磁盘低功耗策略，和同页的「硬盘睡眠（disksleep）」「系统睡眠」是同一心智模型里的邻居，用户找得到。放在总览页会和「保持清醒」那组 assertion 混在一起 —— 那组是「阻止系统睡着」，这一个是「阻止磁盘睡着」，不是一回事。
2. **总览页已经有一行**：`AssertionKind.allCases` 已经包含 `preventDiskIdle`（`AssertionKind.swift:26`），`DashboardView.swift:27` 用 `ForEach(AssertionKind.allCases)` 渲染，所以总览页「保持清醒」卡里**已经会出现**这一行。再加一张卡就是两个入口。
3. **避免双入口打架**：状态回读（本地意图 vs 系统实际）需要额外一行提示文字，总览页的 `AssertionRow` 结构放不下（`Components.swift:97-147` 是固定的「图标 + 标题 + 副标题 + Toggle」四段式）。所以详细信息给电源设置页，总览那一行保持原样当快捷入口。

> 代价：用户可能只在总览页看到开关而不看边界说明。所以 `AssertionKind.preventDiskIdle` 的 `subtitle`（`AssertionKind.swift:60-61`）需要补上边界，见 §6.4。

### 6.2 结构图

```
┌ 电源设置 ──────────────────────────────────────────────────────────────┐
│  （现有「系统电源设置」卡 + 「依赖关系提示」卡，不动）                │
│                                                                           │
│ ┌ SectionCard「外部磁盘防休眠」 symbol: "internaldrive" ─────────────┐ │
│ │  ┌ 开关行 ────────────────────────────────────────────────────┐    │ │
│ │  │ [图标 internaldrive]  阻止磁盘空闲休眠              [Toggle] │    │ │
│ │  │                     已生效                                │    │ │
│ │  └────────────────────────────────────────────────────────────┘    │ │
│ │  正文（.caption / .secondary）:                                   │ │
│ │  阻止已连接磁盘因为空闲进入低功耗态，避免外置硬盘在传输中被唤醒  │ │
│ │  或掉电，也会减少再次访问时的唤醒延迟。                           │ │
│ │  它不阻止系统睡眠，也不能阻止电池耗尽时关机；它与上面的「硬盘睡眠」│ │
│ │  设置项不是一回事 —— 那一项是全局改 disksleep 的值。               │ │
│ │  状态行: Label(icon) 系统实际状态：已生效 / 未生效（14:22:31 校验）│ │
│ │  按钮: [重新应用]（仅当本地开、系统关时出现）                     │ │
│ └───────────────────────────────────────────────────────────────────┘ │
└───────────────────────────────────────────────────────────────────────┘
```

### 6.3 视觉规格

- 卡标题 `外部磁盘防休眠`，图标 `internaldrive`（与 `AssertionKind.symbolName` 一致，`AssertionKind.swift:70`），accent `.accentColor`。
- 开关行复用 `AssertionRow` 的视觉语汇但**不复用组件**（`AssertionRow` 内部绑死 `SleepController` 的 assertion 逻辑，这里需要「意图 vs 实际」两态）：
  - 左：16pt 图标，`.secondary`。
  - 中：标题 `.body.weight(.medium)` `阻止磁盘空闲休眠`；副标题 `.caption` / `.secondary` 放**实际状态**（`已生效` / `未生效` / `本地已开，系统未生效`）。
  - 右：`Toggle`（`.toggleStyle(.switch)`）。
- 正文 3 行，`.caption` / `.secondary`：
  1. `阻止已连接磁盘因为空闲进入低功耗态，避免外置硬盘在传输中被唤醒或掉电，也会减少再次访问时的唤醒延迟。`
  2. `它不阻止系统睡眠，也不能阻止电池耗尽时关机。`
  3. `它与上面的「硬盘睡眠」设置项不是一回事 —— 那一项是全局改 disksleep 的值。`
- **不得出现**「外置盘永不休眠」「外置盘不会休眠」这类表述（契约 §9 明确要求）。
- 状态回读行：
  - `.caption` / `.secondary`，`Label(icon, text)`，图标 `checkmark.circle` / `exclamationmark.triangle`。
  - 一致态：`系统实际状态：已生效（14:22:31 校验）`
  - 不一致态（本地开、系统里没有）：`系统实际状态：未生效 —— 可能被其它程序释放。` + 一枚 `Button("重新应用")`（`.controlSize(.small)`）+ `Tag(text: "需重新应用", color: .orange)`
  - 本地关、系统里有：`系统实际状态：已生效（其它程序持有）` + `.caption2` / `.secondary` `Deep Sleep 未持有该断言。`
- 回读来源：`pmset -g assertions`（不需要 root，契约 §9 实测可见 `PreventDiskIdle 1`）。轮询 15 秒一次 + 开关切换后立即回读一次。

### 6.4 配套改动（文案，非新增组件）

`AssertionKind.preventDiskIdle` 的 `subtitle`（`AssertionKind.swift:60-61`）现在是：
`外置硬盘不会因空闲而转入低功耗态，避免传输中断与唤醒延迟。`

**保留原文案**，但在总览页那一行下方还会显示电源设置页链接？—— 不加链接（总览行已经很长）。改法：把 subtitle 补一句边界：

```
外置硬盘不会因空闲而转入低功耗态，避免传输中断与唤醒延迟；不阻止系统睡眠，也不能阻止电池耗尽时关机。
```

> 这一行是 `Core/AssertionKind.swift`，不在本规格的改动范围内（别人在改），只在此登记，实施时由代码负责人落地。

### 6.5 状态矩阵（防休眠开关）

| 组件 | 默认 | 悬停 | 按下 | 禁用 | 加载 | 空态 | 错误 |
| --- | --- | --- | --- | --- | --- | --- |
| 开关行 `Toggle` | 关 | 系统高亮 | 系统按压 | 申请中 → disabled | `ProgressView().controlSize(.small)` | — | 申请失败 → 回滚 + `BannerView` |
| 「重新应用」按钮 | `.bordered` 小号 | 系统高亮 | 系统按压 | 申请中 → disabled | — | 仅不一致态出现 | 失败 → `BannerView` |
| 状态回读行 | `.caption` / `.secondary` | — | — | 回读中 → 文字换成 `正在核对系统实际状态…` | — | 回读失败 → `系统实际状态：核对失败（14:22:31）` | — |

---

## 7. Token 汇总

**「沿用」= 不改既有代码；「新增」= 本次要落地的 token。**

| 名称 | 默认值 | 可调 | 范围 | 用途 |
| --- | --- | --- | --- | --- |
| `page.padding` | 22 | 否 | — | 页面内边距（`pageLayout`） |
| `page.maxWidth` | 760 / 880（温度页）/ 980（工具箱） | 否 | — | 内容区最大宽度 |
| `card.gap` | 16 | 否 | — | 卡片之间垂直间距 |
| `card.padding` | 18 | 否 | — | SectionCard 内边距 |
| `card.cornerRadius` | 16 | 否 | — | SectionCard 圆角 |
| `card.strokeOpacity` | 0.08（兜底触发时 0.28） | 否 | — | 卡片描边 |
| `card.material` | `.regularMaterial` | 否 | — | 卡片底纹（不做全屏毛玻璃） |
| `row.minHeight` | 28 | 否 | — | 传感器行 / 规则行最小高（动态字体下自适应增高） |
| `tag.font` | 10pt semibold | 否 | — | Tag 文字 |
| `pill.font` | 12pt medium | 否 | — | StatusPill 文字 |
| `value.font` | `.title3` monospaced semibold | 否 | — | 主数值（温度 / 转速） |
| `threshold.dotSize` | 8 | 是 | 6...10 | 温度分档圆点 |
| `temp.refreshSeconds` | 3 | 是 | 1...10 | 温度刷新间隔 |
| `temp.threshold.warnCelsius` | 75 | 是 | 50...89 | 提示阈值（标黄线） |
| `temp.threshold.highCelsius` | 85 | 是 | 60...89 | 过热阈值（标红线） |
| `temp.threshold.emergencyCelsius` | 90 | **否（强制）** | — | 紧急兜底阈值，来源 `FanControl.emergencyTemperatureCelsius` |
| `temp.validReadingFloor` | 0.5 | 是 | 0.1...2.0 | 低于此值视为无效通道（过滤电压/电流类） |
| `temp.showInvalidSensors` | false | 是 | — | 是否显示「无有效读数」的传感器 |
| `temp.groups` | SoC 与芯片 / GPU / 电池 / 存储 / 其它 | 是（顺序可调） | — | 分组与顺序 |
| `temp.defaultExpandedGroups` | SoC 与芯片 / 电池 / 存储 | 是 | — | 默认展开的分组 |
| `temp.sensorRowColumns` | 2 | 是 | 1...2 | 传感器网格列数（宽度 < 680pt 自动降为 1 列） |
| `temp.staleAfterSeconds` | 10 | 是 | 5...60 | 数据过期判定 |
| `fan.mode.default` | 自动 | 是 | 自动/固定/规则 | 新风扇的默认模式 |
| `fan.fixed.rpmStep` | `maxRPM-minRPM > 4000 ? 10 : 1` | 是 | 1...100 | 滑杆步长 |
| `fan.rule.minTempCelsius` | 60 | 是 | 30...89 | 规则最低温度 |
| `fan.rule.maxTempCelsius` | 85 | 是 | 31...89 | 规则最高温度（上限 89，避免被 90 兜底抢跑） |
| `fan.rule.minSafetyRatio` | 0.95 | **否（强制）** | — | 写入转速下限，来源 `FanControl.minRpmSafetyRatio` |
| `fan.leaseSeconds` | 15 | **否（强制）** | — | 租约，来源 `FanControl.leaseSeconds`；UI 只读展示 |
| `fan.emergencyCooldownSeconds` | 60 | **否（强制）** | — | 兜底解除冷却期，来源 `FanControl.emergencyCooldownSeconds`；UI 只用于倒计时展示 |
| `fan.disclaimerVersion` | 1 | **否（强制）** | — | 免责声明版本，来源契约 §7 |
| `fan.disclaimerAccepted` | false | 是（用户操作） | — | 同意状态（`UserDefaults`） |
| `alert.duration.defaultSeconds` | 60 | 是 | 0...3600 | 规则默认持续时间 |
| `alert.duration.step` | 10 | 是 | 1...60 | 持续时间步进 |
| `alert.duration.quickChips` | 0 / 30 / 60 / 300 | 是 | — | 快捷值 |
| `alert.cooldownSeconds` | 300 | **否（强制）** | — | 冷却窗口，沿用 `SystemMonitor` 既有 5 分钟 |
| `alert.threshold.cpuPercent` | 90（1...100） | 是 | — | CPU 阈值 |
| `alert.threshold.ramPercent` | 85（1...100） | 是 | — | RAM 阈值 |
| `alert.threshold.singleProcessRAMGB` | 8（0.5...64） | 是 | — | 单进程 RAM 阈值 |
| `alert.threshold.cpuTemperature` | 85（40...105） | 是 | — | 温度阈值 |
| `alert.threshold.diskUsagePercent` | 90（1...100） | 是 | — | 磁盘占用阈值 |
| `disk.assertion.pollSeconds` | 15 | 是 | 5...60 | assertion 实际状态回读周期 |
| `accent` | 系统语义色 | 是 | — | 卡片强调色：兜底卡 `.orange`，兜底触发转 `.red` |

---

## 8. 状态矩阵汇总（每组件全状态）

### 8.1 温度页

| 组件 | 默认 | 悬停 | 按下 | 禁用 | 加载 | 空态 | 错误 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 顶部「刷新」按钮 | `.bordered` 小号 | 系统高亮 | 系统按压 | 读取中 disabled | 转圈 | — | 读取失败 disabled + `BannerView` |
| 总览数值格 | 数值 + 状态词 | 不可交互 | — | — | 显示 `—` | 无有效读数时整格显示 `—` | 数据过期 → 底部提示 |
| 分组 `DisclosureGroup` | 展开/折叠箭头 | 系统高亮 | 展开折叠 | — | — | 空组不渲染 | — |
| 传感器行 | 可读名 + 原名 + 数值 + 状态词 | 行底高亮 `primary.opacity(0.04)` | 同悬停更浅 | — | 首次读数前 `—` | — | 读数无效 → 「无有效读数」 |
| 阈值 `Slider`（提示/过热） | 可拖 | 滑块放大 | 拖动 | — | — | — | — |
| 阈值 `Slider`（紧急 90） | 固定 90 | 不可交互 | 不可交互 | **恒禁用** | — | — | — |
| 兜底卡 | 橙描边 + 「未触发」 | 不可交互 | — | — | — | — | 温度不可用 → 底部 tertiary 提示 |
| 页面级横幅 | 无 | — | — | — | — | — | 兜底触发 → `BannerView(level: .error)` |

### 8.2 风扇页

| 组件 | 默认 | 悬停 | 按下 | 禁用 | 加载 | 空态 | 错误 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 同意按钮 | `.borderedProminent` | 系统高亮 | 系统按压 | 写入中 disabled | 转圈 | — | 写失败 → `BannerView` + 恢复可点 |
| 「查看说明」按钮 | `.bordered` 小号 | 系统高亮 | 系统按压 | — | — | — | — |
| 模式 `Picker`（分段） | 当前模式 | 系统高亮 | 系统按压 | 兜底接管 / 引擎未运行 | 提交中 disabled | 无风扇不渲染 | 写失败回滚 + `BannerView` |
| 固定 `Slider` | 当前目标 rpm | 滑块放大 | 拖动 1:1 | 兜底接管 / 助手未就绪 / 未同意免责 | 提交中 disabled | — | 写失败 → 弹回读回值 |
| 规则 `Picker`（目标风扇） | 当前风扇 | 系统高亮 | 系统按压 | 同上 | — | 无规则不渲染 | — |
| 规则 `Stepper`（最低/最高温度） | 当前值 | 系统高亮 | 系统按压 | 同上 | — | 同上 | — |
| 规则预览条 | 圆点位置 | 不可交互 | — | 温度不可用 → 显示说明文字 | — | — | — |
| 规则行 `Toggle` | 反映状态 | 系统高亮 | 系统按压 | 兜底接管 | 提交中 disabled | 空态文案 | 写失败回滚 |
| 规则行 编辑/删除 | borderless 图标 | 背景高亮 | 按压 | 兜底接管 | — | — | 删除失败 → `BannerView` |
| 兜底接管横幅 | 不显示 | — | — | — | — | — | `BannerView(level: .error)` |

### 8.3 告警规则页

| 组件 | 默认 | 悬停 | 按下 | 禁用 | 加载 | 空态 | 错误 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 规则行 `Toggle` | 反映 `isEnabled` | 系统高亮 | 系统按压 | 引擎未运行 | 保存中 disabled | 无规则不渲染 | 写失败回滚 + `BannerView` |
| 规则行 编辑/删除 | borderless 图标 | 背景高亮 | 按压 | 引擎未运行 | — | — | 删除失败 → `BannerView` |
| 「新建规则」 | `.borderedProminent` | 系统高亮 | 系统按压 | — | — | — | — |
| 编辑 sheet 字段 | 见 §5.3 | 系统高亮 | 系统按压 | 不适用字段禁用 | — | — | 校验错误在字段下方 `.red` |
| sheet 「保存」 | `.borderedProminent` | 系统高亮 | 系统按压 | 名称空 / 阈值非法 | 转圈 | — | 失败保持打开 + 顶部 `.red` |

### 8.4 防休眠开关

| 组件 | 默认 | 悬停 | 按下 | 禁用 | 加载 | 空态 | 错误 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 开关行 `Toggle` | 关 | 系统高亮 | 系统按压 | 申请中 disabled | `ProgressView` 小号 | — | 申请失败回滚 + `BannerView` |
| 「重新应用」 | `.bordered` 小号 | 系统高亮 | 系统按压 | 申请中 disabled | — | 仅不一致态出现 | 失败 → `BannerView` |
| 状态回读行 | `.caption` / `.secondary` | — | — | 回读中 → 「正在核对…」 | — | 回读失败 → 「核对失败」 | — |

---

## 9. 动效规格

| 元素 | 动效规格 | 可打断 | reduced-motion 行为 |
| --- | --- | --- | --- |
| 数值变化（温度 / 转速） | **不做位移动画**。数值用 `.monospacedDigit()` 保证不跳宽；颜色变化 0.2s `easeOut` 交叉淡入 | 是（颜色过渡随时可被新值覆盖） | 保留 0.2s 颜色淡入（颜色变化帮助理解，不属于前庭刺激） |
| 卡片入场 | `opacity 0→1` + `y +8→0`，`.spring(response: 0.3, dampingFraction: 0.85)`（沿用 `ToolboxView.swift:91-97` 的参数） | 是（弹簧从当前 presentation 值继续） | 降级为 `.easeOut(duration: 0.15)` 的纯淡入（与 `ToolboxView` 的 reduceMotion 分支一致） |
| 分组展开 / 折叠 | `DisclosureGroup` 默认动画（系统 spring） | 是 | 系统在 reduce motion 下自动降级 |
| 传感器行悬停高亮 | `primary.opacity(0.04)`，`.easeOut(duration: 0.12)` | 是 | 保留（颜色淡入，无位移） |
| 阈值跨越分档 | 数值色 + 状态词色 0.25s `easeOut` 交叉淡入 | 是 | 保留 |
| 兜底触发（横幅 + 卡片变红） | 横幅 `opacity 0→1`，`.spring(response: 0.28, dampingFraction: 0.85)`；卡片描边色 0.25s `easeOut` | 是 | 横幅降级为 0.2s 纯淡入；描边色变化保留 |
| 模式切换（分段控件） | 系统默认 | 是 | 系统处理 |
| 滑杆拖动 | **无动画**，1:1 跟随手指 | 不适用 | 不适用 |
| 滑杆写失败回弹 | 弹簧 `.spring(response: 0.3, dampingFraction: 0.8)`，从当前值回到读回值 | 是 | 降级为 0.15s `easeOut` 位置过渡 |
| 规则预览圆点移动 | `.spring(response: 0.25, dampingFraction: 0.9)`，圆点 x 位置随温度变化 | 是 | 降级为 0.15s `easeOut` |
| 规则行增删 | 行高 + `opacity`，`.spring(response: 0.3, dampingFraction: 0.9)` | 是 | 降级为 0.15s `easeOut` 淡入淡出 |
| 编辑 sheet 出现 / 消失 | 系统 sheet 动画 | 是 | 系统处理 |
| 免责声明卡展开 / 折叠 | `opacity` + `height`，`.spring(response: 0.32, dampingFraction: 0.9)` | 是 | 降级为 0.15s 淡入淡出 |
| Toggle 切换 | 系统默认 | 是 | 系统处理 |
| 加载转圈 | 系统 `ProgressView` | 是 | 系统处理 |

**统一动效参数**（本次新增部分，全部沿用项目既有参数）：

| 参数 | 值 |
| --- | --- |
| 卡片入场 spring | `.spring(response: 0.3, dampingFraction: 0.85)` |
| 数值 / 行高 spring | `.spring(response: 0.3, dampingFraction: 0.9)` |
| 失败回弹 spring | `.spring(response: 0.3, dampingFraction: 0.8)` |
| 常规淡入 | `.easeOut(duration: 0.12)`（悬停）/ `0.2`（数值）/ `0.25`（分档） |
| reduce motion 降级 | `.easeOut(duration: 0.15)` |

- **不做的动效**：不做循环呼吸 / 脉冲动画（`apple-design` 明确反对 < 0.2 Hz 的持续循环）；不做全屏毛玻璃；不做横向飞入。
- 实现方式统一用 `@Environment(\.accessibilityReduceMotion) private var reduceMotion`（`ToolboxView.swift:48` 已有这个写法）。

---

## 10. 无障碍

### 10.1 对比度

| 元素 | 前景 | 要求 |
| --- | --- | --- |
| 正文 / 副标题 | `.primary` / `.secondary` 在 `.regularMaterial` 上 | ≥ 4.5:1（`secondary` 在浅色 material 上约 5.1:1，达标） |
| 辅助说明（原始名、meta） | `.tertiary` | ≥ 4.5:1 **仅当字号 ≥ 12pt**；`.caption2` 在 macOS 约 11pt，**`.tertiary` 只用于装饰性信息**（原始 sensorID、通道数、时间戳），**不得承载唯一信息** |
| 数值 | `.primary` / 分档色 | 分档色（黄/橙/红）在浅色背景上作为**辅助**，判定信息由状态词承载，颜色不承担唯一区分 |
| 分档状态词 | 与数值同色 | 同上 |
| 禁用态 | 系统 `.disabled` 效果 | 不依赖透明度单独传达状态，旁必有文字说明 |

- 结论性文字**不放在 `.tertiary`**。
- 深浅色模式：全部用语义色（`.primary` / `.secondary` / `.tertiary` / `.accentColor` / `.orange` / `.red` / `.green` / `.yellow`），不硬编码色值。

### 10.2 动态字体

- **禁止** `.font(.system(size: N))` 写死字号 —— 既有代码里 `Tag`（10pt）、`StatusPill`（12pt）、`SectionCard` 图标（15pt）是写死的，这是**既有实现**，本次新组件不要照抄这个坏习惯：
  - 新增的 `SensorRow` / `AlertRuleRow` 全部用语义字体：`.body` / `.callout` / `.caption` / `.caption2`。
  - `ThresholdDot` 是纯图形，不含文字，不受字号影响。
- 数值用 `.system(.title3, design: .monospaced).weight(.semibold)` —— `.title3` **会**随 Dynamic Type 缩放（`system(size:)` 不会）。
- 布局随字号变化：
  - 传感器行用 `HStack` + `Spacer(minLength: 8)`，长可读名 `.lineLimit(1) + .truncationMode(.tail)`，字号变大时可读名换行（`.fixedSize(horizontal: false, vertical: true)`），**不裁切**。
  - 风扇块里的「标签 + 控件」行在 AX3 及以上改为 `VStack`（`@Environment(\.dynamicTypeSize)` 判断），避免控件被挤成 0 宽。
  - 总览数值格：`.frame(maxWidth: .infinity, alignment: .leading)`，字号变大时格子自动换行，不加固定高度。
  - 触控/点击目标高度不小于 28pt（`.frame(minHeight: 28)`），不写死行高。
- 测试点：AX1 / AX3 / AX5 下，温度页、风扇页、告警规则页不得出现截断、重叠或横向滚动条。

### 10.3 VoiceOver 标签

| 元素 | label | value / hint |
| --- | --- | --- |
| 传感器行 | 「电源管理芯片 die 1，PMU tdie1」 | value：「47.6 度，正常」；hint：「阈值 75 度」 |
| 温度分档圆点 | 由行整体承载，**单独标 hidden**（`.accessibilityHidden(true)`） | — |
| 总览数值格 | 「最高温」 | value：「48.9 度，正常」 |
| 兜底卡状态 | 「90 度强制最大转速」 | value：「未触发」/「已触发，正在强制降速」；触发时 hint：「所有风扇已拉到最高转速」 |
| 分组 `DisclosureGroup` | 「SoC 与芯片，24 个传感器」 | 系统默认折叠/展开状态 |
| 风扇块 | 「风扇 0」 | value：「3200 转每分钟，手动模式」；hint：「可用范围 1171 到 7296 转每分钟」 |
| 模式 `Picker` | 「风扇 0 的模式」 | value：「固定速度」 |
| 固定 `Slider` | 「风扇 0 的目标转速」 | value：「3200 转每分钟」；hint：「松手后生效」 |
| 规则字段 | 「目标风扇」/「最低温度」/「最高温度」 | value 取当前值 |
| 规则预览 | 「规则预览」 | value：「当前 47.6 度，目标 3200 转每分钟」 |
| 告警规则行 | 规则名 + 指标 | value：「高于 90 %，持续 60 秒，通知加邮件，已启用」 |
| Toggle（各页） | 沿用控件自身的 label（不要 `labelsHidden()` 后又不补 `accessibilityLabel`） | — |
| 防休眠开关 | 「阻止磁盘空闲休眠」 | value：「已生效」/「未生效」；hint：「它不阻止系统睡眠，也不能阻止电池耗尽时关机」 |
| 同意免责声明按钮 | 「我已阅读并同意，开始使用手动控制」 | hint：「写入风扇前必须先同意免责声明」 |

- 图标按钮（编辑 / 删除 / 置顶）必须有 `accessibilityLabel`（`ToolCard.swift:248-251` 已有示范：`置顶<n>` / `取消置顶<n>`）。
- 不可见的按钮（opacity 0）必须 `.accessibilityHidden(true)`（同 `ToolCard.swift:250-252`）。
- 一个卡片整体读太长的，用 `.accessibilityElement(children: .contain)` 让子元素各自可聚焦（`ToolCard.swift:254` 已有示范）。

### 10.4 触控 / 指针热区

macOS 是指针设备，但 HIG 仍要求可点击区域足够大。

| 元素 | 尺寸 | 说明 |
| --- | --- | --- |
| 图标按钮（编辑 / 删除 / 刷新 / 重新应用） | **命中区 ≥ 24×24pt**，视觉图标 12–14pt | 既有 `AutomationView.swift:489-512` 的 borderless 图标按钮**没有**补热区（只有图标本身 ~16pt）—— 新页面里的同类按钮**必须**补 `.frame(width: 24, height: 24).contentShape(Rectangle())`，参照 `ToolCard.swift:329-336` 的 pinIcon 写法 |
| 分段 `Picker` | 系统默认高度（约 22–24pt） | 不缩到 `.mini` |
| `Slider` | 系统默认 | — |
| `Toggle`（`.switch`） | 系统默认（约 26pt 高） | — |
| 「新建规则」/「新建温度规则」按钮 | `.borderedProminent`，系统默认高度（≥ 28pt） | 不加 `.controlSize(.mini)` |
| 行整体可点（温度行、规则行） | 最小 28pt 高 | `.frame(minHeight: 28)` |
| 快捷 chip（0/30/60/300 秒） | `.controlSize(.mini)` 但补 `.frame(minHeight: 22)` + `contentShape` | 视觉小、命中不小于 22pt |
| sheet 内字段 | 系统默认 | — |

---

## 11. 关键组件实现要点

### 11.1 `ThresholdDot`

```swift
struct ThresholdDot: View {
    enum Level { case normal, elevated, high, critical, invalid }
    let level: Level
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 8   // 随 Dynamic Type 微缩放大，上限 10

    private var color: Color {
        switch level {
        case .normal:   return .green
        case .elevated: return .yellow
        case .high:     return .orange
        case .critical: return .red
        case .invalid:  return .secondary.opacity(0.5)
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: min(size, 10), height: min(size, 10))
            .accessibilityHidden(true)     // 状态由行整体承载
    }
}
```

- 分档计算在**视图层**做（一个纯函数），不要在数据层塞显示色：

```swift
enum TempLevel { case normal, elevated, high, critical, invalid }

func level(for celsius: Double, warn: Double, high: Double) -> TempLevel {
    if celsius <= 0.5 { return .invalid }
    if celsius >= FanControl.emergencyTemperatureCelsius { return .critical }
    if celsius >= high { return .high }
    if celsius >= warn { return .elevated }
    return .normal
}
```

### 11.2 `SensorRow`

```swift
struct SensorRow: View {
    let display: SensorDisplay      // { displayName, rawName, celsius: Double?, level: TempLevel, channelCount: Int }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            ThresholdDot(level: display.level)
            VStack(alignment: .leading, spacing: 1) {
                Text(display.displayName)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(display.rawName)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(display.celsius.map { String(format: "%.1f", $0) } ?? "—")
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(tint)
                    Text("°C").font(.caption2).foregroundStyle(.secondary)
                }
                Text(statusWord).font(.caption2).foregroundStyle(tint)
            }
            if display.channelCount > 1 {
                Text("\(display.channelCount) 个通道").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 5)
        .frame(minHeight: 28, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(display.displayName)，\(display.rawName)")
        .accessibilityValue(accessibilityValue)
    }
}
```

- `statusWord`：`正常` / `偏高` / `过高` / `紧急` / `无有效读数`。
- `tint`：normal → `.primary`；elevated → `.yellow`；high → `.orange`；critical → `.red`；invalid → `.secondary`。
- 悬停高亮：`.onHover { hovering in withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering } }` + 背景 `.primary.opacity(isHovering ? 0.04 : 0)`。

### 11.3 传感器名映射与合并（数据层）

- 映射表放在 UI 侧的字典（`SensorNameMap`），**不进 `Shared/FanModels.swift`**（协议层字段不变）。
- 匹配顺序：先按 §3.3 D 表逐条 pattern 匹配，命中即停；未命中 → `displayName = rawName`，`group = .other`。
- 合并：同一 `rawName` 的多条通道 → 取最大读数，`channelCount` = 通道数。
- 过滤：`celsius <= 0.5` 的通道直接丢弃（不进列表）。
- 排序键：`SensorSortKey(rawName)` —— 拆出前缀与尾部数字，数字按整数比；没有数字的按字符串比。保证 `tdie2 < tdie10`。

### 11.4 `FanModePicker` 与模式提交

```swift
enum FanMode: String { case automatic, fixed, rule }

Picker("", selection: modeBinding) {
    Text("自动").tag(FanMode.automatic)
    Text("固定").tag(FanMode.fixed)
    Text("规则").tag(FanMode.rule)
}
.pickerStyle(.segmented)
.labelsHidden()
```

- `modeBinding` 的 setter **不直接写 SMC**：先置本地状态，再 `Task { await fanController.apply(mode:to:fanIndex) }`。
- 写成功后刷新 `FanState`；写失败 → 本地状态回滚 + `BannerView`。
- 兜底接管中：`modeBinding` 的 setter 直接 `return`（不改状态），并在 UI 上 disabled。

### 11.5 固定模式滑杆

```swift
Slider(
    value: $draftRPM,
    in: Double(fan.minRPM)...Double(fan.maxRPM),
    step: step,
    onEditingChanged: { editing in
        if !editing { Task { await commitFixedRPM() } }   // 松手才写
    }
)
.onChange(of: fan.currentRPM) { _, newValue in
    if !isEditing { draftRPM = Double(newValue) }            // 外部改动同步回来
}
```

- `draftRPM` 是本地 `@State`，初值取 `fan.currentRPM`。
- 写成功后把 `draftRPM` 设为读回值（不是请求值）。
- 写失败：`withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { draftRPM = Double(fan.currentRPM) }` + `BannerView`。
- 提交时夹下限：`let target = max(Int(draftRPM.rounded()), Int(Double(fan.minRPM) * FanControl.minRpmSafetyRatio))`。

### 11.6 规则预览

```swift
// 与引擎同一条映射，UI 与引擎共用一个函数（放在 UI 侧或 Shared 侧由代码负责人定，
// 但两边必须调用同一实现，不能各写一份）
func targetRPM(for temp: Double, minTemp: Double, maxTemp: Double, fan: FanState.Fan) -> Int {
    let floor = Double(fan.minRPM) * FanControl.minRpmSafetyRatio
    if temp <= minTemp { return Int(floor.rounded()) }
    if temp >= maxTemp { return fan.maxRPM }
    let ratio = (temp - minTemp) / (maxTemp - minTemp)
    return Int((floor + Double(fan.maxRPM - fan.minRPM) * ratio).rounded())
}
```

- 预览条用 `GeometryReader` 把温度映射成 x 坐标：`(temp - minTemp) / (maxTemp - minTemp)`，并把 [0,1] 夹住。
- 当前温度取**芯片组最高温**（`SensorGroup.soc` 的最大读数），与规则引擎取值一致。
- 温度不可用时：预览区替换成 `.caption2` / `.tertiary` 的 `当前温度不可用，无法计算目标转速。`

### 11.7 告警规则编辑器

- `AlertRuleEditorView` 的结构照抄 `AutomationView.swift:518-622` `RuleEditorView`：
  - `.padding(22).frame(width: 480)`
  - 标题 `.title3.weight(.semibold)`
  - 字段名 `.caption` / `.secondary` + 控件
  - 底部 `HStack { Spacer(); 取消 / 保存 }`，`.keyboardShortcut(.cancelAction)` / `.keyboardShortcut(.defaultAction)`
- 指标切换时重置阈值：`onChange(of: metric) { _, new in threshold = new.defaultThreshold }`。
- 持续时间用 `Stepper(value: $duration, in: 0...3600, step: 10)`，并在下方渲染 4 个快捷 chip。
- 动作 Picker 下方：邮件通道未配置 → `.caption2` / `.orange` 提示（不阻止保存）。

### 11.8 防休眠开关

```swift
Toggle("", isOn: Binding(
    get: { controller.activeAssertions.contains(.preventDiskIdle) },
    set: { newValue in Task { await controller.setAssertion(.preventDiskIdle, enabled: newValue) } }
))
.toggleStyle(.switch)
.labelsHidden()
.accessibilityLabel("阻止磁盘空闲休眠")
```

- 实际状态回读：`pmset -g assertions` 解析出 `PreventDiskIdle 1` 即为已生效。
- 回读周期 15 秒（`disk.assertion.pollSeconds`），切换后立即回读一次。
- 不一致态：`本地开 + 系统关` → 显示 `Tag("需重新应用", color: .orange)` + `Button("重新应用")`。
- `AssertionRow` 组件本身不改（它绑死 `SleepController` 的四态语义）；防休眠这张卡自己写一个 `Toggle` 行。

---

## 12. 需要拍板 / 需要代码负责人确认的点

1. **`AssertionKind.preventDiskIdle` 的 subtitle 补边界文案** —— 要改 `DeepSleep/Core/AssertionKind.swift:60-61`，不在本次改动范围（别人在改这个文件），需代码负责人落地。
2. **总览页已有 `preventDiskIdle` 一行**（`DashboardView.swift:27` 的 `ForEach(AssertionKind.allCases)` 自动渲染）。本规格的决定是「电源设置页放详细卡，总览页保留那一行快捷入口」。如果希望总览页不出现这一行，需要改 `DashboardView` 的渲染过滤 —— 那是产品决定，不是设计决定。
3. **规则最高温度上限 89** 是本规格加的约束（超过就被 90 兜底抢跑），契约没写。如果希望允许到 100，请拍板。
4. **规则模式取「芯片组最高温」作为驱动温度** —— 契约 §11 只说「温度区间决定该风扇的转速映射」，没说用哪个传感器。本规格取芯片组最高温。若要改成可指定传感器，需要改数据模型。
5. **温度页宽度 880**（其它页 760）—— 需要改 `ContentView.swift:151` 的宽度判断。若坚持统一 760，传感器网格就退化成单列，38 条读数要滚很久。
6. **`temp.validReadingFloor = 0.5`** 这个过滤阈值把「真实读数为 0.4°C」的传感器误杀。实测本机没有这种情况（电压通道是精确 0.00），但阈值可调，边界由用户承担。
7. **告警规则编辑器用 sheet 而不是 inline** —— 与 `AutomationView` 一致，但 sheet 里的字段有 6 个，比 `RuleEditorView` 复杂；需要确认 480pt 宽够放（规格里字段都是单列纵向堆叠，应该够）。
8. **实现已并行开工**：`ThermalView.swift` / `AlertRule.swift` / `AlertRuleEngine.swift` / `FanDisclaimer.swift` 在本次出稿期间已建出，风扇页视图尚未建。规格里的类型名以既有实现为准；如果实现侧已经选了不同的组织方式（比如把「规则预览」拆成独立文件），以实现为准，规格只约束「画出什么、什么状态下长什么样」。

---

## 13. 未做的事（明确边界）

- 没有写任何业务代码 —— 本文只有规格、token、结构图、SwiftUI 骨架片段，实现由工程师做。
- 没有动 `DeepSleep/` 下任何文件、`Shared/`、`scripts/`、`project.yml`。
- 没有验证 SMC 写入路径（契约 §4 明确说从未端到端验证过）—— 本规格里「写入成功 / 失败」的 UI 分支是按契约 §5 的失败语义设计的，实际行为要等写入路径验证后才能确认。
- 没有验证 `pmset -g assertions` 的实际输出格式（规格里按契约 §9 的「`PreventDiskIdle 1`」写解析假设）。
- 没有做深色模式截图验证 —— 规格里所有颜色都用语义色，深浅色自动适配，但真机观感需要实现后过一遍。