# Claude Guard

Claude Guard 为 macOS 上的 Claude Desktop 提供专用代理入口，并用 LuLu 限制应用出站。服务核验 Clash Verge / Mihomo 的代理出口，菜单栏提供启动、状态和自检入口。

## 安装与更新

目前仓库提供的是**已有环境的更新包**。首次部署还需要配置专用 Clash 入口、LuLu 规则、统一服务和菜单。仓库里的 `source/legacy/` 用于追溯旧安装流程，当前没有验证过的全新安装命令。

更新前确认这几项：

- 在 macOS 的当前桌面账号下操作，使用系统 Ruby。
- 已安装 Claude Desktop、Clash Verge 和 LuLu，现有 LuLu 规则能通过保护服务的核验。
- 已有 Claude Guard 统一服务和自检入口，通常位于 `~/.claude-unified/service.rb` 和 `~/.claude-unified/selfcheck.rb`。
- 保存 Claude 中的工作，退出 Claude，并先等菜单自检结束。更新会重载 Claude Guard 统一服务。

首次下载私有仓库时，在有读取权限的账号下执行：

```sh
git clone https://github.com/rosalgee4-lgtm/claude-guard.git
cd claude-guard
/usr/bin/ruby source/install-claude-native.rb
```

已经克隆后，从仓库根目录更新：

```sh
git switch main
git pull --ff-only origin main
/usr/bin/ruby source/install-claude-native.rb
```

[更新器](source/install-claude-native.rb)会检查现有服务和自检文件。文件一致时跳过重载。如果更新失败，脚本会尝试恢复原文件和原服务。看到「缺少现有统一服务或自检」时，说明需要先完成基础部署。

## 从图标启动

1. 打开 Clash Verge，确认 **全局模式和 TUN 已开启**，全局组选择代理节点。
2. 等待菜单栏 Claude 状态显示专用代理就绪。
3. 点击 Dock、Launchpad 或 Finder 中的 **Claude** 应用图标。保护服务会接管这次普通启动，并以专用代理参数重新打开 Claude，因此窗口可能短暂消失再出现。

如果在代理尚未就绪时点击图标，保护服务不会排队重开。若普通窗口仍在，等代理恢复就绪后先退出该窗口，再手动点图标启动。也可以使用已部署菜单中的受保护启动项。

## 自检

保存工作并退出 Claude，然后在菜单栏 Claude 项目里点击 **一键自检（会关闭 Claude）**。自检会尝试关闭 Claude、运行测试并恢复专用代理。如果自检前 Claude 正在运行，恢复阶段可能尝试重新打开应用，正在运行的任务无法随之恢复。

结果会在菜单弹窗中显示，最近一次报告保存在 `~/.claude-unified/selfcheck-last.json`。也可在终端运行同一个入口：

```sh
/usr/bin/env -u RUBYOPT -u RUBYLIB /usr/bin/ruby -EUTF-8:UTF-8 "$HOME/.claude-unified/selfcheck.rb"
```

逐项查看「通过」「失败」和「未验证」。现有自检的进程清理项仍使用旧的故障终止判据，可能显示未验证。该项无法代替对当前 Clash 终止条件的验证。

## 什么时候只断流，什么时候关闭 Claude

这些是**已经受保护运行**的 Claude 的处置规则：

| 情况 | 处置 |
| --- | --- |
| 节点超时、HTTP 或 TLS 探测失败、出口记录缺失、控制接口暂时读不到 | 关闭专用连接，保留 Claude。重新核验成功后恢复连接。 |
| 确认 Clash Verge 已退出或 Mihomo 核心进程已消失 | 关闭专用连接并终止 Claude。 |
| 确认 Clash 切到直连模式，或全局组实际选中 DIRECT | 关闭专用连接并终止 Claude。 |

图标启动接管会替换刚打开的普通进程。手动运行自检也可能关闭 Claude。这两个操作属于各自的流程。

系统代查 DNS 仍存在未覆盖的例外。专用代理断流的结果只适用于专用连接，系统 DNS 代查需要独立验证。
