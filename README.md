# 桌面小灵宠 · Desktop Spirit Pet

一个使用 Windows PowerShell 和 WPF 编写的桌面小灵宠。透明、无边框的悬浮窗口配合动画，展示电脑实时硬件与网络状态，无需额外安装运行时。

## 功能

- 显示 CPU 使用率、频率、内存、GPU 使用率以及可读取的热区温度。
- 展示磁盘总用量，点击后展开各盘信息，同时显示磁盘读写活动。
- 显示网络速度、Wi-Fi 地址，以及识别到的 VPN 公网和隧道地址。
- 显示电池、开机时长和设备信息。
- 头顶常驻 Cursor Auto 剩余百分比和 Token API 每日剩余金额；点击小灵再查看高级模型、Grok Bot 周额度和设备详情。额度约每 30 秒后台更新，也可右键立即刷新。
- 支持拖动、收起、置顶、托盘找回和可选的开机启动。
- 支持滚轮、滑条和右键菜单缩放，范围为 10%–140%。

## 启动

适用于 Windows 桌面环境，使用系统自带的 Windows PowerShell 5.1 与 WPF。已在 Windows 11 上运行；不同设备的传感器可用性可能不同。

1. 下载仓库并解压，或克隆到本地。
2. 双击 `start.bat`。
3. 拖动小灵宠调整位置，单击在屏幕右上角展开/收起详情卡，右键打开菜单。详情卡的“×”只收起详情，退出小灵请用右键菜单。

也可以在项目目录运行：

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\pet.ps1
```

启动命令中的 `ExecutionPolicy Bypass` 仅作用于该 PowerShell 进程，不修改系统持久执行策略。脚本使用 UTF-8 BOM 编码，修改时请保留编码以兼容 Windows PowerShell。

## 额度显示

每次启动默认收起详情面板，头顶仅显示 Cursor Auto 和 Token API 两项剩余额度。点击小灵或头顶额度区，会在小灵所在屏幕的工作区右上角展开详情，小灵本体留在原位；再次点击或点击详情卡“×”收起。每次展开都会重新定位到右上角，缩放或内容变长时也会保持在屏幕内，超长内容可滚动查看。收起时两项额度仍持续更新，低额度和缓存状态有颜色提示。悬停各行可看说明与更新时间。

Cursor 额度默认启用。小灵只读本机 Cursor 已有的登录授权并查询额度，不修改登录数据，也不刷新 token；需要先在本机 Cursor 中登录。额度口径以 [Cursor 用量页面](https://cursor.com/dashboard/spending) 为准。

Cursor Auto 和高级模型使用当前计费周期的独立用量百分比，Grok AI 行使用 Grok Bot 的独立周用量；悬停可看各自周期和重置时间。无法取得某项独立额度时会明确提示，不会拿另一项的额度代替。

API 额度默认关闭。右键小灵，选择“设置额度连接…”，输入 API Key 并启用 API 额度。Key 使用当前 Windows 用户的 DPAPI 加密，保存在 `%LOCALAPPDATA%\桌面小灵宠\quotas.json`；明文 Key 不写入项目或日志。输入框留空会保留已存 Key，清除操作需点击保存才生效。若旧 Key 因 Windows 用户或加密数据变化而无法解密，小灵会明确要求重新输入；不会自动删除或发送该密文。

Token API 主值只显示每日剩余。优先采用接口的每日窗口或订阅日额度，不使用钱包总余额。对于 `unrestricted` Key，接口只返回日用量：在设置中填写仪表盘的“每日上限（美元）”，小灵按北京时间当天的实际消费估算剩余。上限保存在本机，后台上限调整后需同步修改；若账户还有其他 Key，账户共享额度以仪表盘为准。留空且接口无日上限时显示“每日剩余未知”。

当前 API 地址为 `http://token.acerobotics.com/v1`，连接没有加密，Key 可能被截获。必须主动勾选设置中的 HTTP 明文传输确认项才能启用请求。此处查询的是所填 API Key 对应的额度，可能与 [API 仪表盘](http://token.acerobotics.com/dashboard) 显示的账户总额度不同。

额度在独立后台任务中约每 30 秒更新；右键“立即刷新额度”可提前查询。界面显示最后成功更新时间，断网或临时查询失败时保留本次运行最近成功的读数并标记为缓存；缓存不会作为最新额度显示，也不会保存到磁盘。

## 设置与网络请求

窗口位置、置顶和缩放设置保存在 `%LOCALAPPDATA%\桌面小灵宠\window.json`，每次启动默认收起详情面板；运行日志也保存在该目录。右键菜单中可启用或关闭开机启动。

检测到 VPN 后，公网 IP 与位置查询会请求 `ip-api.com`（HTTP），失败时尝试 `ipwho.is`（HTTPS）。这些服务能够看到发起请求的公网 IP；位置结果是 IP 地理信息，可能与实际位置不同。内网隧道地址在本机读取并显示，不作为查询参数发送给上述服务。

温度取决于固件暴露的 ACPI 热区，不一定等同于 CPU 核心温度；GPU、网络和其他性能计数器也可能因设备、驱动或系统环境而不可用。

## 文件

| 文件 | 用途 |
| --- | --- |
| `pet.ps1` | WPF 窗口、动画、交互与后台采样 |
| `sensors.ps1` | 性能计数器、硬件、电池及网络信息读取 |
| `cursor-quota.ps1` | 读取本机 Cursor 授权并查询、解析额度 |
| `token-quota.ps1` | 查询、解析 API Key 对应的额度 |
| `quota-settings.ps1` | 额度设置弹窗与 DPAPI 加密存储 |
| `quota-worker.ps1` | 额度后台轮询、刷新与内存缓存 |
| `start.bat` | 双击启动入口 |
| `check-place.ps1` | IP 位置标签的示例检查 |

本机专属快捷方式、项目记忆和运行输出不包含在仓库内。

## 检查

读取硬件快照（输出可能包含本机和网络信息，请勿直接公开）：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\pet.ps1 -SelfTest
```

检查位置标签：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\check-place.ps1
```

检查真实额度连接（按照保存的启用状态和 HTTP 确认设置发起请求）：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\pet.ps1 -QuotaSelfTest
```

运行不访问真实账户的额度 fixture 检查：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\test-cursor-quota.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\test-token-quota.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\test-quota-worker.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\test-quota-settings.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\test-pet-quota-layout.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\test-pet-details-window.ps1
```

离屏检查额度设置弹窗布局并生成预览（不读取设置或密钥）：

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\test-quota-settings-layout.ps1
```
