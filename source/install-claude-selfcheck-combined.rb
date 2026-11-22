# encoding: UTF-8
require 'json'
require 'digest'
require 'open3'
require 'tempfile'
require 'socket'
require 'timeout'
require_relative 'install-claude-selfcheck-menu'

class CombinedSelfcheckInstaller
  STATE = File.join(Dir.home, '.claude-unified')
  MENU_LOG = File.join(Dir.home, '.claude-clash-menu', '状态与日志.command')
  JOB = "gui/#{Process.uid}/local.claude-unified"
  PLIST = File.join(Dir.home, 'Library/LaunchAgents/local.claude-unified.plist')

  def run(*args)
    _, _, status = Open3.capture3(*args)
    raise "操作失败：#{args.first} #{args[1]}" unless status.success?
  end

  def loaded
    _, _, status = Open3.capture3('/bin/launchctl', 'print', JOB)
    status.success?
  end

  def stop
    run('/bin/launchctl', 'bootout', JOB) if loaded
    100.times do
      return unless loaded
      sleep 0.2
    end
    raise '监控卸载超时'
  end

  def atomic(path, data, mode)
    Tempfile.create('.selfcheck-update-', File.dirname(path)) do |file|
      file.binmode
      file.write(data)
      file.flush
      File.chmod(mode, file.path)
      File.rename(file.path, path)
    end
  end

  def verify_environment
    raise '请在 Mac 已登录桌面账号执行' unless RUBY_PLATFORM.include?('darwin') && Process.uid != 0
  end

  def menu_installer
    SelfcheckMenuInstaller.new
  end

  def verify_diagnostics
    40.times do
      begin
        response = UNIXSocket.open(File.join(STATE, 'control.sock')) do |socket|
          socket.puts('diagnostics')
          JSON.parse(Timeout.timeout(2) { socket.gets }.to_s)
        end
        return if response['diagnostics'].is_a?(Hash)
      rescue IOError, SystemCallError, Timeout::Error, JSON::ParserError
        nil
      end
      sleep 0.25
    end
    raise '监控未能提供自检接口'
  end

  def verify_jobs
    run('/bin/launchctl', 'print', SelfcheckMenuInstaller::JOB)
    %w[local.claude-clash-guard local.claude-desktop-service].each do |label|
      _, _, status = Open3.capture3('/bin/launchctl', 'print', "gui/#{Process.uid}/#{label}")
      raise '检测到未合并的旧服务，请先完成统一监控迁移；未做修改' if status.success?
    end
  end

  def install
    verify_environment
    raise '尚未安装统一监控，未做修改' unless File.directory?(STATE)
    lock = File.open(File.join(STATE, 'selfcheck.lock'), File::RDWR | File::CREAT, 0600)
    raise '自检或更新正在运行，请结束后重试' unless lock.flock(File::LOCK_EX | File::LOCK_NB)
    verify_jobs
    service_path = File.join(STATE, 'service.rb')
    manifest_path = File.join(STATE, 'migration.json')
    raise '合并版尚未安装或未运行' unless loaded && File.file?(service_path)
    service = File.read(service_path, encoding: 'UTF-8')
    marker = "\nif $PROGRAM_NAME == __FILE__\n"
    read_request = "              request = Timeout.timeout(2) { connection.gets(64) }.to_s.strip\n"
    unless service.include?("require_relative 'selfcheck-support'")
      raise '监控版本不匹配' unless service.scan(marker).length == 1 && service.scan(read_request).length == 1
      handler = <<~'CODE'
              if request == 'diagnostics'
                connection.puts(JSON.generate('ok' => true, 'diagnostics' => selfcheck_snapshot))
                next
              end
