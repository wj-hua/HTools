# HTools 开发约定

## UI 开发必须遵循 apple-design

开发或修改任何界面（SwiftUI 视图、动画、手势、材质、字体）之前，先阅读并遵循：

<https://github.com/emilkowalski/skills/blob/main/skills/apple-design/SKILL.md>

使用 Claude Code 时，直接调用 `apple-design` skill。该 skill 面向 Web，落到 SwiftUI 时按下表对应：

| apple-design 原则 | 本项目的落地方式 |
| --- | --- |
| 默认临界阻尼弹簧，只有带动量的交互才回弹 | `Motion.standard` / `snappy` / `press`（`DesignSystem.swift`），不要直接写 `.easeInOut` 或自定义时长 |
| 按下即反馈，不等松手 | 可点击的自定义控件使用 `PressableButtonStyle` |
| 动画可被打断、从当前值出发 | 用弹簧驱动状态，不要锁住输入等动画结束 |
| 减弱动态效果 | 读取 `accessibilityReduceMotion`，改用 `.easeInOut(duration: 0.15)` 淡入淡出，去掉位移和回弹 |
| 材质与层级 | 使用系统材质（`.bar`、`.regularMaterial`）和系统语义色，不写死 RGB；不要叠加两层浅色半透明面 |
| 字体 | 系统字体；大字号收紧字距（`BigNumber`），数字用 `monospacedDigit` |
| 反馈有四类：状态、完成、警告、错误 | 状态用 `subtitle` / 进度；完成用 `.toast`；破坏性操作用 `confirmationDialog` 二次确认；错误用 `alert` |
| 简洁，不是极简 | 常用路径放前面，高级选项放在更深一层；每个元素都要有存在的理由 |
| 一致性 | 卡片一律用 `Card`，图标底板用 `IconTile`，指标用 `MetricCell`，不要各页面各写一套 |

## 其他约定

- 优先复用已有代码和系统框架，不引入第三方依赖。
- 浅色 / 深色模式都要检查；新页面至少截图验证一次。
- 侧边栏行里 `.tag()` 必须是最外层修饰符，否则带角标的行点击不会切换页面（见 `RootView.swift`）。
- 构建必须用固定证书签名（`scripts/build-app.sh`），否则“辅助功能”和“本地网络”权限会在每次构建后失效。
