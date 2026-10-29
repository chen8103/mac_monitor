# Mac Monitor

一个轻量、原生的 macOS 菜单栏系统负载工具。使用 SwiftUI 和 Darwin/IOKit 接口，无第三方运行时或 npm 依赖。

## 功能

- 菜单栏彩色图标，点击弹出监控面板，不占用 Dock。
- CPU 总占用率、逐核心负载及 1/5/15 分钟平均负载。
- 物理内存使用量与总容量。
- 磁盘读取、写入速率及双通道动态进度条。
- 网络下载、上传速率及双通道动态进度条。
- 主机名、系统运行时间、Darwin 版本和硬件架构。
- 每 3 秒自动刷新；面板关闭后暂停采样。
- 点击图标、点击面板外部或切换应用可收起面板。
- 面板内提供退出按钮。

## 系统要求

- macOS 14.0 或更高版本。
- 已在 Apple Silicon（arm64）上验证。
- 源码构建需要 Swift 6.0 或更高版本及 Command Line Tools。

## 安装

### 下载已构建版本

1. 下载 [MacMonitor-1.0.0.zip](https://github.com/chen8103/mac_monitor/releases/download/v1.0.0/MacMonitor-1.0.0.zip)。
2. 解压后得到 `MacMonitor.app`。
3. 双击启动，在屏幕顶部菜单栏找到应用图标。

当前应用未进行 Apple Developer ID 签名或公证，请仅运行自己信任的来源；也可以直接从源码构建。

### 从源码构建

```bash
git clone https://github.com/chen8103/mac_monitor.git
cd mac_monitor
./Scripts/build-app.sh
open dist/MacMonitor.app
```

构建产物位于 `dist/MacMonitor.app`。

## 使用

- 点击顶部菜单栏图标：打开或收起面板。
- 点击面板外部或切换到其他应用：收起面板。
- 点击右下角“退出”：结束应用。
- 首次采样时 CPU、磁盘和网络显示 `—`，获得第二个样本后显示实际速率。

速率自动使用 `B/s`、`KB/s`、`MB/s` 或 `GB/s`。磁盘和网络进度条按各自读写或上下行的当前峰值比例显示，最低刻度为 1 MB/s。

## 指标口径

- **CPU**：根据相邻两次 `host_processor_info` 采样的 tick 差值计算。
- **内存**：活跃页、有线页和压缩器实际占用页之和，以 GiB 显示。
- **磁盘**：通过 IOKit 汇总块设备累计读写字节，按实际采样间隔计算速率。
- **网络**：通过 `getifaddrs` 汇总启用、运行中且非回环接口的累计收发字节，按实际采样间隔计算速率。
- 单项磁盘或网络读取失败不会影响其他指标；动态采样失败时保留最近一次有效快照。

所有指标均只在本机读取和展示，不上传监控数据。

## 测试与检查

运行零依赖检查脚本：

```bash
./Scripts/run-checks.sh
```

检查覆盖 CPU 与活动计数器差值、异常输入、速率单位换算、动态条比例、真实系统采样、刷新生命周期和失败恢复。

项目也保留 XCTest 用例。在具备完整 Xcode/XCTest 环境时可运行：

```bash
swift test
```

仅有 Command Line Tools 的 macOS 环境可能不包含 XCTest，此时请使用 `./Scripts/run-checks.sh`。

## 项目结构

```text
Sources/MacMonitor/
  MacMonitorApp.swift          菜单栏、弹窗与外部点击处理
  MonitorView.swift            面板布局
  MetricViews.swift            颜色与进度条组件
  MetricsStore.swift           定时刷新与失败恢复
  MetricsSamplingActor.swift   连续采样和速率计算
  SystemMetricsSampler.swift   CPU、内存和系统信息采样
  ActivityMetricsSampler.swift 磁盘与网络计数器采样
  MetricCalculations.swift     纯计算与格式化
  Models.swift                 不可变数据模型
Resources/                    应用配置与图标
Scripts/                      构建和检查脚本
Tests/                        XCTest 与零依赖检查
```

## 版本与发布

项目使用语义化版本号和 Git 标签管理发布。当前版本为 [`v1.0.0`](https://github.com/chen8103/mac_monitor/releases/tag/v1.0.0)，GitHub Release 附带经过 ZIP 完整性检查的应用包。
