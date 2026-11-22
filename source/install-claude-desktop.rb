# encoding: UTF-8
require 'fileutils'
require 'json'
require 'digest'
require 'open3'
require 'socket'
require 'timeout'
require 'cgi'

class DesktopInstaller
  STATE = File.join(Dir.home, '.claude-desktop-service')
  MENU = File.join(Dir.home, '.claude-clash-menu')
  LABEL = 'local.claude-desktop-service'
  PLIST = File.join(Dir.home, 'Library/LaunchAgents', LABEL + '.plist')
  JOB = "gui/#{Process.uid}/#{LABEL}"

  def run(*args)
    output, error, status = Open3.capture3(*args)
    raise "命令失败：#{args.first} #{args[1]}" unless status.success?
    output
  end

  def atomic(path, text, mode)
    require 'tempfile'
    Tempfile.create('.desktop-install-', File.dirname(path)) do |file|
      file.binmode
      file.write(text)
      file.flush
      File.chmod(mode, file.path)
      File.rename(file.path, path)
    end
  end

  def rollback
    return unless File.directory?(STATE)
    manifest_path = File.join(STATE, 'manifest.json')
    raise '回滚记录缺失，已保留现场' unless File.file?(manifest_path)
    manifest = JSON.parse(File.read(manifest_path))
    manifest.fetch('files').each do |entry|
      path = entry.fetch('path')
      next unless File.exist?(path)
      digest = Digest::SHA256.file(path).hexdigest
      unless [entry['before'], entry['after']].include?(digest)
        raise '菜单文件在安装后被修改，回滚已停止并保留备份'
      end
    end
    if File.exist?(PLIST) && Digest::SHA256.file(PLIST).hexdigest != manifest.fetch('plist')
      raise 'LaunchAgent 已被修改，已保留回滚记录'
    end
    _, _, loaded = Open3.capture3('/bin/launchctl', 'print', JOB)
    run('/bin/launchctl', 'bootout', JOB) if loaded.success?
    manifest.fetch('files').each do |entry|
      atomic(entry['path'], File.binread(File.join(STATE, entry['backup'])), entry['mode'])
    end
    File.unlink(PLIST) if File.exist?(PLIST)
    Open3.capture3('/bin/launchctl', 'kickstart', '-k', "gui/#{Process.uid}/local.claude-clash-menu")
    archive = STATE + '.rollback.' + Time.now.strftime('%Y%m%d%H%M%S') + ".#{Process.pid}"
    File.rename(STATE, archive)
    puts "本次服务和菜单改动已撤销，备份保存在 #{archive}"
  end

  def install
    raise '请在 Mac mini 已登录桌面的账号下执行' unless RUBY_PLATFORM.include?('darwin') && Process.uid != 0
    raise '已有安装目录，请先执行现有 rollback 命令' if File.exist?(STATE) || File.exist?(PLIST)
    guard = File.join(Dir.home, '.claude-clash-guard/guard.rb')
    raise '原代理监控未安装' unless File.file?(guard)
    service = File.join(__dir__, 'claude-desktop-service.rb')
    run('/usr/bin/ruby', '-EUTF-8:UTF-8', '-c', service)
    require guard
    %i[record identity terminate read_header shutdown verify_socket_limits proxy_status].each do |method|
      raise "原监控缺少接口 #{method}" unless ClaudeGuard.method_defined?(method)
    end
    extensions = run('/usr/bin/systemextensionsctl', 'list')
    raise 'LuLu 扩展未启用' unless extensions.lines.any? { |line| line.include?('com.objective-see.lulu.extension') && line.include?('[activated enabled]') }
    require service
    raise '请先在 Claude 桌面应用按 Command-Q 退出，并结束 Claude CLI' unless ClaudeDesktopService.new.processes.empty?
    TCPServer.open('127.0.0.1', ClaudeDesktopService::PORT) { |socket| socket.close }
    paths = ['manage.sh', '启动 Claude Code.command', 'menu.js']
    originals = paths.map do |name|
      path = File.join(MENU, name)
      raise "菜单文件缺失或为符号链接：#{name}" unless File.file?(path) && !File.symlink?(path)
      [name, File.binread(path), File.stat(path).mode & 0777]
    end
    manager = originals[0][1].dup.force_encoding('UTF-8')
    raise '菜单版本不匹配' unless manager.include?('probe) guard_command status ;;')
    command = '/usr/bin/env -u RUBYOPT -u RUBYLIB /usr/bin/ruby -EUTF-8:UTF-8 "$HOME/.claude-desktop-service/service.rb"'
    manager = manager.gsub('guard_command status', command + ' status')
    launcher = "#!/bin/bash\nset -euo pipefail\nexec #{command} launch\n"
    menu = originals[2][1].dup.force_encoding('UTF-8').sub("'Claude ✓'", "'Claude 代理✓'")
    replacements = [manager, launcher, menu]
    args = ['/usr/bin/env', '-u', 'RUBYOPT', '-u', 'RUBYLIB', '/usr/bin/ruby', '-EUTF-8:UTF-8', File.join(STATE, 'service.rb'), 'serve']
    plist = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0"><dict>
      <key>Label</key><string>#{LABEL}</string>
      <key>ProgramArguments</key><array>#{args.map { |arg| '<string>' + CGI.escapeHTML(arg) + '</string>' }.join}</array>
      <key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
      <key>ThrottleInterval</key><integer>5</integer>
      <key>StandardErrorPath</key><string>#{CGI.escapeHTML(File.join(STATE, 'service.log'))}</string>
      </dict></plist>
    XML
    manifest = {'plist' => Digest::SHA256.hexdigest(plist), 'files' => []}
    FileUtils.mkdir(STATE, mode: 0700)
    begin
    originals.each_with_index do |(name, content, mode), index|
      backup = "original-#{index}"
      atomic(File.join(STATE, backup), content, 0600)
      manifest['files'] << {'path' => File.join(MENU, name), 'backup' => backup, 'mode' => mode,
                            'before' => Digest::SHA256.hexdigest(content), 'after' => Digest::SHA256.hexdigest(replacements[index])}
    end
    atomic(File.join(STATE, 'manifest.json'), JSON.generate(manifest), 0600)
      atomic(File.join(STATE, 'service.rb'), File.binread(service), 0600)
      atomic(File.join(STATE, 'install.rb'), File.binread(__FILE__), 0600)
      atomic(PLIST, plist, 0600)
      run('/usr/bin/plutil', '-lint', PLIST)
      run('/bin/launchctl', 'bootstrap', "gui/#{Process.uid}", PLIST)
      ready = false
      40.times do
        begin
          UNIXSocket.open(File.join(STATE, 'control.sock')) do |socket|
            socket.puts('status')
            response = JSON.parse(Timeout.timeout(2) { socket.gets }.to_s)
            ready = response.key?('ok') && response['message'].is_a?(String)
          end
        rescue SystemCallError, IOError, Timeout::Error, JSON::ParserError
          nil
        end
        break if ready
        sleep 0.25
      end
      raise '桌面服务未能启动' unless ready
      originals.each_with_index do |(name, content, mode), index|
        path = File.join(MENU, name)
        raise '菜单文件在安装期间发生变化' unless File.binread(path) == content
        atomic(path, replacements[index], mode)
      end
      run('/bin/bash', '-n', File.join(MENU, 'manage.sh'))
      run('/bin/bash', '-n', File.join(MENU, '启动 Claude Code.command'))
      run('/bin/launchctl', 'kickstart', '-k', "gui/#{Process.uid}/local.claude-clash-menu")
      puts '桌面代理服务已安装，固定入口为 127.0.0.1:17893。'
      puts '菜单和监控会在登录后自动启动；请完成 LuLu 规则后再启动 Claude。'
      puts '回滚命令：/usr/bin/ruby -EUTF-8:UTF-8 "$HOME/.claude-desktop-service/install.rb" rollback'
    rescue Exception
      if File.file?(File.join(STATE, 'manifest.json'))
        rollback
      else
        File.rename(STATE, STATE + ".failed.#{Process.pid}")
      end
      raise
    end
  end
end

begin
  installer = DesktopInstaller.new
  ARGV.first == 'rollback' ? installer.rollback : installer.install
rescue StandardError => error
  warn(error.is_a?(RuntimeError) ? error.message : "安装失败（#{error.class}）")
  exit 1
end
