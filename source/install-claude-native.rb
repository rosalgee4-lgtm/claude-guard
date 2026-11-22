# encoding: UTF-8
require 'tempfile'
require 'json'
require 'socket'
require 'timeout'
require 'open3'
require_relative 'claude-lulu-gate'
class ClaudeNativeInstaller
  STATE = File.join(Dir.home, '.claude-unified')
  JOB = "gui/#{Process.uid}/local.claude-unified"
  PLIST = File.join(Dir.home, 'Library/LaunchAgents/local.claude-unified.plist')
  def atomic(path, bytes, mode)
    Tempfile.create('.native-update-',File.dirname(path)) do |f|
      f.binmode; f.write(bytes); f.flush; File.chmod(mode,f.path); File.rename(f.path,path)
    end
  end
  def control
    UNIXSocket.open(File.join(STATE,'control.sock')) do |s|
      s.puts('diagnostics'); JSON.parse(Timeout.timeout(3){s.gets}.to_s)
    end
  end
  def validate_environment
    raise '请在当前 Mac 桌面账号执行' unless RUBY_PLATFORM.include?('darwin') && Process.uid != 0
    ClaudeLuLuGate.new.verify!
    %w[local.claude-clash-guard local.claude-desktop-service].each do |job|
      _,_,s=Open3.capture3('/bin/launchctl','print',"gui/#{Process.uid}/#{job}")
      raise '检测到重复旧监控，未更新' if s.success?
    end
  end
  def stop
    begin
      @old_pid = control.fetch('diagnostics').fetch('pid')
    rescue StandardError
      listing,_,loaded=Open3.capture3('/bin/launchctl','print',JOB)
      raise '无法确认 Claude 服务状态，未停止或覆盖文件' unless loaded.success?
      @old_pid = listing[/^\s*pid = (\d+)\s*$/,1]&.to_i
    end
    _,_,s=Open3.capture3('/bin/launchctl','bootout',JOB)
    raise '无法卸载 Claude 统一服务' unless s.success?
    return unless @old_pid
    100.times do
      begin; Process.kill(0,@old_pid); rescue Errno::ESRCH; return; end
      sleep 0.1
    end
    raise '旧 Claude 服务仍在运行，未写入更新'
  end
  def start
    _,_,s=Open3.capture3('/bin/launchctl','bootstrap',"gui/#{Process.uid}",PLIST)
    raise '无法启动 Claude 统一服务' unless s.success?
    100.times do
      begin
        d=control['diagnostics']
        return if d.is_a?(Hash) && d['pid'] != @old_pid
      rescue StandardError
      end
      sleep 0.1
    end
    raise 'Claude 服务未能提供诊断接口'
  end
  def loaded?
    _,_,status=Open3.capture3('/bin/launchctl','print',JOB)
    status.success?
  end
  def syntax(bytes)
    Tempfile.create(['native-syntax-','.rb']) do |f|
      f.binmode; f.write(bytes); f.flush
      _,_,s=Open3.capture3('/usr/bin/ruby','-EUTF-8:UTF-8','-c',f.path)
      raise '源码语法检查失败' unless s.success?
    end
  end
  def patch(service, check)
    marker="\nif $PROGRAM_NAME == __FILE__\n"
    unless service.include?("require_relative 'claude-desktop-lulu'")
      raise '服务入口版本不匹配' unless service.scan(marker).size == 1
      service=service.sub(marker,"\nrequire_relative 'claude-desktop-lulu'\n"+marker)
    end
    unless service.include?("require_relative 'claude-failure-grace'")
      raise '服务入口版本不匹配' unless service.scan(marker).size == 1
      service=service.sub(marker,"\nrequire_relative 'claude-failure-grace'\n"+marker)
    end
    anchor="        current = processes\n"
    unless service.include?("        verify_firewall!\n")
      raise '监控循环版本不匹配' unless service.scan(anchor).size == 1
      service=service.sub(anchor,"        verify_firewall!\n"+anchor)
    end
    old_registration = "        current.each_key do |pid|\n          registered = @guard.record('launch', pid)"
    new_registration = "        current.each do |pid, expected|\n          registered = @guard.register_expected(pid, expected)"
    unless service.include?(new_registration)
      raise '进程登记循环版本不匹配' unless service.scan(old_registration).size == 1
      service=service.sub(old_registration,new_registration)
    end
    check=check.sub('started >= 15', 'started >= 35')
    unless check.include?("report('故障保留 Claude 窗口'")
      cleanup_line = check.lines.find { |line| line.include?("report('故障清理 Claude 进程'") }
      raise '自检进程策略入口不匹配' unless cleanup_line
      replacement = "    if snapshot.dig('fault_grace', 'mode') == 'hold_while_firewall_valid'\n" +
        "      retained = baseline.all? { |pid, stamp| @guard.identity(pid) == stamp }\n" +
        "      report('故障保留 Claude 窗口', observed_closed && retained ? '通过' : '未验证', '核对断流证据与故障前进程身份；防火墙有效时不再按代理故障时长清理进程')\n" +
        "    else\n" + cleanup_line + "    end\n"
      check=check.sub(cleanup_line,replacement)
    end
