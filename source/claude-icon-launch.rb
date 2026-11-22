# Adopt ordinary LaunchServices launches without modifying the signed application.
module ClaudeIconLaunch
  def unprotected_desktop_main
    rows,_,status=Open3.capture3('/bin/ps','-axo','pid=,comm=')
    raise '无法检查桌面启动方式' unless status.success?
    rows.each_line do |line|
      match=line.match(/^\s*(\d+)\s+(.+?)\s*$/)
      next unless match && match[2]==self.class::APP
      pid=match[1].to_i; stamp=@guard.identity(pid); next unless stamp
      args,_,ok=Open3.capture3('/bin/ps','-ww','-p',pid.to_s,'-o','args=')
      next unless ok.success? && @guard.identity(pid)==stamp
      expected=["--proxy-server=http://127.0.0.1:#{self.class::PORT}",'--proxy-bypass-list=<-loopback>','--disable-quic']
      return [pid,stamp] unless expected.all?{|flag|args.split.include?(flag)}
    end
    nil
  end
  def icon_launch_once
    # Do not interfere with deliberately unprotected selfcheck test instances.
    lock=File.open(File.join(self.class::STATE,'selfcheck.lock'),File::RDWR|File::CREAT,0600)
    return unless lock.flock(File::LOCK_EX|File::LOCK_NB)
    raw=unprotected_desktop_main
    return unless raw
    @launch_mutex.synchronize do
      return unless @guard.identity(raw[0])==raw[1]
      @icon_launch_status={'time'=>Time.now.utc.iso8601,'state'=>'closing_unprotected','original_pid'=>raw[0]}
      unless proxy
        @guard.terminate({raw[0]=>raw[1]})
        @icon_launch_status['state']='waiting_for_manual_protected_launch'
        @deferred_icon=raw
        return
      end
      return if @deferred_icon==raw
      victims={raw[0]=>raw[1]}
      prior=Thread.current[:claude_termination_cause]
      begin
        Thread.current[:claude_termination_cause]='unprotected_icon_launch'
        @guard.terminate(victims)
      ensure
        Thread.current[:claude_termination_cause]=prior
      end
      # No queued relaunch: an unavailable proxy leaves Claude closed.
      raise '代理未就绪，已关闭普通启动的Claude' unless proxy
      verify_firewall!
      20.times { break if processes.empty?; sleep 0.1 }
      launch
      @icon_launch_status=@icon_launch_status.merge('state'=>'protected_relaunch_complete')
    end
  rescue StandardError=>e
    @icon_launch_status={'time'=>Time.now.utc.iso8601,'state'=>'closed_or_launch_failed','error_class'=>e.class.to_s}
  ensure
    lock&.close
  end
  def monitor_icon_launches
    loop do
      icon_launch_once
      sleep 0.5
    end
  end
  def selfcheck_snapshot
    super.merge('icon_launch'=>@icon_launch_status || {'state'=>'watching'})
  end
end
ClaudeDesktopService.prepend(ClaudeIconLaunch)
