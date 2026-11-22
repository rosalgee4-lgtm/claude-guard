require 'json'
class EmbeddedClaudeGuard
  attr_reader :events
  def initialize; @events=[]; end
  def identity(pid); pid==11 ? 'birth' : nil; end
  def close_gate(reason); @events << :closed; terminate({11=>'birth'}); end
  def terminate(pids,tree:true); @events << :terminated; end
end
class ClaudeDesktopService
  def initialize(g,firewall=true); @guard=g; @firewall=firewall; end
  def close_gate(reason); @guard.close_gate(reason); end
  def selfcheck_snapshot; {}; end
end
require_relative 'claude-failure-grace'
g=EmbeddedClaudeGuard.new
g.close_gate('proxy failed')
raise 'wrong order' unless g.events==[:closed,:terminated]
raise 'missing termination' unless g.fault_snapshot['termination_events']==1
raise 'wrong reason' unless g.fault_snapshot['last_termination']['cause']=='proxy_failure'
raise 'retention enabled' unless g.fault_snapshot['mode']=='terminate_immediately' && g.fault_snapshot['grace_seconds']==0
raise 'thread cause leaked' unless Thread.current[:claude_termination_cause].nil?
g=EmbeddedClaudeGuard.new
ClaudeDesktopService.new(g).close_gate('proxy unavailable')
raise 'desktop kept alive' unless g.events==[:closed,:terminated]
g=EmbeddedClaudeGuard.new; g.close_gate('监控退出')
raise 'shutdown cause missing' unless g.fault_snapshot['last_termination']['cause']=='monitor_shutdown'
puts 'PASS immediate termination, socket-close ordering, desktop path, audit and cause cleanup'