cleanup_line = check.lines.find { |line| line.include?("report('故障清理 Claude 进程'") }
if cleanup_line && !cleanup_line.include?('termination_events')
  check=check.sub(cleanup_line,"    report('故障清理 Claude 进程', observed_cleanup && snapshot.dig('fault_grace', 'termination_events').to_i > before.dig('fault_grace', 'termination_events').to_i && snapshot.dig('fault_grace', 'last_termination', 'cause') == 'proxy_failure' ? '通过' : '未验证', '核对故障前进程身份、进程消失及监控故障终止审计')\n")
end
    check=check.sub("require_relative 'claude-local-intercept'", "require_relative 'claude-native-intercept'")
    check=check.sub('ClaudeLocalIntercept.new(self).run','ClaudeNativeIntercept.new(self).run')
    raise '自检入口版本不匹配' unless check.include?('ClaudeNativeIntercept.new(self).run') && check.include?("require_relative 'claude-native-intercept'")
check=check.sub('break if observed_closed && observed_cleanup', "break if observed_closed && observed_cleanup && snapshot.dig('fault_grace', 'termination_events').to_i > before.dig('fault_grace', 'termination_events').to_i && snapshot.dig('fault_grace', 'last_termination', 'cause') == 'proxy_failure'") unless check.include?("break if observed_closed && observed_cleanup && snapshot.dig")
check=check.sub("JSON.pretty_generate('time' => Time.now.utc.iso8601, 'results' => @results)", 'JSON.pretty_generate(selfcheck_payload)')
marker="if $PROGRAM_NAME == __FILE__\n"
check=check.sub(marker,"require_relative 'claude-selfcheck-evidence'\n\n"+marker) unless check.include?("require_relative 'claude-selfcheck-evidence'")
    check=check.sub("    observed_cleanup = false\n", "    observed_cleanup = false\n    snapshot = nil\n") unless check.include?("    snapshot = nil\n")
unless service.include?("require_relative 'claude-icon-launch'")
  service=service.sub("if $PROGRAM_NAME == __FILE__\n", "require_relative 'claude-icon-launch'\n\nif $PROGRAM_NAME == __FILE__\n")
end
unless service.include?('icon_worker = Thread.new')
  service=service.sub('    worker = Thread.new { monitor }', "    worker = Thread.new { monitor }\n    icon_worker = Thread.new { monitor_icon_launches }")
  service=service.sub("    worker&.kill\n", "    icon_worker&.kill\n    icon_worker&.join\n    worker&.kill\n")
  service=service.sub("      raise '健康监控线程停止' unless worker.alive?", "      raise '健康监控线程停止' unless worker.alive?\n      raise '图标启动监控线程停止' unless icon_worker.alive?")
end
unless service.include?("require_relative 'claude-health-confirmation'")
  service=service.sub("if $PROGRAM_NAME == __FILE__\n", "require_relative 'claude-health-confirmation'\n\nif $PROGRAM_NAME == __FILE__\n")
end
    [service,check]
  end
  def install
    validate_environment
    lock=File.open(File.join(STATE,'selfcheck.lock'),File::RDWR|File::CREAT,0600)
    raise '自检或更新正在运行' unless lock.flock(File::LOCK_EX|File::LOCK_NB)
    paths=%w[service.rb selfcheck.rb claude-lulu-gate.rb claude-lulu-readonly.rb claude-desktop-lulu.rb claude-native-intercept.rb claude-local-intercept.rb claude-failure-grace.rb claude-selfcheck-evidence.rb claude-icon-launch.rb claude-health-confirmation.rb].map { |n| File.join(STATE,n) }
    originals=paths.to_h do |path|
      raise '目标为符号链接' if File.symlink?(path)
      [path,File.file?(path) ? [File.binread(path),File.stat(path).mode & 0777] : nil]
    end
    raise '缺少现有统一服务或自检' unless originals[paths[0]] && originals[paths[1]]
    service,check=patch(originals[paths[0]][0].dup.force_encoding('UTF-8'),originals[paths[1]][0].dup.force_encoding('UTF-8'))
    updates={paths[0]=>[service.b,originals[paths[0]][1]],paths[1]=>[check.b,originals[paths[1]][1]]}
    paths.drop(2).each { |path| updates[path]=[File.binread(File.join(__dir__,File.basename(path))),0600] }
    updates.each_value { |bytes,_| syntax(bytes) }
    if updates.all? { |path,value| value==originals[path] }
      puts '原生沙箱兼容更新已安装，无需重启。'; return
    end
    originals.each do |path,prior|
      raise '安装检查期间文件变化' unless prior ? File.binread(path)==prior[0] : !File.exist?(path)
    end
    stopped=false; written=[]
    begin
      stop; stopped=true
      updates.each { |path,(bytes,mode)| atomic(path,bytes,mode); written << path }
      @start_attempted=true
      start
    rescue Exception
      # If startup partially succeeded, stop the new instance before rollback.
      if stopped
        # A partially started replacement must stop before files are restored.
        # Never suppress a stop failure and overwrite a still-running service.
        stop if @start_attempted && loaded?
        written.reverse_each do |path|
          prior=originals[path]
          prior ? atomic(path,*prior) : File.unlink(path)
        end
        start
      end
      raise
    end
    puts '已更新 Claude 桌面启动与自检，保留原生子进程沙箱；只重载了 Claude 统一服务。'
  ensure
    lock&.close
  end
end
if $PROGRAM_NAME == __FILE__
  begin; ClaudeNativeInstaller.new.install
  rescue StandardError => e; warn(e.is_a?(RuntimeError) ? e.message : "更新失败（#{e.class}）"); exit 1
  end
end
