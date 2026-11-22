require File.join(Dir.home, '.claude-unified', 'selfcheck')
require_relative 'claude-health-confirmation'
class StopTest < Exception; end
class HealthHarness < EmbeddedClaudeGuard
 attr_reader :kills,:closes,:seen_review
 def initialize(results,hard=false)
  super();@results=results;@hard=hard;@kills=[];@closes=[]
  @route={path:['local',['GLOBAL','node'],'node'],expires:now+12};@sessions={123=>'birth'};@tunnels={:client=>:upstream}
 end
 def running_route;raise '请打开 Clash 全局模式和 TUN' if @hard;['local',['GLOBAL','node'],'node'];end
 def measured_probe(purpose='primary')
  @seen_review=health_review_pending? if @results.size==1
  @last_probe={'curl_exit'=>28,'http_status'=>'000'};@results.shift
 end
 def shutdown(s);@closes<<s;end
 def identity(pid);'birth';end
 def terminate(pids,tree:true);@kills << pids;end
 def reject_selector;end
 def sleep(_);raise StopTest;end
 def ready?;!!@route;end
end
[[[false,true],false,false],[[false,false],false,true],[[true],true,true]].each do |seq,hard,killed|
 h=HealthHarness.new(seq,hard);begin;h.monitor;rescue StopTest;end
 raise 'wrong termination' unless !h.kills.empty? == killed
 raise 'streams not closed' unless h.closes==[:client,:upstream]
 raise 'review was not active' if !hard && !h.seen_review
 raise 'pending review leaked' if h.health_review_pending?
 raise 'did not restore route' if !killed && !h.ready?
end
puts 'PASS transient disconnect without kill, repeated failure termination, hard failure termination'
class DesktopReviewHarness < ClaudeDesktopService
 attr_reader :test_events
 def initialize(review,firewall)
  @mutex=Mutex.new;@streams={:socket=>true};@test_events=[];@firewall=firewall
  events=@test_events;@guard=Object.new
  @guard.define_singleton_method(:confirmed_close_reason){nil}
  @guard.define_singleton_method(:health_review_pending?){review}
  @guard.define_singleton_method(:shutdown){|_|events<<:closed}
  @guard.define_singleton_method(:terminate){|_|events<<:terminated}
 end
 def processes;{};end
end
[[true,true,'代理不可用',[:closed]], [false,true,'代理不可用',[:closed]], [false,true,'健康检查超时',[:closed]], [true,nil,'代理不可用',[:closed,:terminated]], [true,true,'监控退出',[:closed,:terminated]]].each do |review,firewall,reason,expected|
 d=DesktopReviewHarness.new(review,firewall);d.close_gate(reason);raise 'desktop fail-closed boundary failed' unless d.test_events==expected
end
puts 'PASS desktop bounded-review hold, confirmed failure, firewall loss and shutdown'
h=EmbeddedClaudeGuard.new
[[0,'401|200|0.01|0.20|0.30',true,'reachable'],[0,'429|200|0.01|0.20|0.30',true,'reachable'],[0,'503|200|0.01|0.20|0.30',true,'reachable'],[28,'000|200|0.01|0.20|8.0',false,'http_response'],[60,'000|200|0.01|0|0.3',false,'tls_handshake'],[56,'000|000|0.01|0|0.3',false,'proxy_connect_or_route_validation'],[0,'401|000|0.01|0.20|0.30',false,'proxy_connect_or_route_validation']].each do |exitcode,output,expected,stage|
 status=Struct.new(:exitstatus){def success?;exitstatus==0;end}.new(exitcode)
 r=h.probe_result(output,status,h.now,'test')
 raise "bad classification #{output}" unless r['reachable']==expected && r['stage']==stage
end
puts 'PASS HTTP errors are not transport failures; TLS, response timeout and CONNECT failures stay closed'
class VisibilityHarness < HealthHarness
 def initialize(stage,expired=false)
  super([false,false]);@stage=stage
  @visibility_hold_started=now-31 if expired
 end
 def measured_probe(purpose='primary')
  @last_probe={'curl_exit'=>56,'http_status'=>'000','tunnel_failure'=>{'stage'=>@stage}}
  false
 end
end
[['route_visibility_pending',false,false],['route_visibility_pending',true,false],['route_mismatch',false,true],['controller_unavailable',false,true],['connect',false,true]].each do |stage,expired,killed|
 h=VisibilityHarness.new(stage,expired);begin;h.monitor;rescue StopTest;end
 raise 'visibility termination boundary' unless (!h.kills.empty?) == killed
 raise 'visibility leaked traffic' if h.ready?
 raise 'visibility failed to close streams' unless h.closes==[:client,:upstream]
 raise 'visibility hold not active' if !killed && !h.health_review_pending?
end
puts 'PASS missing telemetry retains closed beyond 30s; mismatch, controller and transport failures terminate'
class VisibilityRecoveryHarness < HealthHarness
 def initialize
  super([false,false,true]);@sleeps=0
 end
 def measured_probe(purpose='primary')
  result=@results.shift
  @last_probe={'curl_exit'=>result ? 0 : 56,'tunnel_failure'=>{'stage'=>'route_visibility_pending'}}
  result
 end
 def sleep(_)
  @sleeps+=1
  raise StopTest if @sleeps>=2
 end
end
h=VisibilityRecoveryHarness.new;begin;h.monitor;rescue StopTest;end
raise 'recovery failed' unless h.kills.empty? && h.ready? && !h.health_review_pending? && !h.health_diagnostics['visibility_hold_active']
puts 'PASS visibility recovery restores only verified route and retains process'
h=HealthHarness.new([false,false]);started=h.now-29;h.instance_variable_set(:@visibility_hold_started,started);h.suspend_health_connections
raise 'inconclusive hold lost' unless h.health_review_pending? && h.instance_variable_get(:@health_review_until).nil?
puts 'PASS inconclusive hold is not tied to a termination deadline'
