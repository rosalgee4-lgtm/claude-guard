# encoding: UTF-8
require 'socket'
require 'json'
require 'timeout'
require 'open3'
require 'tempfile'
require 'time'
require File.join(Dir.home, '.claude-unified', 'service.rb')

class ClaudeSelfcheck
  STATE = File.join(Dir.home, '.claude-unified')
  APP = '/Applications/Claude.app/Contents/MacOS/Claude'
  FUSES = '/Applications/Claude.app/Contents/Frameworks/Electron Framework.framework/Electron Framework'
  SENTINEL = 'dL7pKGdnNz796PbbjQWNKmHXBZaB9tsX'.b

  def initialize
    @guard = ClaudeGuard.new
    @scanner = ClaudeDesktopService.new
    @results = {}
  end

  def report(name, state, detail)
    @results[name] = {'state' => state, 'detail' => detail}
    puts "[#{state}] #{name}：#{detail}"
    $stdout.flush
  end

  def control(action)
    UNIXSocket.open(File.join(STATE, 'control.sock')) do |socket|
      socket.puts(action)
      JSON.parse(Timeout.timeout(15) { socket.gets }.to_s)
    end
  end

  def node_probe_supported?
    states = []
    carry = ''.b
    File.open(FUSES, 'rb') do |file|
      while (chunk = file.read(4 * 1024 * 1024))
        data = carry + chunk
        offset = 0
        while (index = data.index(SENTINEL, offset))
          wire = index + SENTINEL.bytesize
          if wire + 2 < data.bytesize
            states << (data.getbyte(wire) == 1 && data.getbyte(wire + 1).positive? && data.getbyte(wire + 2) == 0x31)
          end
          offset = index + SENTINEL.bytesize
        end
        carry = data.byteslice(-64, 64) || data
      end
    end
    !states.empty? && states.all?
  rescue SystemCallError
    false
  end

  def probe(host, port)
    script = <<~JS
      const net = require('net');
      const socket = net.connect({host: #{JSON.generate(host)}, port: #{port}});
      function finish(value) { console.log('CLAUDE_PROBE ' + value); socket.destroy(); process.exit(0); }
      socket.once('connect', () => finish('CONNECTED'));
      socket.once('error', error => finish(error.code || 'ERROR'));
      setTimeout(() => finish('TIMEOUT'), 3000);
    JS
    env = {'ELECTRON_RUN_AS_NODE' => '1', 'NODE_OPTIONS' => nil, 'NODE_PATH' => nil}
    ClaudeGuard::PROXY_KEYS.each { |key| env[key] = nil }
    Open3.popen3(env, APP, '-e', script, pgroup: true) do |input, output, errors, waiter|
      input.close
      error_reader = Thread.new { errors.read }
      begin
        text = Timeout.timeout(6) { output.read }
        Timeout.timeout(2) { waiter.value }
        text.lines.map { |line| line[/\ACLAUDE_PROBE ([A-Z_]+)\s*\z/, 1] }.compact.last
      ensure
        if waiter.alive?
          Process.kill('KILL', -waiter.pid) rescue nil
          waiter.join(2)
        end
        errors.close rescue nil
        error_reader.join(1)
      end
    end
  rescue StandardError
    nil
  end

  def direct_test
    unless node_probe_supported?
      report('Claude 直连拦截', '未验证', '该桌面版本未启用安全的同身份 Node 探针，跳过自动直连测试')
      return
    end
    unless probe('127.0.0.1', 17893) == 'CONNECTED'
      report('Claude 直连拦截', '未验证', '同身份探针无法连接允许的代理端口，缺少有效对照')
      return
    end
    server = TCPServer.new('127.0.0.1', 0)
    result = probe('127.0.0.1', server.addr[1])
    if result == 'CONNECTED'
      report('非授权本机端口', '失败', 'Claude 能连接规则允许范围之外的端口')
    elsif %w[EACCES EPERM].include?(result)
      report('非授权本机端口', '通过', '同一 Claude 可执行文件收到明确的系统拒绝')
    else
      report('非授权本机端口', '未验证', '未取得明确的系统拒绝错误')
    end
    ['1.1.1.1', '2606:4700:4700::1111'].each do |host|
      label = host.include?(':') ? 'IPv6 直连' : 'IPv4 直连'
      begin
        Socket.tcp(host, 443, connect_timeout: 3) { |socket| socket.close }
      rescue SystemCallError, IOError
        report(label, '未验证', '对照连接不可达，不能把网络不通当作防火墙生效')
        next
      end
      result = probe(host, 443)
      if result == 'CONNECTED'
        report(label, '失败', 'Claude 原始 TCP 连接成功，未被按应用规则阻止')
      elsif %w[EACCES EPERM].include?(result)
        report(label, '通过', 'Claude 原始 TCP 连接收到明确系统拒绝')
      else
        report(label, '未验证', '超时或探针异常，不能确定阻止原因')
      end
    end
    report('LuLu 归因及 Helper 覆盖', '未验证', '上述探针只验证主程序的系统拦截，未自动关联 LuLu 日志或逐个验证 Helper')
  ensure
    server&.close
  end

  def tunnel
    socket = Socket.tcp('127.0.0.1', 17893, connect_timeout: 3)
    socket.write("CONNECT api.anthropic.com:443 HTTP/1.1\r\nHost: api.anthropic.com:443\r\n\r\n")
    header = Timeout.timeout(12) { @guard.read_header(socket) }
    raise '专用隧道建立失败' unless header&.start_with?('HTTP/1.1 200 ')
    raise '隧道在测试前已结束' if IO.select([socket], nil, nil, 0.3)
    socket
  rescue Exception
    socket&.close
    raise
  end

  def disconnected?(socket)
    return false unless IO.select([socket], nil, nil, 0)
    value = socket.recv_nonblock(1, Socket::MSG_PEEK, exception: false)
    value.nil? || value == ''
  rescue IOError, SystemCallError
    true
  end

  def outage_test
    initial = @scanner.processes
    @was_running = !initial.empty?
    unless @was_running
      response = control('launch')
      raise(response['message'] || '无法启动测试会话') unless response['ok']
      @launched = true
      sleep 2
    end
    baseline = @scanner.processes
    raise '未找到实际 Claude 进程，不能验证进程清理' if baseline.empty?
    stream = tunnel
    before = control('diagnostics').fetch('diagnostics')
    raise '测试前代理未就绪' unless before['proxy_ready']
    route = @guard.running_route
    raise '专用组名称不匹配' unless ClaudeGuard::GROUP == 'ClaudeGuard-Local'
    @route = route
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    observed_closed = false
    observed_cleanup = false
    closed_counter = before.fetch('engine').fetch('tunnels_closed')
    loop do
      raise '无法设置专用组故障' unless @guard.set_selector(route[0], 'REJECT')
      @changed = true
      @scanner.processes
      snapshot = control('diagnostics').fetch('diagnostics')
      observed_closed ||= disconnected?(stream) && snapshot['engine']['tunnels_closed'] > closed_counter && snapshot['pid'] == before['pid']
      observed_cleanup ||= baseline.all? { |pid, stamp| @guard.identity(pid) != stamp } && @scanner.processes.empty?
      break if observed_closed && observed_cleanup
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) - started >= 35
      sleep 0.2
    end
    report('故障断开已有连接', observed_closed ? '通过' : '失败', '以测试隧道关闭和同一服务的断流计数作为证据')
    report('故障清理 Claude 进程', observed_cleanup ? '未验证' : '失败', '已核对 PID 身份和当前进程；进程消失不能区分监控清理与应用自行退出，尚缺少终止归因证据')
    report('全部关联进程覆盖', '未验证', '采样前脱离父子关系的通用解释器和系统服务仍不在完整证明范围内')
  ensure
    stream&.close
    restore
  end

  def restore
    return unless @route
    route = @guard.running_route
    raise '专用代理组恢复失败' unless @guard.set_selector(route[0], route[1].last)
    @changed = false
    ready = false
    80.times do
      if control('status')['ok']
        ready = true
        break
      end
      sleep 0.25
    end
    report('代理恢复', ready ? '通过' : '失败', ready ? '专用入口重新就绪' : '已请求恢复，监控尚未恢复就绪')
    if @was_running && ready && @scanner.processes.empty?
      result = control('launch')
      report('重新打开 Claude', result['ok'] ? '通过' : '失败', '重新打开应用，无法恢复被终止任务的内存状态')
    elsif @launched
      @guard.terminate(@scanner.processes)
    end
    @route = nil
  rescue StandardError
    report('代理恢复', '失败', '恢复未完成；统一监控仍会尝试跟随当前全局节点')
  end

  def run
    lock = File.open(File.join(STATE, 'selfcheck.lock'), File::RDWR | File::CREAT, 0600)
    held = lock.flock(File::LOCK_EX | File::LOCK_NB)
    raise '自检已经运行' unless held
    puts '自检会中断 Claude 会话，并仅对 ClaudeGuard-Local 专用组注入故障。'
    %w[INT TERM HUP].each { |signal| trap(signal) { raise Interrupt } }
    raise '统一代理尚未就绪' unless control('status')['ok']
    raise '自检支持未安装' unless control('diagnostics')['diagnostics'].is_a?(Hash)
    direct_test
    outage_test
  rescue Interrupt
    report('自检', '未完成', '收到中断，正在恢复专用组')
  rescue StandardError => error
    report('自检', '未完成', error.is_a?(RuntimeError) ? error.message : "检查异常（#{error.class}）")
  ensure
    restore if @route
    if @launched && !@was_running
      @guard.terminate(@scanner.processes) rescue nil
    end
    if held && !@results.empty?
      Tempfile.create('.selfcheck-report-', STATE) do |file|
        file.binmode
        file.write(JSON.pretty_generate('time' => Time.now.utc.iso8601, 'results' => @results))
        file.flush
        File.chmod(0600, file.path)
        File.rename(file.path, File.join(STATE, 'selfcheck-last.json'))
      end
      puts '结果已保存到 ~/.claude-unified/selfcheck-last.json。未验证项目不能计为通过。'
      puts 'LuLu 仍需在其规则/拦截记录中核对 Claude 及 Helper；本自检不会改动 LuLu 设置。'
    end
    lock&.close
  end
end

if $PROGRAM_NAME == __FILE__
  check = ClaudeSelfcheck.new
  check.run
  states = check.instance_variable_get(:@results).values.map { |entry| entry['state'] }
  exit(states.include?('失败') || states.include?('未完成') ? 1 : (states.any? { |state| state != '通过' } ? 2 : 0))
end
