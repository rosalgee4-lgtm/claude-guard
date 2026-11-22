require_relative 'claude-local-intercept'
identity = {path: '/Applications/Claude.app/Contents/MacOS/Claude', stamp: 'fixed-birth'}
resolver = ->(pid) { pid == 51 ? identity : nil }
def event(message, thread = 2)
  {'subsystem'=>'com.objective-see.lulu','processImagePath'=>'/x/com.objective-see.lulu.extension/y',
   'processID'=>9,'threadID'=>thread,'eventMessage'=>message}
end
messages = ['remote endpoint: 127.0.0.1:23456 / url: (null)',
 'found matching rule for 51/Claude: RULE: pid: all, path: /x, action: 0, type: 3, disabled: 0, creation: x',
 'setting verdict to: BLOCK', 'verdict: block']
check = ClaudeLuLuEvidence.new(23456, resolver)
messages.each_with_index { |message, i| check.feed(event(message), 1.0 + i * 0.1) }
raise 'valid rejection missing' unless check.blocked[[identity[:path], 'IPv4']]
check = ClaudeLuLuEvidence.new(23456, resolver)
messages.each_with_index { |message, i| check.feed(event(message, i == 3 ? 3 : 2), 1.0 + i * 0.1) }
raise 'mixed threads accepted' unless check.blocked.empty?
check = ClaudeLuLuEvidence.new(23456, resolver)
messages.each_with_index { |message, i| check.feed(event(message), i.to_f) }
raise 'stale evidence accepted' unless check.blocked.empty?
check = ClaudeLuLuEvidence.new(23456, resolver)
messages.each_with_index { |message, i| check.feed(event(message.sub('23456','234567')), 1.0 + i * 0.1) }
raise 'wrong port accepted' unless check.blocked.empty?
check = ClaudeLuLuEvidence.new(23456, resolver)
messages.first(2).each { |message| check.feed(event(message), 1.0) }
identity = {path: identity[:path], stamp: 'reused-pid'}
messages.last(2).each { |message| check.feed(event(message), 1.1) }
raise 'reused pid accepted' unless check.blocked.empty?
check = ClaudeLuLuEvidence.new(23456, resolver)
check.feed(event(messages[0]), 1)
check.feed(event(messages[1]), 1.1)
check.feed(event('verdict: allow'), 1.2)
raise 'allow not recorded' unless check.allowed[[identity[:path], 'IPv4']]
puts 'PASS rejection chain, thread isolation, time bound, exact port, PID reuse, allow detection'

# Validate cleanup/restoration even when a fault occurs after launch.
class SimulatedLocal < ClaudeLocalIntercept
  attr_reader :cleanups, :restored
  attr_accessor :inject_failure
  def initialize
    @streams = []; @cleanups = 0; @observed = {}
    @scanner = Object.new
    def @scanner.processes; {51=>'birth'}; end
    @check = Object.new
    def @check.control(action); {'ok'=>true}; end
  end
  def preflight; end
  def profile_for(port); 'test-profile'; end
  def start_log; end
  def stop_log; end
  def resolve(pid); nil; end
  def targets; []; end
  def report(name, state, detail)
    @restored = state == '通过' if name == '本机拦截测试后恢复Claude'
  end
  def cleanup_claude; @cleanups += 1; end
  def launch_test(*args)
    raise 'injected test failure' if @inject_failure
  end
end
[false, true].each do |failure|
  instance = SimulatedLocal.new
  instance.inject_failure = failure
  begin
    instance.run
    raise 'missing injected failure' if failure
  rescue RuntimeError => e
    raise unless failure && e.message == 'injected test failure'
  end
  raise 'application not restored' unless instance.restored
  raise 'cleanup missing' unless instance.cleanups >= 2
  raise 'canary listener leaked' unless instance.instance_variable_get(:@server4).closed? && instance.instance_variable_get(:@server6).closed?
end
puts 'PASS normal/fault cleanup, app restoration, IPv4/IPv6 listener closure'

# Substring matches must never turn a non-loopback target into local evidence.
['1127.0.0.1:23456', '[2001:db8::1]:23456', '127.0.0.1:443 extra 23456'].each do |endpoint|
  check = ClaudeLuLuEvidence.new(23456, resolver)
  ["remote endpoint: #{endpoint} / url: (null)", *messages.drop(1)].each_with_index do |message, i|
    check.feed(event(message), 1.0 + i * 0.1)
  end
  raise 'non-target endpoint accepted' unless check.blocked.empty?
end
['[::1]:23456', '::1:23456', '::1.23456'].each do |endpoint|
  check = ClaudeLuLuEvidence.new(23456, resolver)
  ["remote endpoint: #{endpoint} / url: (null)", *messages.drop(1)].each_with_index do |message, i|
    check.feed(event(message), 1.0 + i * 0.1)
  end
  raise 'IPv6 target missing' unless check.blocked[[identity[:path], 'IPv6']]
end
check = ClaudeLuLuEvidence.new(23456, resolver)
[messages[0], messages[1], messages[1], *messages.last(2)].each_with_index do |message, i|
  check.feed(event(message), 1.0 + i * 0.1)
end
raise 'ambiguous repeated rule accepted' unless check.blocked.empty?
puts 'PASS exact IPv4/IPv6 endpoints and ambiguous rule rejection'

class LostLogLocal < SimulatedLocal
  attr_reader :states
  def initialize
    super
    @states = []
  end
  def targets; ['/test/Claude']; end
  def launch_test(*args)
    @evidence.blocked[['/test/Claude', 'IPv4']] = true
    @log_failed = true
  end
  def report(name, state, detail)
    @states << state if name.include?('本机越权连接')
    super
  end
end
lost = LostLogLocal.new
lost.run
raise 'incomplete log evidence passed' if lost.states.include?('通过')
puts 'PASS incomplete log evidence cannot pass target checks'

banner = 'Filtering the log data using "subsystem == "com.objective-see.lulu""'
parser = ClaudeLocalIntercept.allocate
sink = Object.new
class << sink
  attr_reader :received
  def feed(event, now); @received = event; end
end
parser.instance_variable_set(:@evidence, sink)
parser.ingest_log_line(banner + "\n")
raise 'macOS banner flagged as corruption' if parser.instance_variable_get(:@log_failed)
parser.ingest_log_line(JSON.generate(event('verdict: block')))
raise 'valid event lost' unless sink.received
parser.ingest_log_line(banner)
raise 'unexpected repeated banner ignored' unless parser.instance_variable_get(:@log_failed)
['not json', 'null', '[]'].each do |line|
  parser = ClaudeLocalIntercept.allocate
  parser.ingest_log_line(line)
  raise 'malformed log accepted' unless parser.instance_variable_get(:@log_failed)
end
puts 'PASS exact first-line macOS banner, valid JSON, malformed and repeated banner detection'
