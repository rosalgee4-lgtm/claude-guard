# encoding: UTF-8
require 'socket'
require 'json'
require 'timeout'
require 'uri'
require 'base64'
require 'open3'
require 'fileutils'

# The Mihomo engine runs in a thread of this process.
require_relative 'claude-embedded-engine'

class ClaudeDesktopService
  PORT = 17893
  STATE = File.join(Dir.home, '.claude-unified')
  SOCKET = File.join(STATE, 'control.sock')
  APP = '/Applications/Claude.app/Contents/MacOS/Claude'

  def initialize
    @guard = EmbeddedClaudeGuard.new
    @mutex = Mutex.new
    @launch_mutex = Mutex.new
    @streams = {}
    @tracked = {}
    @expires = 0
    @proxy = nil
    @reason = '正在检查代理'
  end

  def now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def processes
    output, _, status = Open3.capture3('/bin/ps', '-axww', '-o', 'uid=', '-o', 'pid=', '-o', 'ppid=', '-o', 'comm=')
    raise '无法读取进程列表' unless status.success?
    rows = output.lines.map do |line|
      match = line.match(/^\s*(\d+)\s+(\d+)\s+(\d+)\s+(.+?)\s*$/)
      next unless match && match[1].to_i == Process.uid
      [match[2].to_i, match[3].to_i, match[4]]
    end.compact
    selected = {}
    rows.each do |pid, _, executable|
      stamp = @tracked[pid]
      related = executable.include?('/Claude.app/Contents/') || File.basename(executable) == 'claude'
      if related || (stamp && @guard.identity(pid) == stamp)
        identity = @guard.identity(pid)
        selected[pid] = identity if identity
      end
    end
    loop do
      count = selected.size
      rows.each do |pid, parent, _|
        next unless selected.key?(parent) && !selected.key?(pid)
        identity = @guard.identity(pid)
        selected[pid] = identity if identity
      end
      break if selected.size == count
    end
    @tracked = selected
  end

  def close_gate(reason)
    sockets = @mutex.synchronize do
      @expires = 0
      @proxy = nil
      @reason = reason
      current = @streams.keys
      @streams.clear
      current
    end
    sockets.each { |socket| @guard.shutdown(socket) }
    @guard.terminate(processes)
  end

  def monitor
    loop do
      begin
        current = processes
        result = @guard.record('launch', Process.pid)
        raise(result['error'] || '原监控不可用') unless result['ok']
        proxy = URI.parse(result.fetch('proxy'))
        unless proxy.scheme == 'http' && proxy.host == '127.0.0.1' && proxy.user && proxy.password
          raise '原监控返回的代理地址无效'
        end
        current.each_key do |pid|
          registered = @guard.record('launch', pid)
          raise '进程登记期间代理失效' unless registered['ok']
        end
        @mutex.synchronize do
          @proxy = proxy
          @expires = now + 3
          @reason = nil
        end
      rescue StandardError
        close_gate('代理不可用，Claude 连接已关闭')
      end
      sleep 0.5
    end
  end

  def proxy
    @mutex.synchronize { @proxy if @expires > now }
  end

  def bridge(client)
    remote = nil
    reverse = nil
    upstream = proxy
    return unless upstream
    first = Timeout.timeout(3) { @guard.read_header(client) }&.lines&.first
    match = first&.match(/\ACONNECT ([A-Za-z0-9.-]+:[0-9]{1,5}|\[[0-9a-fA-F:]+\]:[0-9]{1,5}) HTTP\/1\.[01]\r\n\z/)
    return unless match
    remote = Socket.tcp('127.0.0.1', upstream.port, connect_timeout: 2)
    accepted = @mutex.synchronize do
      if @expires > now && @proxy == upstream
        @streams[client] = true
        @streams[remote] = true
        true
      end
    end
    return unless accepted
    auth = Base64.strict_encode64("#{upstream.user}:#{upstream.password}")
    remote.write("CONNECT #{match[1]} HTTP/1.1\r\nHost: #{match[1]}\r\nProxy-Authorization: Basic #{auth}\r\n\r\n")
    reply = Timeout.timeout(10) { @guard.read_header(remote) }
    return unless reply&.match?(/\AHTTP\/1\.[01] 200 /) && proxy
    client.write(reply)
    reverse = Thread.new do
      begin
        IO.copy_stream(remote, client)
      rescue IOError, SystemCallError
        nil
      ensure
        @guard.shutdown(client)
      end
    end
    IO.copy_stream(client, remote)
  rescue IOError, SystemCallError, Timeout::Error
    nil
  ensure
    @mutex.synchronize { @streams.delete(client); @streams.delete(remote) }
    @guard.shutdown(client)
    @guard.shutdown(remote)
    reverse&.join(1)
  end

  def launch
    raise '代理未就绪' unless proxy
    raise 'Claude 已运行，请先完全退出再从菜单启动' unless processes.empty?
    address = "http://127.0.0.1:#{PORT}"
    profile = @guard.verify_socket_limits(PORT)
    raise '专用代理预检失败' unless @guard.proxy_status(address, [ClaudeGuard::SBOX, '-p', profile]) == '401'
    raise '预检期间代理失效' unless proxy
    env = ClaudeGuard::PROXY_KEYS.each_with_object({}) { |key, result| result[key] = address }
    env.merge!('NO_PROXY' => '', 'no_proxy' => '')
    pid = Process.spawn(env, ClaudeGuard::SBOX, '-p', profile, APP,
                        "--proxy-server=#{address}", '--proxy-bypass-list=<-loopback>', '--disable-quic',
                        in: File::NULL, out: File::NULL, err: File::NULL, close_others: true)
    Process.detach(pid)
    registered = @guard.record('launch', pid)
    unless registered['ok']
      @guard.terminate({pid => @guard.identity(pid)})
      raise '启动期间代理失效'
    end
    'Claude 桌面版已启动'
  end

  def serve
    lock = File.open(File.join(STATE, 'service.lock'), File::RDWR | File::CREAT, 0600)
    raise '服务已经运行' unless lock.flock(File::LOCK_EX | File::LOCK_NB)
    listener = TCPServer.new('127.0.0.1', PORT)
    File.unlink(SOCKET) if File.socket?(SOCKET)
    control = UNIXServer.new(SOCKET)
    started = true
    File.chmod(0600, SOCKET)
    stopped = false
    %w[TERM INT HUP].each { |signal| trap(signal) { stopped = true } }
    engine = Thread.new { @guard.serve }
    Timeout.timeout(5) do
      until @guard.ready
        raise 'Mihomo 引擎初始化失败' unless engine.alive?
        sleep 0.05
      end
    end
    worker = Thread.new { monitor }
    slots = SizedQueue.new(64)
    until stopped
      raise 'Mihomo 引擎停止' unless engine.alive?
      raise '健康监控线程停止' unless worker.alive?
      close_gate('健康检查超时') if @mutex.synchronize { @proxy && @expires <= now }
      ready = IO.select([listener, control], nil, nil, 0.25)
      next unless ready
      ready[0].each do |server|
        client = server.accept
        if server == control
          Thread.new(client) do |connection|
            begin
              request = Timeout.timeout(2) { connection.gets(64) }.to_s.strip
              message = request == 'launch' ? @launch_mutex.synchronize { launch } : (@reason || 'UP：专用代理就绪；全入口拦截依赖 LuLu 规则')
              connection.puts(JSON.generate('ok' => !proxy.nil?, 'message' => message))
            rescue StandardError => error
              connection.puts(JSON.generate('ok' => false, 'message' => error.is_a?(RuntimeError) ? error.message : '控制请求失败')) rescue nil
            ensure
              connection.close
            end
          end
        else
          begin
            slots.push(true, true)
          rescue ThreadError
            client.close
            next
          end
          Thread.new(client) do |connection|
            begin
              bridge(connection)
            ensure
              slots.pop
            end
          end
        end
      end
    end
  ensure
    worker&.kill
    worker&.join
    close_gate('监控退出') if started
    @guard.stop
    engine&.join(8)
    engine&.kill if engine&.alive?
    listener&.close
    control&.close
    lock&.close
  end

  def self.request(action)
    UNIXSocket.open(SOCKET) do |socket|
      socket.puts(action)
      result = JSON.parse(Timeout.timeout(15) { socket.gets }.to_s)
      puts result['message']
      exit(result['ok'] ? 0 : 1)
    end
  rescue StandardError
    warn '桌面监控未就绪'
    exit 1
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    if ARGV.first == 'serve'
      ClaudeDesktopService.new.serve
    else
      ClaudeDesktopService.request(ARGV.first || 'status')
    end
  rescue StandardError => error
    warn(error.is_a?(RuntimeError) ? error.message : "桌面服务失败（#{error.class}）")
    exit 1
  end
end
