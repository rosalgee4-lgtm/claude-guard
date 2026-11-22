#!/bin/bash
set -euo pipefail
umask 077
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

state="$HOME/.claude-clash-menu"
guard="$HOME/.claude-clash-guard"
agents="$HOME/Library/LaunchAgents"
label=local.claude-clash-menu
guard_label=local.claude-clash-guard
domain="gui/$UID"
job="$domain/$label"
plist="$agents/$label.plist"
guard_job="$domain/$guard_label"
guard_plist="$agents/$guard_label.plist"

die() { printf '%s\n' "$*" >&2; exit 1; }

running() {
    launchctl print "$1" 2>/dev/null |
        awk '$1=="state" && $3=="running" {ready=1} END {exit !ready}'
}

loaded() { launchctl print "$1" >/dev/null 2>&1; }

guard_command() {
    /usr/bin/env -u RUBYOPT -u RUBYLIB /usr/bin/ruby -EUTF-8:UTF-8 "$guard/guard.rb" "$@"
}

start_job() {
    local id=$1 descriptor=$2
    [[ -f "$descriptor" && ! -L "$descriptor" ]] || return 1
    if ! loaded "$id"; then launchctl bootstrap "$domain" "$descriptor"; fi
}

install_rollback() {
    local result=$?
    trap - EXIT INT TERM HUP
    if [[ "$committed" != yes ]]; then
        printf '%s\n' '安装未完成，正在撤销本次改动。' >&2
        if [[ "$needs_guard" == yes && -f "$guard/guard.rb" ]]; then
            guard_command rollback || printf '%s\n' 'Claude 监控回滚失败，已保留回滚记录。' >&2
        fi
        archive_menu || printf '%s\n' '菜单回滚失败，已保留回滚记录。' >&2
    fi
    exit "$result"
}

write_menu() {
    cat > "$state/menu.js" <<'JXA'
ObjC.import('AppKit');

let directory, app, statusItem, menu, statusText, startItem, actions, timer;
let pending = null;

function openFile(path, bundle) {
    const task = $.NSTask.alloc.init;
    task.launchPath = '/usr/bin/open';
    task.arguments = bundle ? ['-b', bundle, path] : [path];
    task.launch;
}

function displayError(message) {
    const alert = $.NSAlert.alloc.init;
    alert.messageText = 'Claude Code';
    alert.informativeText = message;
    app.activateIgnoringOtherApps(true);
    alert.runModal;
}

function setStatus(ready, text) {
    statusItem.button.title = ready ? 'Claude ✓' : 'Claude';
    statusItem.button.toolTip = text;
    statusText.title = text;
    startItem.enabled = ready;
}

function beginStatus() {
    const pipe = $.NSPipe.pipe;
    const task = $.NSTask.alloc.init;
    task.launchPath = '/bin/bash';
    task.arguments = [directory + '/manage.sh', 'probe'];
    task.standardOutput = pipe;
    task.standardError = pipe;
    task.launch;
    pending = { task: task, pipe: pipe };
}

function updateStatus() {
    try {
        if (!pending) {
            beginStatus();
            return;
        }
        if (pending.task.isRunning) return;
        const data = pending.pipe.fileHandleForReading.readDataToEndOfFile;
        const result = ObjC.unwrap($.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding)).trim();
        if (Number(pending.task.terminationStatus) === 0 && result.indexOf('UP') === 0) {
            const missing = result.split('\n').includes('尚未找到 Claude Code');
            setStatus(true, missing ? '代理可用 · 尚未找到 Claude Code' : '代理可用');
        } else {
            setStatus(false, result.split('\n')[0].slice(0, 90) || 'Claude 监控未就绪');
        }
        pending = null;
    } catch (error) {
        pending = null;
        setStatus(false, '无法读取 Claude 监控状态');
    }
}

ObjC.registerSubclass({
    name: 'ClaudeGuardMenuActions',
    methods: {
        'tick:': {
            types: ['void', ['id']],
            implementation: function () { updateStatus(); }
        },
        'start:': {
            types: ['void', ['id']],
            implementation: function () {
                try { openFile(directory + '/启动 Claude Code.command', 'com.apple.Terminal'); }
                catch (error) { displayError('无法打开启动器。可以在终端输入 claude。'); }
            }
        },
        'refresh:': {
            types: ['void', ['id']],
            implementation: function () { updateStatus(); }
        },
        'logs:': {
            types: ['void', ['id']],
            implementation: function () {
                try { openFile(directory + '/状态与日志.command', 'com.apple.Terminal'); }
                catch (error) { displayError('无法打开监控日志。'); }
            }
        }
    }
});

