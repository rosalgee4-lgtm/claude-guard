# encoding: UTF-8
require 'socket'
require 'json'
require 'open3'
require 'timeout'
require_relative 'claude-lulu-readonly'

# A conservative parser for LuLu 4.5.7's sequential per-thread flow messages.
# Keep only PID identities, destination family and verdict. Raw messages stay in memory.
class ClaudeLuLuEvidence
  attr_reader :blocked, :allowed, :verdicts
  def initialize(port, resolver, endpoints: nil)
    @port, @resolver = port, resolver
    @endpoints = endpoints || {
      "127.0.0.1:#{port}"=>'IPv4', "[::1]:#{port}"=>'IPv6',
      "::1:#{port}"=>'IPv6', "::1.#{port}"=>'IPv6'
    }
    @flows, @blocked, @allowed = {}, {}, {}
    @verdicts = []
  end
  def feed(event, now)
    return unless event['subsystem'] == 'com.objective-see.lulu'
    return unless event['senderImagePath'].to_s.include?('com.objective-see.lulu.extension') || event['processImagePath'].to_s.include?('com.objective-see.lulu.extension')
    thread = event['threadID']
    return unless thread && event['processID']
    key = [event['processID'], thread]
    message = event['eventMessage'].to_s
    if message.start_with?('remote endpoint:')
      @flows.delete(key)
      endpoint = message.split(' / url:', 2).first.sub('remote endpoint:', '').strip
      family = @endpoints[endpoint]
      if family
        @flows[key] = {time: now, family: family, endpoint: endpoint}
      end
      return
    end
    flow = @flows[key]
    return unless flow
    if now - flow[:time] > 2
      @flows.delete(key)
      return
    end
    if (match = message.match(/\Afound matching rule for (\d+)\//))
      # Multiple rule identities in one candidate chain are ambiguous.
      if flow[:pid]
        @flows.delete(key)
        return
      end
      identity = @resolver.call(match[1].to_i)
      # Require current process identity, not only its name in a log message.
      flow[:identity] = identity
      flow[:pid] = match[1].to_i
      flow[:rule_block] = message.match?(/, action: 0,/) && message.match?(/, disabled: 0,/)
    elsif message == 'setting verdict to: BLOCK'
      flow[:block_stage] = true
    elsif message == "...but 'allow DNS traffic' is set and this is resolver DNS on the app's behalf, so allowing"
      flow[:resolver_dns_exception] = true
    elsif message == 'verdict: block' || message == 'verdict: allow'
      current = flow[:pid] && @resolver.call(flow[:pid])
      if current && current == flow[:identity]
        label = [current[:path], flow[:family]]
        if message == 'verdict: block' && flow[:rule_block] && flow[:block_stage]
          @blocked[label] = true
          @verdicts << {pid:flow[:pid], identity:current, endpoint:flow[:endpoint], verdict:'block', time:now}
        elsif message == 'verdict: allow'
          @allowed[label] = true
          @verdicts << {pid:flow[:pid], identity:current, endpoint:flow[:endpoint], verdict:'allow', time:now,
            reason:flow[:resolver_dns_exception] ? 'system_resolver_dns_exception' : 'unspecified'}
        end
      end
      @flows.delete(key)
    elsif message.start_with?('verdict:') || message.start_with?('ignoring non-outbound')
      @flows.delete(key)
    end
    @flows.delete_if { |_, data| now - data[:time] > 2 }
  end
end

class ClaudeLocalIntercept
  APP = '/Applications/Claude.app/Contents/MacOS/Claude'
  def initialize(check)
    @check = check
    @guard = check.instance_variable_get(:@guard)
    @scanner = check.instance_variable_get(:@scanner)
    @identities = {}
    @identity_mutex = Mutex.new
    @observed = {}
    @streams = []
  end
  def report(*args); @check.report(*args); end
  def now; Process.clock_gettime(Process::CLOCK_MONOTONIC); end
  def truth(value); value == true || value == 1; end
  def targets
    @targets ||= ([APP] + Dir.glob('/Applications/Claude.app/Contents/Frameworks/*.app/Contents/MacOS/*') +
      ['/Applications/Claude.app/Contents/Frameworks/Electron Framework.framework/Helpers/chrome_crashpad_handler']).select { |path| File.file?(path) }
  end
  def inventory
    rows, _, status = Open3.capture3('/bin/ps', '-axww', '-o', 'uid=', '-o', 'pid=', '-o', 'comm=')
    raise '无法读取实际进程身份' unless status.success?
    current = {}
    rows.each_line do |line|
      match = line.match(/^\s*(\d+)\s+(\d+)\s+(.+?)\s*$/)
      next unless match && match[1].to_i == Process.uid && targets.include?(match[3])
      pid = match[2].to_i
      stamp = @guard.identity(pid)
      next unless stamp
      current[pid] = {path: match[3], stamp: stamp}
      @observed[match[3]] = true
    end
    @identity_mutex.synchronize { @identities = current }
  end
  def resolve(pid)
    identity = @identity_mutex.synchronize { @identities[pid] }
    unless identity
      output, _, status = Open3.capture3('/bin/ps', '-p', pid.to_s, '-o', 'uid=', '-o', 'comm=')
      row = output.match(/\A\s*(\d+)\s+(.+?)\s*\z/)
      if status.success? && row && row[1].to_i == Process.uid && targets.include?(row[2])
        stamp = @guard.identity(pid)
        identity = {path: row[2], stamp: stamp} if stamp
        @identity_mutex.synchronize { @identities[pid] = identity } if identity
      end
    end
    identity if identity && @guard.identity(pid) == identity[:stamp]
  end
  def preflight
    prefs = LuLuReadOnly.plist('/Library/Objective-See/LuLu/preferences.plist')
    raise 'LuLu仍允许所有localhost连接；未开始主动测试' if truth(prefs['allowLocalHost'])
    raise 'LuLu已禁用；未开始主动测试' if truth(prefs['disabled'])
    raise '全局允许列表已开启，需先核对其影响；未开始主动测试' if truth(prefs['useAllowList'])
    raise '当前配置档需单独适配，未开始主动测试' if prefs['currentProfile'] && !prefs['currentProfile'].to_s.empty?
    version, _, status = Open3.capture3('/usr/libexec/PlistBuddy', '-c', 'Print :CFBundleShortVersionString', '/Applications/LuLu.app/Contents/Info.plist')
    raise '此日志解析器仅适配LuLu 4.5.7，未开始主动测试' unless status.success? && version.strip == '4.5.7'
    extensions, _, status = Open3.capture3('/usr/bin/systemextensionsctl', 'list')
    raise '未确认LuLu扩展已激活，未开始主动测试' unless status.success? && extensions.lines.any? { |line| line.include?('com.objective-see.lulu.extension') && line.include?('[activated enabled]') }
  end
  def start_log
    @log_stopping = false
    @log_failed = false
    @log_lines = 0
    @log_input, @log_output, @log_errors, @log_wait = Open3.popen3('/usr/bin/log', 'stream', '--style', 'ndjson', '--level', 'debug', '--predicate', 'subsystem == "com.objective-see.lulu"')
    @log_input.close
    @log_error_reader = Thread.new { @log_errors.each_line { |_| } }
    @log_reader = Thread.new do
      @log_output.each_line do |line|
        ingest_log_line(line)
      end
      @log_failed = true unless @log_stopping
    rescue StandardError
      @log_failed = true unless @log_stopping
    end
    sleep 0.5
    raise '无法读取LuLu实时日志，未启动Claude测试' unless @log_wait.alive?
  end
  def ingest_log_line(line)
    first = (@log_lines || 0).zero?
    @log_lines = (@log_lines || 0) + 1
    # macOS log stream writes one human-readable banner before NDJSON.
    return if first && line.strip == 'Filtering the log data using "subsystem == "com.objective-see.lulu""'
    event = JSON.parse(line)
    raise TypeError unless event.is_a?(Hash)
    @evidence.feed(event, now)
  rescue JSON::ParserError, TypeError
    @log_failed = true
  end
  def stop_log
    @log_failed = true if @log_wait && !@log_wait.alive? && !@log_stopping
    @log_stopping = true
    if @log_wait&.alive?
      Process.kill('TERM', @log_wait.pid) rescue nil
      unless @log_wait.join(2)
        Process.kill('KILL', @log_wait.pid) rescue nil
        @log_wait.join(2)
      end
    end
    [@log_output, @log_errors].compact.each { |io| io.close rescue nil }
    [@log_reader, @log_error_reader].compact.each { |thread| thread.join(2) }
  end
  def profile_for(port)
    # Only the local test port is allowed by this temporary process sandbox.
    # LuLu remains responsible for rejecting that allowed socket.
    profile = @guard.seatbelt(port) + "\n(allow network-outbound (remote tcp6 \"localhost:#{port}\"))\n"
    tcp4 = TCPServer.new('127.0.0.1', 0)
    tcp6 = TCPServer.new('::1', 0)
    udp6 = UDPSocket.new(Socket::AF_INET6)
    udp6.bind('::1', 0)
    _, _, status = @guard.command(ClaudeGuard::SBOX, '-p', profile, ClaudeGuard::RUBY, '-e', @guard.socket_tests,
                                port.to_s, tcp4.addr[1].to_s, tcp6.addr[1].to_s, udp6.addr[1].to_s)
    raise '测试沙箱出站隔离未通过；未启动Claude' unless status.success?
    %w[127.0.0.1 ::1].each do |host|
      code = "require 'socket'; Socket.tcp(ARGV[0], Integer(ARGV[1]), connect_timeout: 2) { |s| s.close }"
      _, _, status = @guard.command(ClaudeGuard::SBOX, '-p', profile, ClaudeGuard::RUBY, '-e', code, host, port.to_s)
      raise '测试端口对照连接失败；未启动Claude' unless status.success?
    end
    profile
  ensure
    [tcp4, tcp6, udp6].compact.each { |io| io.close rescue nil }
  end
  def cleanup_claude
    @guard.terminate(@scanner.processes)
    20.times do
      return if @scanner.processes.empty?
      sleep 0.1
    end
    raise 'Claude进程未全部退出；停止后续测试'
  end
  def drain
    [@server4, @server6].compact.each do |server|
      loop do
        socket = server.accept_nonblock(exception: false)
        break if socket == :wait_readable
        @streams << socket
      end
    end
  end
  def inspect_connections(port)
    text, _, = Open3.capture3('/usr/sbin/lsof', '-nP', '-a', "-iTCP:#{port}", '-sTCP:ESTABLISHED', '-Fpn')
    pid = nil
    text.each_line do |line|
      if line.start_with?('p')
        pid = line[1..-1].to_i
      elsif line.start_with?('n') && pid
        family = line.include?("->127.0.0.1:#{port}") ? 'IPv4' : (line.include?("->[::1]:#{port}") ? 'IPv6' : nil)
        identity = family && resolve(pid)
        if identity
          key = [identity[:path], family]
          @evidence.allowed[key] = true
          (@established ||= {})[key] = true
        end
      end
    end
  end
  def prepare_tests; end
  def block_has_control?(key); true; end
  def launch_test(profile, host, port)
    address = "http://#{host == '::1' ? '[::1]' : host}:#{port}"
    env = ClaudeGuard::PROXY_KEYS.each_with_object({}) { |key, result| result[key] = address }
    env.merge!('NO_PROXY' => '', 'no_proxy' => '', 'ELECTRON_RUN_AS_NODE' => nil, 'NODE_OPTIONS' => nil)
    # Test an unauthorized local proxy port using the normal launcher's switches.
    # Claude rejects the former host-resolver/no-proxy test switches at startup.
    # This establishes only local-port enforcement, not arbitrary direct egress.
    pid = Process.spawn(env, ClaudeGuard::SBOX, '-p', profile, APP,
      "--proxy-server=#{address}", '--proxy-bypass-list=<-loopback>', '--disable-quic',
      in: File::NULL, out: File::NULL, err: File::NULL, close_others: true)
    waiter = Process.detach(pid)
    deadline = now + 15
    until now >= deadline
      inventory
      drain
      inspect_connections(port) unless @streams.empty?
      raise '测试期间统一代理不可用，结束测试并保留断网保护' unless @check.control('status')['ok']
      sleep 0.25
    end
    if !waiter.alive? && !waiter.value.success?
      state = waiter.value
      report("Claude #{host == '::1' ? 'IPv6' : 'IPv4'} 测试启动", '未验证',
        "主进程提前退出（退出码=#{state.exitstatus || '无'}，信号=#{state.termsig || '无'}），不能将没有流量算作拦截成功")
    end
  end
  def run
    preflight
    @server4 = TCPServer.new('127.0.0.1', 0)
    port = @server4.addr[1]
    @server6 = TCPServer.new('::1', port)
    profile = profile_for(port)
    drain
    @streams.each(&:close)
    @streams.clear
    @evidence = ClaudeLuLuEvidence.new(port, method(:resolve))
    start_log
    @was_running = !@scanner.processes.empty?
    @touched_claude = true
    cleanup_claude
    prepare_tests
    %w[127.0.0.1 ::1].each do |host|
      launch_test(profile, host, port)
      cleanup_claude
    end
    stop_log
    report('LuLu日志采集', '未验证', '日志读取或解析出现异常，本次证据可能不完整') if @log_failed
    targets.each do |path|
      label = File.basename(path)
      %w[IPv4 IPv6].each do |family|
        key = [path, family]
        if @evidence.allowed[key]
          report("#{label} #{family} 本机越权连接", '失败', '实际进程获准连接或建立了非17893测试端口连接；测试端口未转发任何流量')
        elsif @evidence.blocked[key] && !@log_failed && block_has_control?(key)
          report("#{label} #{family} 本机越权连接", '通过', '同一LuLu日志线程中关联到测试端口、当前PID身份、阻止规则及最终block判决')
        elsif @evidence.blocked[key] && !block_has_control?(key)
          report("#{label} #{family} 本机越权连接", '未验证', '取得本机目标拒绝证据，但缺少该可执行文件对允许端口的有效正对照')
        else
          report("#{label} #{family} 本机越权连接", '未验证', @observed[path] ? '程序已运行，但没有取得该程序完整的目标端口拒绝证据' : '该程序本次未运行，不能计为通过')
        end
      end
    end
    report('公网、UDP及所有入口覆盖', '未验证', '本测试验证真实程序对本机非授权端口的连接，不能外推为全部公网协议与入口均已验收')
    report('独立Claude Code', '未验证', '此前仅发现包装启动器；本次不把桌面Helper结果当作独立CLI结果')
  ensure
    stop_log
    if @touched_claude
      begin
        cleanup_claude
        if @was_running
          response = @check.control('launch')
          report('本机拦截测试后恢复Claude', response['ok'] ? '通过' : '失败', '通过原固定代理启动器重新打开应用；不恢复已终止任务内存')
          raise '测试结束后Claude恢复失败' unless response['ok']
        end
      rescue StandardError
        report('本机拦截测试后恢复Claude', '失败', '清理或重新启动未完成；未取消原断网保护')
        raise
      ensure
        @streams.each { |io| io.close rescue nil }
        [@server4, @server6].compact.each { |io| io.close rescue nil }
      end
    else
      @streams.each { |io| io.close rescue nil }
      [@server4, @server6].compact.each { |io| io.close rescue nil }
    end
  end
end
