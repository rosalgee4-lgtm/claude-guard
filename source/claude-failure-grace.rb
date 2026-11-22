# encoding: UTF-8
# Fail closed after confirmed health failure; claude-health-confirmation.rb allows one bounded probe review.
require 'time'
module ClaudeFailureGrace
  def initialize(*args)
    @fault_mutex = Mutex.new
    @termination_events = 0
    @last_termination = nil
    super
  end
  # Retained for compatibility with callers; no grace or process retention.
  def with_failure_grace
    yield
  end
  def close_gate(reason)
    prior = Thread.current[:claude_termination_cause]
    Thread.current[:claude_termination_cause] = prior || (reason == '监控退出' ? 'monitor_shutdown' : 'proxy_failure')
    super
  ensure
    Thread.current[:claude_termination_cause] = prior
  end
  def terminate(pids, tree: true)
    live = pids.select { |pid, stamp| stamp && identity(pid) == stamp }
    result = super
    unless live.empty?
      entry = {'time'=>Time.now.utc.iso8601,
        'cause'=>Thread.current[:claude_termination_cause] || 'explicit_cleanup',
        'pids'=>live.keys, 'remaining'=>live.keys.select { |pid| identity(pid) == live[pid] }}
      @fault_mutex.synchronize { @termination_events += 1; @last_termination = entry }
      warn JSON.generate('claude_termination'=>entry)
    end
    result
  end
  def fault_snapshot
    @fault_mutex.synchronize do
      {'mode'=>'terminate_immediately', 'grace_seconds'=>0, 'waiting'=>false,
       'elapsed_seconds'=>0, 'pending_processes'=>0,
       'termination_events'=>@termination_events, 'last_termination'=>@last_termination}
    end
  end
end
EmbeddedClaudeGuard.prepend(ClaudeFailureGrace)

module ClaudeDesktopFailureGrace
  def close_gate(reason)
    prior = Thread.current[:claude_termination_cause]
    Thread.current[:claude_termination_cause] = if reason == '监控退出'
      'monitor_shutdown'
    elsif !@firewall
      'firewall_unverified'
    else
      'proxy_failure'
    end
    super
  ensure
    Thread.current[:claude_termination_cause] = prior
  end
  def selfcheck_snapshot
    super.merge('fault_grace'=>@guard.fault_snapshot)
  end
end
ClaudeDesktopService.prepend(ClaudeDesktopFailureGrace)