function menuItem(title, selector) {
    const item = $.NSMenuItem.alloc.init;
    item.title = title;
    if (selector) {
        item.target = actions;
        item.action = selector;
    }
    return item;
}

function run(argv) {
    directory = argv[0];
    if (!directory) throw new Error('缺少菜单配置目录');
    app = $.NSApplication.sharedApplication;
    app.setActivationPolicy(1);
    actions = $.ClaudeGuardMenuActions.alloc.init;
    menu = $.NSMenu.alloc.init;
    menu.autoenablesItems = false;
    statusText = menuItem('正在检查 Claude 代理', null);
    statusText.enabled = false;
    startItem = menuItem('启动 Claude Code', 'start:');
    menu.addItem(statusText);
    menu.addItem($.NSMenuItem.separatorItem);
    menu.addItem(startItem);
    menu.addItem(menuItem('刷新状态', 'refresh:'));
    menu.addItem(menuItem('查看状态和日志', 'logs:'));
    statusItem = $.NSStatusBar.systemStatusBar.statusItemWithLength($.NSVariableStatusItemLength);
    statusItem.menu = menu;
    setStatus(false, '正在检查 Claude 代理');

    timer = $.NSTimer.timerWithTimeIntervalTargetSelectorUserInfoRepeats(1.5, actions, 'tick:', null, true);
    $.NSRunLoop.mainRunLoop.addTimerForMode(timer, $.NSRunLoopCommonModes);
    const ready = $.NSString.stringWithString(String($.NSProcessInfo.processInfo.processIdentifier));
    const result = ready.writeToFileAtomicallyEncodingError(directory + '/menu.ready', true, $.NSUTF8StringEncoding, null);
    if (!result) throw new Error('无法记录菜单启动状态');
    updateStatus();
    app.run;
}
JXA
    cat > "$state/启动 Claude Code.command" <<'START'
#!/bin/bash
set -euo pipefail
case "$PWD" in
    "$HOME/.claude-clash-menu"|/) cd "$HOME" ;;
esac
exec "$HOME/.claude-clash-guard/bin/claude" "$@"
START
    cat > "$state/状态与日志.command" <<'LOGS'
#!/bin/bash
"$HOME/.claude-clash-menu/manage.sh" status
for entry in "$HOME/.claude-clash-guard/guard.log" "$HOME/.claude-clash-menu/menu.log"; do
    [[ -s "$entry" ]] || continue
    printf '\n%s\n' "$entry"
    /usr/bin/tail -n 30 "$entry"
done
printf '\n按回车关闭此窗口。'
read -r _ || true
LOGS
    chmod 700 "$state/启动 Claude Code.command" "$state/状态与日志.command"
    plutil -create xml1 "$state/launch.plist"
    plutil -insert Label -string "$label" "$state/launch.plist"
    plutil -insert ProgramArguments -xml '<array><string>/usr/bin/osascript</string><string>-l</string><string>JavaScript</string><string></string><string></string></array>' "$state/launch.plist"
    plutil -replace ProgramArguments.3 -string "$state/menu.js" "$state/launch.plist"
    plutil -replace ProgramArguments.4 -string "$state" "$state/launch.plist"
    plutil -insert KeepAlive -bool YES "$state/launch.plist"
    plutil -insert ThrottleInterval -integer 5 "$state/launch.plist"
    plutil -insert LimitLoadToSessionType -string Aqua "$state/launch.plist"
    plutil -insert StandardErrorPath -string "$state/menu.log" "$state/launch.plist"
    plutil -lint "$state/launch.plist" >/dev/null
}

menu_ready() {
    local last=''
    [[ -r "$state/menu.ready" ]] || return 1
    last=$(<"$state/menu.ready")
    [[ "$last" =~ ^[1-9][0-9]*$ ]] || return 1
    launchctl print "$job" 2>/dev/null |
        awk -v pid="$last" '$1=="pid" && $3==pid {ok=1} END {exit !ok}'
}

