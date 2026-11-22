# encoding: UTF-8
require_relative 'claude-lulu-gate'

class EmbeddedClaudeGuard
  # The process may exit between the scanner snapshot and registration.
  # Ignore a stale identity; never register a recycled PID or close a healthy gate.
  def register_expected(pid, expected)
    @mutex.synchronize do
      return {'ok'=>false} unless @route && @route[:expires] > now
      return {'ok'=>true, 'skipped'=>true} unless expected && identity(pid) == expected
      @sessions[pid] = expected
      {'ok'=>true}
    end
  end
end

# Desktop only: retain Chromium's native child sandbox, use LuLu for egress.
# The CLI guard keeps its existing Seatbelt enforcement.
module ClaudeDesktopLuLu
  def new_firewall_gate
    ClaudeLuLuGate.new
  end
  def verify_firewall!
    changed=false
    if @firewall
      begin
        @firewall.unchanged!
      rescue StandardError
        changed=true
      end
    end
    if changed
      # Stop desktop traffic before checking the new policy; do not kill on metadata alone.
      sockets=@mutex.synchronize do
        @proxy=nil;@expires=0;@reason="LuLu设置发生变化，断流重新核验"
        current=@streams.keys;@streams.clear;current
      end
      sockets.each{|s|@guard.shutdown(s)}
    end
    if changed || !@firewall || !@firewall_checked || now-@firewall_checked>=5
      candidate=new_firewall_gate
      candidate.verify!
      @firewall=candidate;@firewall_checked=now
      @last_firewall_verification={"time"=>Time.now.utc.iso8601,"result"=>"verified","changed"=>changed}
    end
    true
  rescue StandardError=>e
    @firewall=nil
    @last_firewall_verification={"time"=>Time.now.utc.iso8601,"result"=>"failed","changed"=>changed,"error_class"=>e.class.to_s}
    warn JSON.generate("claude_firewall_verification"=>@last_firewall_verification)
    raise
  end
  def selfcheck_snapshot
    super.merge("firewall_verification"=>@last_firewall_verification)
  end

  def launch
    verify_firewall!
    raise '代理未就绪' unless proxy
    raise 'Claude 已运行，请先完全退出再从菜单启动' unless processes.empty?
    address = "http://127.0.0.1:#{self.class::PORT}"
    raise '专用代理预检失败' unless @guard.desktop_probe_ready?(address)
    raise '预检期间代理失效' unless proxy
    env = ClaudeGuard::PROXY_KEYS.to_h { |key| [key, address] }
    env.merge!('NO_PROXY'=>'', 'no_proxy'=>'', 'ELECTRON_RUN_AS_NODE'=>nil, 'NODE_OPTIONS'=>nil)
    pid = Process.spawn(env, self.class::APP, "--proxy-server=#{address}",
      '--proxy-bypass-list=<-loopback>', '--disable-quic',
      in: File::NULL, out: File::NULL, err: File::NULL, close_others: true)
    waiter = Process.detach(pid)
    registered = @guard.register_expected(pid, @guard.identity(pid))
    raise '启动期间代理失效' unless registered['ok']
    12.times do
      sleep 0.25
      verify_firewall!
      raise 'Claude 提前退出，启动未通过验收' unless waiter.alive?
      raise '启动期间代理失效' unless proxy
    end
    'Claude 已启动；原生子进程沙箱保留，LuLu 限制到固定代理入口'
  rescue StandardError
    @guard.terminate(processes) if pid
    raise
  end
end
ClaudeDesktopService.prepend(ClaudeDesktopLuLu)
