# encoding: UTF-8
require 'json'
require 'digest'
require 'open3'
require 'socket'
require 'timeout'
require 'tempfile'
require 'fileutils'
require 'cgi'

class UnifiedMigration
  STATE = File.join(Dir.home, '.claude-unified')
  MENU = File.join(Dir.home, '.claude-clash-menu')
  AGENTS = File.join(Dir.home, 'Library/LaunchAgents')
  LABEL = 'local.claude-unified'
  JOB = "gui/#{Process.uid}/#{LABEL}"
  PLIST = File.join(AGENTS, LABEL + '.plist')

  def run(*args)
    output, _, status = Open3.capture3(*args)
    raise "操作失败：#{args.first} #{args[1]}" unless status.success?
    output
  end

  def loaded(label)
    _, _, status = Open3.capture3('/bin/launchctl', 'print', "gui/#{Process.uid}/#{label}")
    status.success?
  end

  def atomic(path, content, mode = 0600)
    Tempfile.create('.unified-', File.dirname(path)) do |file|
      file.binmode
      file.write(content)
      file.flush
      File.chmod(mode, file.path)
      File.rename(file.path, path)
    end
  end

  def stop_job(label)
    run('/bin/launchctl', 'bootout', "gui/#{Process.uid}/#{label}") if loaded(label)
    100.times do
      return unless loaded(label)
      sleep 0.2
    end
    raise "服务在卸载后仍然可查询：#{label}；已等待 20 秒"
  end

  def digest(path)
    Digest::SHA256.file(path).hexdigest
  end

  def restore
    manifest = JSON.parse(File.read(File.join(STATE, 'migration.json'), encoding: 'UTF-8'))
    stop_job(LABEL)
    manifest['menus'].each do |entry|
      path = entry['path']
      if File.exist?(path) && ![entry['before'], entry['after']].include?(digest(path))
        raise '菜单出现其他修改，已停止新服务并保留迁移备份'
      end
      atomic(path, File.binread(File.join(STATE, entry['backup'])), entry['mode'])
    end
    if File.exist?(PLIST)
      raise '新服务自启项已被修改，已保留备份' unless digest(PLIST) == manifest['plist']
      File.unlink(PLIST)
    end
    manifest['old'].each do |entry|
      backup = File.join(STATE, entry['backup'])
      if File.exist?(backup)
        raise '原自启路径已被占用，已保留备份' if File.exist?(entry['path'])
        File.rename(backup, entry['path'])
      end
      if entry['loaded'] && !loaded(entry['label'])
        run('/bin/launchctl', 'bootstrap', "gui/#{Process.uid}", entry['path'])
      end
    end
    run('/bin/launchctl', 'kickstart', '-k', "gui/#{Process.uid}/local.claude-clash-menu")
    archive = STATE + ".rollback.#{Time.now.strftime('%Y%m%d%H%M%S')}.#{Process.pid}"
    File.rename(STATE, archive)
    puts "已恢复迁移前的服务和菜单，回滚资料：#{archive}"
  end

  def install
    raise '请在 Mac 桌面账号下执行' unless RUBY_PLATFORM.include?('darwin') && Process.uid != 0
    raise '合并版目录已存在，请先检查其状态或执行 rollback' if File.exist?(STATE) || File.exist?(PLIST)
    raise '原菜单服务未运行' unless loaded('local.claude-clash-menu')
    guard = File.join(Dir.home, '.claude-clash-guard/guard.rb')
    raise '原监控代码缺失' unless File.file?(guard)
    require_relative 'claude-unified-service'
    raise '请先完全退出 Claude 桌面版及 CLI' unless ClaudeDesktopService.new.processes.empty?
    %w[claude-unified-service.rb claude-embedded-engine.rb].each do |name|
      run('/usr/bin/ruby', '-EUTF-8:UTF-8', '-c', File.join(__dir__, name))
    end
    # The preserved directory contains the existing listener configuration.
    %w[inbound.json installed extension.json].each do |name|
      raise "原监控资料缺失：#{name}" unless File.file?(File.join(Dir.home, '.claude-clash-guard', name))
    end
    old = %w[local.claude-clash-guard local.claude-desktop-service].map do |label|
      path = File.join(AGENTS, label + '.plist')
      active = loaded(label)
      raise '旧任务已加载但自启文件缺失，无法保证恢复' if active && !File.file?(path)
      next unless File.exist?(path)
      raise '旧自启文件是符号链接' if File.symlink?(path)
      actual = run('/usr/libexec/PlistBuddy', '-c', 'Print :Label', path).strip
      raise '旧自启文件标签不匹配' unless actual == label
      {'label' => label, 'path' => path, 'loaded' => active, 'digest' => digest(path), 'backup' => label + '.plist'}
    end.compact
    originals = %w[manage.sh menu.js].map do |name|
      path = File.join(MENU, name)
      raise '菜单文件缺失或为符号链接' unless File.file?(path) && !File.symlink?(path)
      [path, File.binread(path), File.stat(path).mode & 0777]
    end
    launch_path = File.join(MENU, '启动 Claude Code.command')
    raise '菜单启动器缺失或为符号链接' unless File.file?(launch_path) && !File.symlink?(launch_path)
    originals << [launch_path, File.binread(launch_path), File.stat(launch_path).mode & 0777]
    logs_path = File.join(MENU, '状态与日志.command')
    raise '菜单日志入口缺失或为符号链接' unless File.file?(logs_path) && !File.symlink?(logs_path)
    originals << [logs_path, File.binread(logs_path), File.stat(logs_path).mode & 0777]
    command = '/usr/bin/env -u RUBYOPT -u RUBYLIB /usr/bin/ruby -EUTF-8:UTF-8 "$HOME/.claude-unified/service.rb"'
    manager = <<~SH
      #!/bin/bash
      set -euo pipefail
      case "${1:-status}" in
        probe|status) exec #{command} status ;;
        start) /bin/launchctl kickstart "gui/$UID/#{LABEL}"; /bin/launchctl kickstart "gui/$UID/local.claude-clash-menu" ;;
        rollback) exec /usr/bin/env -u RUBYOPT -u RUBYLIB /usr/bin/ruby -EUTF-8:UTF-8 "$HOME/.claude-unified/migrate.rb" rollback ;;
        *) exit 2 ;;
      esac
    SH
    menu = originals[1][1].dup.force_encoding('UTF-8').sub("'Claude ✓'", "'Claude 代理✓'")
    replacements = [manager, menu, "#!/bin/bash\nset -euo pipefail\nexec #{command} launch\n"]
    replacements << <<~SH
      #!/bin/bash
      #{command} status
      for entry in "$HOME/.claude-unified/service.log" "$HOME/.claude-clash-menu/menu.log"; do
        [[ -s "$entry" ]] || continue
        printf '\\n%s\\n' "$entry"
        /usr/bin/tail -n 30 "$entry"
      done
      printf '\\n按回车关闭此窗口。'
      read -r
    SH
    args = ['/usr/bin/env', '-u', 'RUBYOPT', '-u', 'RUBYLIB', '/usr/bin/ruby', '-EUTF-8:UTF-8', File.join(STATE, 'service.rb'), 'serve']
    plist = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <plist version="1.0"><dict>
      <key>Label</key><string>#{LABEL}</string>
      <key>ProgramArguments</key><array>#{args.map { |arg| '<string>' + CGI.escapeHTML(arg) + '</string>' }.join}</array>
      <key>KeepAlive</key><true/><key>RunAtLoad</key><true/>
      <key>ThrottleInterval</key><integer>5</integer>
      <key>StandardErrorPath</key><string>#{CGI.escapeHTML(File.join(STATE, 'service.log'))}</string>
      </dict></plist>
    XML
    manifest = {'old' => old, 'menus' => [], 'plist' => Digest::SHA256.hexdigest(plist)}
    FileUtils.mkdir(STATE, mode: 0700)
    begin
      originals.each_with_index do |(path, content, mode), index|
        name = "menu-backup-#{index}"
        atomic(File.join(STATE, name), content)
        manifest['menus'] << {'path' => path, 'backup' => name, 'mode' => mode,
                              'before' => Digest::SHA256.hexdigest(content), 'after' => Digest::SHA256.hexdigest(replacements[index])}
      end
      atomic(File.join(STATE, 'migration.json'), JSON.generate(manifest))
      atomic(File.join(STATE, 'service.rb'), File.binread(File.join(__dir__, 'claude-unified-service.rb')))
      atomic(File.join(STATE, 'claude-embedded-engine.rb'), File.binread(File.join(__dir__, 'claude-embedded-engine.rb')))
      atomic(File.join(STATE, 'migrate.rb'), File.binread(__FILE__))
      atomic(PLIST, plist)
      run('/usr/bin/plutil', '-lint', PLIST)
      old.each do |entry|
        raise '旧自启文件在迁移期间发生变化' unless digest(entry['path']) == entry['digest']
        stop_job(entry['label'])
        File.rename(entry['path'], File.join(STATE, entry['backup']))
      end
      run('/bin/launchctl', 'bootstrap', "gui/#{Process.uid}", PLIST)
      ready = false
      40.times do
        begin
          UNIXSocket.open(File.join(STATE, 'control.sock')) do |socket|
            socket.puts('status')
            result = JSON.parse(Timeout.timeout(2) { socket.gets }.to_s)
            ready = result.key?('ok') && File.socket?(File.join(Dir.home, '.claude-clash-guard/guard.sock'))
          end
        rescue IOError, SystemCallError, Timeout::Error, JSON::ParserError
          nil
        end
        break if ready
        sleep 0.25
      end
      raise '合并服务未启动' unless ready && loaded(LABEL)
      originals.each_with_index do |(path, content, mode), index|
        raise '菜单在迁移期间发生变化' unless File.binread(path) == content
        atomic(path, replacements[index], mode)
      end
      run('/bin/bash', '-n', originals[0][0])
      run('/bin/launchctl', 'kickstart', '-k', "gui/#{Process.uid}/local.claude-clash-menu")
      remaining = old.select { |entry| loaded(entry['label']) }.map { |entry| entry['label'] }
      raise "旧服务在迁移后重新出现：#{remaining.join(', ')}" unless remaining.empty?
      puts '合并完成：一个后台监控进程，固定入口 127.0.0.1:17893。'
      puts '旧监控与旧桌面代理的自启项已归档，旧配置目录作为现有配置与回滚资料保留。'
      puts '菜单已接入合并服务。LuLu 规则仍需保持生效。'
    rescue Exception
      if File.file?(File.join(STATE, 'migration.json'))
        restore
      else
        File.rename(STATE, STATE + ".failed.#{Process.pid}")
      end
      raise
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    migration = UnifiedMigration.new
    ARGV.first == 'rollback' ? migration.restore : migration.install
  rescue StandardError => error
    warn(error.is_a?(RuntimeError) ? error.message : "迁移失败（#{error.class}）")
    exit 1
  end
end