archive_menu() {
    local archive
    if [[ -e "$plist" || -L "$plist" ]]; then
        [[ ! -L "$plist" && "$plist" -ef "$state/launch.plist" ]] || return 1
    fi
    if loaded "$job"; then launchctl bootout "$job" || return 1; fi
    if [[ -e "$plist" ]]; then
        mv "$plist" "$state/unloaded.plist" || return 1
    fi
    archive="$state.rollback.$(date +%Y%m%d-%H%M%S).$$"
    mv "$state" "$archive"
}

install_menu() {
    local guard_installer=${1:-} attempt
    [[ ! -e "$state" && ! -L "$state" && ! -e "$plist" && ! -L "$plist" ]] || die '菜单已安装，请运行 manage.sh status。'
    [[ ! -e "$HOME/.claude-clash-pf" && ! -e /Library/LaunchDaemons/local.claude-clash-pf.plist ]] ||
        die '请先撤销旧版账号级 PF。'
    launchctl print "$domain" >/dev/null 2>&1 || die '请在已登录 macOS 桌面的终端安装。'
    mkdir -m 700 "$state"
    needs_guard=no
    committed=no
    trap install_rollback EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP

    # Verify the menu process before touching any Claude entry point.
    install -m 700 "${BASH_SOURCE[0]}" "$state/manage.sh"
    write_menu
    mkdir -p "$agents"
    ln "$state/launch.plist" "$plist"
    start_job "$job" "$plist"
    for ((attempt=0; attempt<30; attempt++)); do
        if menu_ready; then break; fi
        sleep 0.3
    done
    menu_ready || die '菜单未通过启动自检。'

    if [[ ! -e "$guard" && ! -L "$guard" && ! -e "$guard_plist" && ! -L "$guard_plist" ]]; then
        [[ -f "$guard_installer" ]] || die '缺少 Claude 沙箱安装器。'
        needs_guard=yes
        /bin/bash "$guard_installer" install
        printf '%s\n' installed > "$state/owns-guard"
    elif [[ -f "$guard/guard.rb" && -x "$guard/bin/claude" && -f "$guard_plist" ]]; then
        if [[ "${REQUIRE_SHARED_CLAUDE_GUARD:-0}" == 1 && ! -f "$guard/inbound.json" ]]; then
            die '检测到旧版独立 Mihomo 监控。请先运行旧版的 rollback，再安装共用内核版。'
        fi
        start_job "$guard_job" "$guard_plist"
    else
        die '现有 Claude 监控配置不完整。'
    fi
    menu_ready || die '菜单进程安装期间退出。'
    committed=yes
    trap - EXIT INT TERM HUP
    printf '%s\n' '菜单已安装。代理就绪且装好 Claude Code 后，可从 macOS 菜单栏启动。'
    printf '启动脚本：%s\n' "$state/启动 Claude Code.command"
    printf '管理命令：%s {start|status|rollback}\n' "$state/manage.sh"
}

[[ "$(uname -s)" == Darwin && $UID -ne 0 ]] || die '请在 Mac mini 桌面账号下执行。'
case "${1:-install}" in
    install) install_menu "${2:-}" ;;
    probe) guard_command status ;;
    start)
        start_job "$guard_job" "$guard_plist" || die '无法启动 Claude 监控。'
        start_job "$job" "$plist" || die '无法启动 Claude 菜单。'
        ;;
    status)
        if running "$job" && menu_ready; then printf '%s\n' '菜单栏正在运行。'; else printf '%s\n' '菜单栏未就绪。'; fi
        if running "$guard_job"; then printf '%s\n' '后台监控正在运行。'; else printf '%s\n' '后台监控未运行。'; fi
        [[ -f "$guard/guard.rb" ]] || die 'Claude 监控未安装。'
        guard_command status
        ;;
    rollback)
        [[ -d "$state" && ! -L "$state" ]] || die '没有菜单安装记录。'
        if [[ -e "$plist" || -L "$plist" ]]; then
            [[ ! -L "$plist" && "$plist" -ef "$state/launch.plist" ]] || die '菜单 LaunchAgent 在安装后发生变化。'
        fi
        if [[ -f "$state/owns-guard" && -f "$guard/guard.rb" ]]; then guard_command rollback; fi
        archive_menu || die '无法撤销菜单，已保留回滚记录。'
        printf '%s\n' '本次安装的菜单与自启动已撤销。'
        ;;
    *) die '用法：manage.sh start|status|rollback' ;;
esac
