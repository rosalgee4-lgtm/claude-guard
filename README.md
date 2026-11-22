# Claude Guard

macOS 上的 Claude Desktop 专用代理保护工具。项目包含 Ruby 服务、LuLu 核验、菜单自检、安装更新脚本和测试。当前是开发版本，部分脚本需要本机已有的 Claude Guard 环境。

- 通过本机专用入口核验代理出口，核验失败时关闭专用连接。
- 受保护运行的 Claude 仅在确认 Clash Verge 退出、Mihomo 核心进程消失或明确切到直连时触发运行期终止。
- 菜单可查看状态、启动受保护的 Claude 和运行自检。

## 目录

- `source/` 包含服务、安装更新脚本、测试和历史安装脚本。
- `source/install-claude-native.rb` 用于更新已有的统一保护服务，依赖本机 Claude Desktop、Clash Verge、LuLu 和先前部署的服务。运行前请阅读脚本。
- `source/test-clash-only-stop.rb` 在已有本机保护环境中用隔离子进程验证终止条件。

系统服务代查 DNS 的例外仍待解决，专用代理断流无法证明系统代查也被阻断。
