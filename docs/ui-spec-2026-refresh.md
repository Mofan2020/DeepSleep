# Deep Sleep 界面换新规格（2026-11）

> 目标：macOS 26 原生玻璃风 + 更少的视觉噪声 + 更快的找路速度。
> 硬约束：**业务逻辑、状态字段、协议层、Core/Shared 一行都不动**。只改界面。

---

## 0. 视觉方向

原生 macOS 26：玻璃分层 + 更多原生控件。整页都用玻璃会互相干扰，
所以玻璃**只用在焦点元素**（首屏状态卡、侧边栏摘要），普通内容卡用材质 + 细描边。

三层容器，从外到内：

| 层级 | 用什么 | 出现在 |
| --- | --- | --- |
| L1 卡片 | `.glassCard()` | 页面上的每一个独立区块 |
| L2 卡内分区 | `.insetPanel()` | 卡片内部成组的次级信息 |
| L3 控件 | SwiftUI 原生 | Toggle / Picker / Slider / Gauge / Table / LabeledContent |

---

## 1. 令牌（`DeepSleep/Views/DesignSystem.swift`）

**页面里不允许再出现字面量的间距、圆角、阴影。**

```swift
DS.Space.xxs  // 2   DS.Space.xs   // 4   DS.Space.sm   // 8
DS.Space.md   // 12  DS.Space.lg   // 16  DS.Space.xl   // 20  DS.Space.xxl // 28

DS.Radius.control  // 8   输入框 / 按钮 / 图标底板
DS.Radius.chip     // 12  小标签底板
DS.Radius.card     // 16  卡片
DS.Radius.hero     // 20  页面焦点卡

DS.Tone.good       // 正常 / 生效中（绿）
DS.Tone.caution    // 需要注意 / 降级运行（橙）
DS.Tone.critical   // 失败 / 危险阈值（红）
DS.Tone.info       // 强调、进行中（accent）
DS.Tone.idle       // 未启用 / 静默（secondary）
DS.Tone.hairline   // 卡片细描边

DS.Metric.gaugeDiameter  // 环形仪表直径（72）
```

视图修饰符：

| 修饰符 | 用途 |
| --- | --- |
| `.glassCard(cornerRadius:)` | L1 卡片。**不要自己写 `.background(.regularMaterial)`** |
| `.insetPanel(cornerRadius:)` | L2 卡内分区 |
| `.glassSurface(cornerRadius:)` | macOS 26 玻璃。**一页最多用一次**（焦点元素） |
| `.metricNumber(_:)` | 等宽数字，读数不跳动 |
| `.caption2()` | 次要说明文字 |

组件：

| 组件 | 用途 |
| --- | --- |
| `SectionCard(title:subtitle:symbol:accent:accessory:)` | 页面主容器。`content` 永远是最后一个参数 |
| `Tag(text:color:)` | 小标签 |
| `StatusPill(text:isActive:color:)` | 状态灯 + 文案 |
| `AssertionRow(kind:)` | assertion 开关行（标记已合并成一个胶囊） |
| `SettingRow(title:detail:key:currentValue:isEditable:onApply:)` | 键值设置行 |
| `BannerView(banner:onDismiss:)` | 顶部横幅 |
| `MetricTile(title:value:unit:status:tint:progress:symbol:)` | 大数值块。**status 必填**（颜色不能是唯一区分手段） |
| `EmptyStateView(title:message:systemImage:actionTitle:action:)` | 空态，底层是系统 `ContentUnavailableView` |
| `SubsectionHeader(title:symbol:accessory:)` | 卡内小标题 |

### 1.1 总览页的专用结构（v1.11.1）

总览页重做过一次，这几个结构是它专用的，别处不要照抄成通用组件：

| 结构 | 位置 | 说明 |
| --- | --- | --- |
| 环形仪表 | `StatusHeroCard` | 原生 `Gauge` + `.accessoryCircularCapacity`。填充比例 = 生效的保持项 / 全部保持项，**是真实比例不是装饰** |
| 保持项卡片 | `AssertionCard` | 两列网格的一格：图标 + 标题 + 说明 + 状态胶囊 + 开关 |
| 环境状态条 | `DashboardView.statusStrip` | 电源 / 自动化 / 完全控制三项并成一条，视觉重量低于主状态 |

