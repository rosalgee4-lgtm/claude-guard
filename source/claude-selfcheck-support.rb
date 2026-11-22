# encoding: UTF-8
require 'time'
# Store only counters and timestamps, never proxy credentials or request data.
class EmbeddedClaudeGuard
  alias_method :initialize_without_audit, :initialize
  alias_method :close_gate_without_audit, :close_gate

  def initialize
    initialize_without_audit
    @audit_mutex = Mutex.new
    @audit = {'events' => 0, 'tunnels_closed' => 0}
  end

  def close_gate(reason)
    count = @mutex.synchronize { @tunnels.size }
    close_gate_without_audit(reason)
    @audit_mutex.synchronize do
      @audit['events'] += 1
      @audit['tunnels_closed'] += count
      @audit['time'] = Time.now.utc.iso8601
    end
    warn "#{Time.now.utc.iso8601} 专用引擎关闭连接，数量=#{count}" if count.positive?
  end

  def audit_snapshot
    @audit_mutex.synchronize { @audit.dup }
  end
end

class ClaudeDesktopService
  alias_method :serve_without_audit, :serve

  def serve
    warn "#{Time.now.utc.iso8601} 统一监控启动，PID=#{Process.pid}，固定入口=127.0.0.1:17893"
    serve_without_audit
  ensure
    warn "#{Time.now.utc.iso8601} 统一监控退出"
  end

  def selfcheck_snapshot
    {'pid' => Process.pid, 'proxy_ready' => !proxy.nil?, 'engine' => @guard.audit_snapshot}
  end
end
