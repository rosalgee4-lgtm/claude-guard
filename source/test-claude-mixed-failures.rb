require_relative 'test-claude-health-confirmation'
cases={pending:{'tunnel_failure'=>{'stage'=>'route_visibility_pending'}},http_timeout:{'stage'=>'http_response','error_class'=>'Timeout::Error'},tls:{'stage'=>'tls_handshake','error_class'=>'OpenSSL::SSL::SSLError'},mismatch:{'tunnel_failure'=>{'stage'=>'route_mismatch'}},controller:{'tunnel_failure'=>{'stage'=>'controller_unavailable'}},connect:{'tunnel_failure'=>{'stage'=>'connect'}},unknown:{},http_eof:{'stage'=>'http_response','error_class'=>'EOFError'}}
class MixedPairHarness < HealthHarness
 def initialize(first,second,expired=false)
  super([first,second]);@visibility_hold_started=now-31 if expired
 end
 def measured_probe(purpose='primary');@last_probe=@results.shift;false;end
end
count=0
cases.each do |a,first|
 cases.each do |b,second|
  expected=[a,b].include?(:pending) && ([a,b]-[:pending,:http_timeout]).empty?
  h=MixedPairHarness.new(first,second);begin;h.monitor;rescue StopTest;end
  raise "wrong decision #{a}/#{b}" unless (h.kills.empty?) == expected
  raise 'gate reopened on failure' if h.ready?
  raise 'streams survived failure' unless h.closes==[:client,:upstream]
  if expected
   raise 'review absent' unless h.health_review_pending?
   h=MixedPairHarness.new(first,second,true);begin;h.monitor;rescue StopTest;end
   raise 'inconclusive expiry killed process' unless h.kills.empty? && h.health_review_pending?
  end
  prior=MixedPairHarness.new(first,second,true);begin;prior.monitor;rescue StopTest;end
  raise 'prior hold masked confirmed failure' unless prior.kills.empty? == expected
  count+=1
 end
end
puts "PASS #{count} ordered pairs; mixed orders held closed, hard failures override, uncertain holds retained beyond old deadline"