CODE
      service = service.sub(read_request, read_request + handler)
      service = service.sub(marker, "\nrequire_relative 'selfcheck-support'\n" + marker)
    end
    manifest = JSON.parse(File.read(manifest_path, encoding: 'UTF-8'))
    raise '菜单日志入口缺失' unless File.file?(MENU_LOG) && !File.symlink?(MENU_LOG)
    current_log = File.binread(MENU_LOG)
    log_script = <<~'SH'
      #!/bin/bash
      /usr/bin/env -u RUBYOPT -u RUBYLIB /usr/bin/ruby -EUTF-8:UTF-8 "$HOME/.claude-unified/service.rb" status
      for entry in "$HOME/.claude-unified/service.log" "$HOME/.claude-clash-menu/menu.log" "$HOME/.claude-unified/selfcheck-last.json"; do
        [[ -s "$entry" ]] || continue
        printf '\n%s\n' "$entry"
        /usr/bin/tail -n 80 "$entry"
      done
      printf '\n按回车关闭此窗口。'
      read -r
    SH
    files = {
      service_path => [service, 0600],
      File.join(STATE, 'selfcheck-support.rb') => [File.binread(File.join(__dir__, 'claude-selfcheck-support.rb')), 0600],
      File.join(STATE, 'selfcheck.rb') => [File.binread(File.join(__dir__, 'claude-selfcheck.rb')), 0600],
      MENU_LOG => [log_script, File.stat(MENU_LOG).mode & 0777]
    }
    entry = manifest.fetch('menus').find { |item| item['path'] == MENU_LOG }
    if entry
      raise '菜单日志入口被其他程序修改' unless Digest::SHA256.hexdigest(current_log) == entry['after']
    else
      entry = {'path' => MENU_LOG, 'backup' => 'menu-backup-selfcheck-log', 'mode' => File.stat(MENU_LOG).mode & 0777,
               'before' => Digest::SHA256.hexdigest(current_log)}
      raise '日志备份路径已存在' if File.exist?(File.join(STATE, entry['backup']))
      files[File.join(STATE, entry['backup'])] = [current_log, 0600]
      manifest['menus'] << entry
    end
    entry['after'] = Digest::SHA256.hexdigest(log_script)
    menu_path = File.join(File.dirname(MENU_LOG), 'menu.js')
    raise '菜单文件缺失或为符号链接' unless File.file?(menu_path) && !File.symlink?(menu_path)
    current_menu = File.binread(menu_path)
    menu_entry = manifest.fetch('menus').find { |item| item['path'] == menu_path }
    raise '菜单与迁移记录不一致，未修改文件' unless menu_entry && menu_entry['after'] == Digest::SHA256.hexdigest(current_menu)
    menu_tool = menu_installer
    new_menu = menu_tool.patch(current_menu.dup.force_encoding('UTF-8'), File.read(File.join(__dir__, 'claude-selfcheck-menu.js'), encoding: 'UTF-8'))
    menu_tool.validate(new_menu)
    menu_entry['after'] = Digest::SHA256.hexdigest(new_menu)
    files[menu_path] = [new_menu, File.stat(menu_path).mode & 0777]
    files[manifest_path] = [JSON.generate(manifest), 0600]
    files.each do |path, (data, _)|
      next unless path.end_with?('.rb')
      Tempfile.create(['selfcheck-syntax-', '.rb']) do |file|
        file.binmode
        file.write(data)
        file.flush
        run('/usr/bin/ruby', '-EUTF-8:UTF-8', '-c', file.path)
      end
    end
    originals = files.each_with_object({}) do |(path, _), result|
      raise '目标文件是符号链接' if File.symlink?(path)
      result[path] = File.exist?(path) ? [File.binread(path), File.stat(path).mode & 0777] : nil
    end
    changes = files.select { |path, (data, mode)| !originals[path] || originals[path] != [data.b, mode] }
    if changes.empty?
      verify_diagnostics
      puts '自检、菜单和日志均已是本版；未写入文件，未重启服务。'
      return
    end
    service_changed = changes.key?(service_path) || changes.key?(File.join(STATE, 'selfcheck-support.rb'))
    menu_changed = changes.key?(menu_path)
    restarting = false
    menu_restarting = false
    written = []
    begin
      changes.each do |path, (data, mode)|
        prior = originals[path]
        raise '文件在更新期间发生变化' if File.symlink?(path) || (prior ? (!File.file?(path) || File.binread(path) != prior[0]) : File.exist?(path))
        atomic(path, data, mode)
        written << path
      end
      if service_changed
        restarting = true
        stop
        run('/bin/launchctl', 'bootstrap', "gui/#{Process.uid}", PLIST)
      end
      verify_diagnostics
      if menu_changed
        menu_restarting = true
        menu_tool.restart
      end
      puts '自检、菜单和日志已一起更新。请从 Claude 菜单点击“一键自检（会关闭 Claude）”。'
      puts(service_changed ? '已更新并重启原统一监控，没有新增服务。' : '原监控保持运行，没有重启或新增服务。')
    rescue Exception => original_error
      errors = []
      begin
        stop if restarting
      rescue StandardError
        errors << '停止新监控失败'
      end
      written.reverse_each do |path|
        begin
          prior = originals[path]
          if prior
            atomic(path, prior[0], prior[1])
          else
            File.unlink(path) if File.exist?(path)
          end
        rescue StandardError
          errors << '恢复文件失败'
        end
      end
      begin
        run('/bin/launchctl', 'bootstrap', "gui/#{Process.uid}", PLIST) if restarting
      rescue StandardError
        errors << '恢复原监控启动失败'
      end
      begin
        menu_tool.restart if menu_restarting
      rescue StandardError
        errors << '恢复原菜单启动失败'
      end
      warn(errors.empty? ? '更新失败，本次文件及任务改动已撤销。' : '回滚未完全完成：' + errors.uniq.join('；'))
      raise original_error
    end
  ensure
    lock&.close
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    CombinedSelfcheckInstaller.new.install
  rescue StandardError => error
    warn(error.is_a?(RuntimeError) ? error.message : "自检安装失败（#{error.class}）")
    exit 1
  end
end
