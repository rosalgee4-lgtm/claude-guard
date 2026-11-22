# encoding: UTF-8
require_relative 'claude-local-intercept'
require_relative 'claude-lulu-gate'
require 'tmpdir'
require 'fileutils'
require 'fiddle'

# Keep Chromium's own sandbox. The verified, existing LuLu rules enforce egress.
# Each round uses a new profile, never a copy of the user's authenticated profile.
class ClaudeNativeIntercept < ClaudeLocalIntercept
  OBSERVATION_SECONDS = 8
  def preflight
    super
    @firewall = ClaudeLuLuGate.new
    @firewall.verify!
    @scratch = Dir.mktmpdir('claude-guard-check-')
    @round = 0
    @sandboxed = {}
    library = Fiddle.dlopen('/usr/lib/system/libsystem_sandbox.dylib')
    @sandbox_library = library
    @sandbox_check = Fiddle::Function.new(library['sandbox_check'],
      [Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT], Fiddle::TYPE_INT)
    report('Claude 签名及 LuLu 前置核验', '通过', '核对主程序、全部 Helper、crashpad 的签名身份、仅允许固定端口的规则及已启用扩展；未修改规则')
  end
  def profile_for(port)
    # The external Seatbelt policy cannot be reapplied by Chromium children.
    # No --no-sandbox switch and no executable/signature/fuse changes are used.
    nil
  end
  def inventory
    super
    @identity_mutex.synchronize do
      @identities.each do |pid, identity|
        @sandboxed[identity[:path]] = true if @sandbox_check.call(pid, 0, 0) == 1
      end
    end
  end
  def cleanup_claude
    super
    @safe_delete = true
  end
  def browser_arguments(address, data)
    ["--user-data-dir=#{data}", "--proxy-server=#{address}", '--proxy-bypass-list=<-loopback>', '--disable-quic']
  end
  def launch_test(_profile, host, port)
    @firewall.unchanged!
    @round += 1
    data = File.join(@scratch, "round-#{@round}")
    Dir.mkdir(data, 0700)
    address = "http://#{host.include?(':') ? "[#{host}]" : host}:#{port}"
    env = ClaudeGuard::PROXY_KEYS.to_h { |key| [key, address] }
    env.merge!('NO_PROXY'=>'', 'no_proxy'=>'', 'ELECTRON_RUN_AS_NODE'=>nil, 'NODE_OPTIONS'=>nil)
    @safe_delete = false
    pid = spawn_test(env, browser_arguments(address, data))
    waiter = Process.detach(pid)
    deadline = now + OBSERVATION_SECONDS
    until now >= deadline
      @firewall.unchanged!
      raise '测试期间专用代理不可用' unless @check.control('status')['ok']
      inventory
      drain
      inspect_connections(port)
      raise 'Claude 原生测试进程提前退出，无法验收启动' unless waiter.alive?
      sleep 0.25
    end
    report("原生沙箱启动（第#{@round}轮）", '通过', "主进程持续运行#{OBSERVATION_SECONDS}秒；使用独立空白配置及原生子进程沙箱，没有关闭沙箱的参数")
  end
  def spawn_test(env, arguments)
    Process.spawn(env, APP, *arguments,
      in: File::NULL, out: File::NULL, err: File::NULL, close_others: true)
  end
  def prepare_tests
    negative_evidence = @evidence
    @evidence = ClaudeLuLuEvidence.new(17893, method(:resolve))
    @established = {}
    launch_test(nil, '127.0.0.1', 17893)
    @positive_paths = @established.keys.select { |_, family| family == 'IPv4' }.map(&:first)
    report('允许端口同身份正对照', @positive_paths.empty? ? '未验证' : '通过',
      @positive_paths.empty? ? '没有观察到真实 Claude 可执行文件建立固定代理连接' : "已观察到 #{@positive_paths.map { |path| File.basename(path) }.uniq.join('、')} 建立127.0.0.1:17893连接")
    report('Chromium 子进程原生沙箱', @sandboxed.keys.any? { |p| p.include?('Claude Helper') } ? '通过' : '未验证',
      '使用系统 sandbox_check 查询实际进程；仅记录观察到的沙箱状态，不等于该进程已完成拦截验收')
  ensure
    cleanup_claude
    @evidence = negative_evidence
  end
  def block_has_control?(key)
    Array(@positive_paths).include?(key[0])
  end
  def run
    super
  ensure
    if @scratch && @safe_delete && File.directory?(@scratch)
      FileUtils.remove_entry_secure(@scratch)
    end
  end
end