**环形仪表必须配文字。** 环只能靠颜色传达状态，颜色在深色模式和色觉障碍下都不可靠。
所以环旁边一定有 `StatusPill` 写的状态词 —— 这是规则 4 在仪表上的具体落法。

`AssertionRow`（`Components.swift`）保留但总览页不再用它：一列四个长行要滚动才看全，
而「哪几项开着」恰恰需要一眼看出。

---

## 2. 六条硬规则

1. **零字面量**。间距、圆角、阴影一律走 `DS.*`。新增页面级常量也要先进 `DesignSystem.swift`。
2. **颜色只表达语义**，不做装饰。不要为了「好看」给卡片挑颜色。
3. **卡片是唯一容器**。不要自己造第二种卡片背景。
4. **状态用「颜色 + 文字」双编码**。温度分档要写「正常 / 偏高 / 过高 / 紧急」，
   不能只把字染红。
5. **原生控件优先**。能用 `LabeledContent` / `Gauge` / `Table` /
   `ContentUnavailableView` / `Picker(.segmented)` 就不要手搓。
6. **动效尊重 `accessibilityReduceMotion`**，统一用 `DS.Animation`。

---

## 3. 每页的改造要求（统一套路）

1. **删掉重复状态**。同一个状态不要在页面里出现两次（标题区一个胶囊、
   卡片里又一个胶囊）。留信息量最大的那一处。
2. **卡片加 `accessory`**：需要在标题栏右侧放操作时用
   `SectionCard(title: ..., accessory: AnyView(button))`，不要在内容区
   单独拉一行放按钮。
3. **指标改 `MetricTile`**：原来手写的「标题 + 大数字 + 说明」三件套
   换成 `MetricTile`，它自带状态词和进度条。
4. **空态换 `EmptyStateView`**：不要自己画图标加一行字。
5. **列表能用 `Table` 就用 `Table`**（macOS 原生表格：可排序、可调列宽）。
   用 `Table` 时把列定义写在 `TableColumn` 里，单元格内容保持简洁。
6. **设置行用 `LabeledContent`** 或 `SettingRow`，不要三种控件混着用。
7. **开关用 `.toggleStyle(.switch)`**，多档选择用 `.pickerStyle(.segmented)`，
   数值用 `Stepper` 或 `Slider`，状态用 `Gauge`。
8. **触控目标不小于 28pt**，行高留白用 `DS.Space.sm` 以上。

---

## 4. 不能动的东西

- `DeepSleep/Core/`、`DeepSleep/Privileged/`、`DeepSleep/Auth/`、
  `Shared/`、`DeepSleepHelper/`：**一行都不改**。
- 视图文件里的**状态绑定**（`@State` / `@EnvironmentObject` / `@ObservedObject`）
  和**业务调用**（`controller.xxx`、`engine.xxx`）保持原样。
  只改「怎么显示」，不改「显示什么数据」。
- 已有的类型名（`SectionCard` / `Tag` / `StatusPill` / `SettingRow` /
  `BannerView` / `AssertionRow` / `ToolCard`）不要重命名。
- `DeepSleep/Views/ToolboxLayout.swift` 有独立回归测试
  （`scripts/test-toolbox-layout.swift`），**不要改它的逻辑**。
- `DeepSleep/LLMGateway/` 整块不参与编译，别碰。
- 注释里写明的历史约束（性能、IO 成本、ZStack 顺序）继续保留。

---

## 5. 验收

- 全项目编译通过：`xcodebuild -project DeepSleep.xcodeproj -scheme DeepSleep -configuration Debug CODE_SIGNING_ALLOWED=NO build`
- 仓库里 35 个 `scripts/test-*.swift` 回归全绿。
- 不新增字面量间距/圆角（可用 grep 自查）。
