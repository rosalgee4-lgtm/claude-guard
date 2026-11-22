require_relative 'test-claude-health-confirmation'

class DeadlineClockHarness < VisibilityHarness
 attr_accessor :clock
 def now;@clock || 100.0;end
end
class DeadlineDesktopHarness < ClaudeDesktopService
 def initialize(guard)
  @guard=guard;@firewall=true;@mutex=Mutex.new;@streams={};@proxy=nil
 end
 def processes;{123=>'birth'};end
end
h=DeadlineClockHarness.new('route_visibility_pending');begin;h.monitor;rescue StopTest;end
d=DeadlineDesktopHarness.new(h)
[110.1,120.1,130.0,400.0,3700.0].each do |t|
 h.clock=t;d.close_gate('代理不可用，Claude 连接已关闭')
 raise "premature desktop termination at #{t-100}s" unless h.kills.empty?
 h.suspend_health_connections
 raise 'hold lost' unless h.health_review_pending? && h.instance_variable_get(:@health_review_until).nil?
end
h.close_gate('confirmed hard failure');d.close_gate('代理不可用，Claude 连接已关闭');raise 'hard failure did not terminate' if h.kills.empty?
puts 'PASS desktop retains at 30s/300s/3600s while closed; explicit hard failure still terminates'
lease=HealthHarness.new([])
lease.instance_variable_get(:@route)[:expires]=lease.now-1
lease.close_gate('代理探测已超时')
raise 'expired route retained or process killed' unless !lease.ready? && lease.kills.empty? && lease.closes==[:client,:upstream]
puts 'PASS engine lease expiry closes tunnels and keeps process'
