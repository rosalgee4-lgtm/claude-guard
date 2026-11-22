require_relative 'test-claude-unified'
require_relative 'claude-unified-service'
require_relative 'claude-selfcheck-support'
$LOADED_FEATURES << File.join(Dir.home, '.claude-unified', 'service.rb')
require_relative 'claude-selfcheck'

guard = EmbeddedClaudeGuard.new
left, right = UNIXSocket.pair
peer, upstream = UNIXSocket.pair
guard.instance_variable_get(:@tunnels)[left] = upstream
guard.close_gate('test')
raise 'missing closure counter' unless guard.audit_snapshot['tunnels_closed'] == 1
raise 'socket not closed' unless right.read == '' && peer.read == ''
raise 'credentials in diagnostics' unless guard.audit_snapshot.keys.sort == %w[events time tunnels_closed]
[right, peer].each(&:close)
puts 'PASS real engine closes sockets and exposes only counters/timestamps'

class FakeCheckGuard
  attr_reader :changes
  def initialize
    @changes = []
  end
  def running_route
    ['/fake/controller.sock', ['GLOBAL', 'CURRENT_NODE'], 'CURRENT_NODE']
  end
  def set_selector(path, choice)
    @changes << [path, choice]
    true
  end
  def identity(pid); nil; end
  def terminate(pids); end
end
class FakeScanner
  def initialize; @calls = 0; end
  def processes
    @calls += 1
    @calls <= 2 ? {123 => 'identity'} : {}
  end
end
class SimulatedSelfcheck < ClaudeSelfcheck
  attr_reader :results, :guard
  attr_accessor :fail_diagnostics
  def initialize
    @guard = FakeCheckGuard.new
    @scanner = FakeScanner.new
    @results = {}
    @snapshots = 0
  end
  def control(action)
    if action == 'diagnostics'
      @snapshots += 1
      raise 'injected control failure' if @fail_diagnostics && @snapshots > 1
      {'diagnostics' => {'pid' => 345, 'proxy_ready' => true, 'engine' => {'tunnels_closed' => @snapshots - 1}}}
    else
      {'ok' => true}
    end
  end
  def tunnel
    @socket, peer = UNIXSocket.pair
    peer.close
    @socket
  end
end
check = SimulatedSelfcheck.new
check.outage_test
raise 'closure not validated' unless check.results['故障断开已有连接']['state'] == '通过'
raise 'process disappearance falsely attributed to cleanup' unless check.results['故障清理 Claude 进程']['state'] == '未验证'
raise 'did not restore current selection' unless check.guard.changes.map(&:last) == ['REJECT', 'CURRENT_NODE']
check = SimulatedSelfcheck.new
check.fail_diagnostics = true
begin
  check.outage_test
rescue RuntimeError => e
  raise unless e.message == 'injected control failure'
end
raise 'failed test did not restore' unless check.guard.changes.last.last == 'CURRENT_NODE'
puts 'PASS fault verification, exception recovery, current-node restoration'

class ProbeSelfcheck < SimulatedSelfcheck
  def node_probe_supported?; true; end
  def probe(host, port); port == 17893 ? 'CONNECTED' : 'TIMEOUT'; end
end
# Prevent actual external networking; a failed control must stay unverified.
class << Socket
  alias_method :tcp_before_selfcheck_test, :tcp
  def tcp(*args, **options); raise Errno::ENETUNREACH; end
end
check = ProbeSelfcheck.new
check.direct_test
raise 'timeout falsely accepted' unless check.results['非授权本机端口']['state'] == '未验证'
raise 'unreachable control falsely accepted' unless check.results['IPv4 直连']['state'] == '未验证'
class << Socket
  alias_method :tcp, :tcp_before_selfcheck_test
end
puts 'PASS timeout and unreachable baseline never count as blocking success'
