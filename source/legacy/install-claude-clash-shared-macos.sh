#!/bin/bash
set -euo pipefail
umask 077
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
state="$HOME/.claude-clash-guard"

case "${1:-install}" in
install)
    [[ "$(uname -s)" == Darwin && "$UID" -ne 0 ]] || { echo '请在 Mac mini 桌面账号下运行。' >&2; exit 1; }
    raw=$(type -P claude || true)
    [[ "$raw" != "$state/bin/claude" ]] || raw=''
    /usr/bin/env -u RUBYOPT -u RUBYLIB /usr/bin/ruby -EUTF-8:UTF-8 - "${BASH_SOURCE[0]}" "$raw" "${ZDOTDIR:-$HOME}" <<'CLAUDE_GUARD_RUBY'
# encoding: UTF-8
require 'digest'
require 'base64'
require 'fileutils'
require 'json'
require 'open3'
require 'securerandom'
require 'socket'
require 'tempfile'
require 'time'
require 'timeout'

class ClaudeGuard
  JOB = 'local.claude-clash-guard'.freeze
  SBOX = '/usr/bin/sandbox-exec'.freeze
  CURL = '/usr/bin/curl'.freeze
  RUBY = '/usr/bin/ruby'.freeze
  APP = 'io.github.clash-verge-rev.clash-verge-rev'.freeze
  GROUP = 'ClaudeGuard-Local'.freeze
  INBOUND = 'claude-guard-local'.freeze
  MARKER = '/* BEGIN Claude Guard managed listener */'.freeze
  URL = 'https://api.anthropic.com/v1/models'.freeze
  TYPES = /\A(?:ssr?|shadowsocksr?|socks5|http|snell|vmess|vless|trojan|wireguard|hysteria2?|tuic|ssh|mieru|anytls|masque|trusttunnel)\z/i
  PROXY_KEYS = %w[http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY].freeze
  SHELL_MARKER = '# BEGIN Claude Clash Guard'.freeze
  SHELL_BLOCK = "\n#{SHELL_MARKER}\nexport PATH=\"$HOME/.claude-clash-guard/bin:$PATH\"\nunalias claude 2>/dev/null || :\nunset -f claude 2>/dev/null || :\n# END Claude Clash Guard\n".freeze

  def initialize
    @home = Dir.home
    @state = File.join(@home, '.claude-clash-guard')
    @app = File.join(@home, 'Library/Application Support', APP)
    @job = "gui/#{Process.uid}/#{JOB}"
    @plist = File.join(@home, 'Library/LaunchAgents', JOB + '.plist')
    @control = File.join(@state, 'guard.sock')
    @sessions = {}
    @tunnels = {}
    @selector = nil
    @route = nil
    @error = '正在运行沙箱出站自检'
    @mutex = Mutex.new
  end

  def file(name)
    File.join(@state, name)
  end

  def command(*args)
    Open3.capture3(*args)
  end

  def curl(*args, data: '')
    out, _, status = Open3.capture3(CURL, '-q', '-s', '--connect-timeout', '1', '--max-time', '3',
                                   *args, stdin_data: data)
    out if status.success?
  end

  def probe(proxy)
    proxy_status(proxy) == '401'
  end

  def proxy_status(proxy, prefix = [])
    # Feed the ephemeral proxy URL on stdin, so it is absent from argv.
    out, _, status = Open3.capture3(*prefix, CURL, '-q', '--config', '-', '-s', '--noproxy', '',
                                   '--connect-timeout', '4', '--max-time', '7',
                                   '-o', '/dev/null', '-w', '%{http_code}', URL,
                                   stdin_data: "proxy = #{JSON.generate(proxy)}\n")
    out if status.success?
  end

  def controller(path, resource)
    raw = curl('--unix-socket', path, '--noproxy', '*', '--fail', 'http://localhost' + resource)
    parsed = JSON.parse(raw) if raw
    parsed if parsed.is_a?(Hash)
  rescue JSON::ParserError
    nil
  end

  def selected(proxies, providers = {})
    seen = []
    name = 'GLOBAL'
    until seen.include?(name) || seen.length >= 16
      entry = proxies[name] || providers[name]
      return unless entry.is_a?(Hash)
      seen << name
      type = entry['type'].to_s.delete('-_')
      if %w[selector urltest fallback].include?(type.downcase)
        picked = entry['now']
        return unless picked.is_a?(String) && Array(entry['all']).include?(picked)
        name = picked
      else
        return [seen, type.downcase, entry['provider-name'].to_s] if seen.length > 1 && TYPES.match?(type) && !entry.key?('all')
        return
      end
    end
    nil
  end

  def socket_paths
    tmp, _, status = command('/usr/bin/getconf', 'DARWIN_USER_TEMP_DIR')
    paths = ["/var/run/clash-verge-service/users/#{Process.uid}/verge-mihomo.sock", '/tmp/verge/verge-mihomo.sock']
    paths << File.join(tmp.strip, 'verge-mihomo.sock') if status.success? && tmp.strip.start_with?('/')
    paths
  end

  def running_route
    running = system('/usr/bin/pgrep', '-u', Process.uid.to_s, '-x', 'clash-verge', out: File::NULL, err: File::NULL)
    raise 'Clash Verge Rev 未运行' unless running
    @sockets ||= socket_paths
    @sockets.each do |path|
      next unless File.socket?(path) && [0, Process.uid].include?(File.stat(path).uid)
      config = controller(path, '/configs')
      next unless config
      raise '请打开 Clash 全局模式和 TUN' unless config['mode'].to_s.downcase == 'global' && config.dig('tun', 'enable') == true
      proxies = controller(path, '/proxies')&.fetch('proxies', nil)
      raise '无法读取 Mihomo 的全局代理组' unless proxies.is_a?(Hash)
      choice = selected(proxies)
      unless choice
        response = controller(path, '/providers/proxies')
        candidates = (response&.fetch('providers', {}) || {}).values.flat_map { |provider| Array(provider['proxies']) }
        candidates = candidates.select { |entry| entry.is_a?(Hash) && !entry['provider-name'].to_s.empty? }
        unique = candidates.group_by { |entry| entry['name'] }
        choice = selected(proxies, unique.select { |_, entries| entries.length == 1 }.transform_values(&:first))
      end
      raise '全局组选中了直连、拒绝或无法确定单一节点的策略' unless choice
      group = proxies[GROUP]
      raise '等待 Clash 下次正常加载专用入口' unless group.is_a?(Hash)
      names = Array(group['all'])
      unless group['type'].to_s.casecmp('Selector').zero? && group['emptyFallback'] == 'REJECT' &&
             names.first == 'REJECT' && names.include?(choice[0].last) &&
             (names.map { |name| name.to_s.upcase } & %w[DIRECT COMPATIBLE PASS PASS-RULE REJECT-DROP]).empty?
        raise 'Claude 专用代理组的配置未通过检查'
      end
      return [path, choice[0], group['now']]
    end
    raise '无法读取 Clash 的本机 Mihomo 接口'
  end

  def extension_path
    path = File.join(@app, 'profiles', 'Script.js')
    raise '找不到 Clash Verge Rev 的 profiles 目录' unless File.directory?(File.dirname(path))
    if File.symlink?(path) || (File.exist?(path) && !File.file?(path))
      raise 'Clash 全局扩展脚本 Script.js 路径异常'
    end
    path
  end

  def stage_extension
    path = extension_path
    existed = File.file?(path)
    before = existed ? File.binread(path).force_encoding('UTF-8') : ''
    raise '全局扩展脚本已含同名 Claude 配置' if before.include?(MARKER) || before.include?(GROUP) || before.include?(INBOUND)
    profile = JSON.parse(File.read(file('inbound.json')))
    port = profile.fetch('port')
    # Preserve the original top-level JavaScript and its main function.
    block = <<~JS

      #{MARKER}
      #{existed ? ';(function () { const original = typeof main === "function" ? main : null; main = function (config, profileName) {' :
                   'function main(config, profileName) {'}
          #{existed ? 'if (original) config = original(config, profileName) || config;' : ''}
          const proxyGroup = #{JSON.generate(GROUP)};
          const inbound = #{JSON.generate(INBOUND)};
          const port = #{port};
          const groups = config["proxy-groups"] || [];
          const listeners = config["listeners"] || [];
          const existing = listeners.find(listener => listener.name === inbound);
          if (existing && String(existing.port) === String(port) && existing.proxy === proxyGroup &&
              groups.some(group => group.name === proxyGroup)) return config;
          if (groups.some(group => group.name === proxyGroup) ||
              listeners.some(listener => listener.name === inbound || String(listener.port) === String(port))) {
            throw new Error("Claude Guard listener or group conflict");
          }
          const types = /^(ss|ssr|socks5|http|snell|vmess|vless|trojan|wireguard|hysteria2?|tuic|ssh|mieru|anytls|masque|trusttunnel)$/i;
          const nodes = (config.proxies || []).filter(node => types.test(node.type) && node.name !== "REJECT");
          config["proxy-groups"] = groups.concat([{
            name: proxyGroup,
            type: "select",
            hidden: true,
            proxies: ["REJECT"].concat(nodes.map(node => node.name)),
            use: Object.keys(config["proxy-providers"] || {}),
            "default-selected": "REJECT",
            "empty-fallback": "REJECT",
            "exclude-type": "Direct|Compatible|RejectDrop|Pass|PassRule|Dns|Rematch|Selector|URLTest|Fallback|LoadBalance|Relay|GostRelay|Unknown"
          }]);
          config.listeners = listeners.concat([{
            name: inbound, type: "http", listen: "127.0.0.1", port: port, proxy: proxyGroup,
            users: []
          }]);
          return config;
      #{existed ? '}; })();' : '}'}
      /* END Claude Guard managed listener */
    JS
    edited = before + block
    # Syntax-check the extension without evaluating it or touching Mihomo.
    validation = <<~JS
      ObjC.import("Foundation");
      function run(argv) {
        const text = $.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null);
        new Function(ObjC.unwrap(text));
      }
    JS
    atomic(file('extension-check.js'), edited)
    ok = system('/usr/bin/osascript', '-l', 'JavaScript', '-e', validation, file('extension-check.js'),
                out: File::NULL, err: File::NULL)
    raise 'Clash 全局脚本语法检查失败' unless ok
    atomic(file('extension.json'), JSON.generate('path'=>path, 'block'=>block, 'existed'=>existed))
    if existed
      raise 'Clash 全局脚本在安装期间有变动' unless !File.symlink?(path) && File.binread(path) == before.b
      atomic(path, edited, File.stat(path).mode & 0777)
    else
      File.link(file('extension-check.js'), path)
    end
  end

  def remove_extension
    return unless File.file?(file('extension.json'))
    data = JSON.parse(File.read(file('extension.json')))
    path, block, existed = data.values_at('path', 'block', 'existed')
    return unless File.exist?(path) || File.symlink?(path)
    raise 'Clash 全局脚本路径变了，已保留回滚记录' unless File.file?(path) && !File.symlink?(path)
    body = File.binread(path)
    unless body.include?(block.b)
      raise 'Claude 的 Clash 扩展块已被编辑，已保留回滚记录' if body.include?(MARKER)
      return
    end
    restored = body.sub(block.b, '')
    if !existed && restored.empty?
      File.rename(path, file('unused-extension.js'))
    else
      atomic(path, restored, File.stat(path).mode & 0777)
    end
  end

  def set_selector(path, name)
    curl('--unix-socket', path, '--noproxy', '*', '--fail', '-X', 'PUT',
         '-H', 'Content-Type: application/json', '--data-binary', '@-',
         'http://localhost/proxies/' + GROUP, data: JSON.generate('name'=>name))
  end

  def health_option(port)
    "http://claude:#{@relay_secret}@127.0.0.1:#{port}"
  end

  def open_tunnel(path, target, node)
    upstream = Socket.tcp('127.0.0.1', @inbound.fetch('port'), connect_timeout: 1)
    verified = false
    Timeout.timeout(3) do
      upstream.write("CONNECT #{target} HTTP/1.1\r\nHost: #{target}\r\n\r\n")
      response = read_header(upstream)
      raise '专用入口拒绝连接' unless response && response.match?(/\AHTTP\/1\.[01] 200 /)
    end
    connection = nil
    deadline = now + 2
    loop do
      listing = controller(path, '/connections')
      connection = Array(listing && listing['connections']).find do |entry|
        metadata = entry['metadata']
        metadata && metadata['sourceIP'] == '127.0.0.1' &&
          metadata['sourcePort'].to_i == upstream.local_address.ip_port &&
          metadata['inboundPort'].to_i == @inbound.fetch('port')
      end
      break if connection || now >= deadline
      sleep 0.08
    end
    if connection
      metadata = connection.fetch('metadata')
      chain = Array(connection['chains'])
      verified = metadata['inboundName'] == INBOUND && metadata['specialProxy'] == GROUP &&
                 chain.first == node && chain.include?(GROUP) && !chain.include?('DIRECT')
    end
    raise '无法在 Mihomo 中验证专用入口和出口' unless verified
    upstream
  ensure
    shutdown(upstream) unless verified
  end

  def relay(client)
    upstream = nil
    other = nil
    route = @mutex.synchronize do
      current = @route || @probe_route
      current if current && current[:expires] > now
    end
    return unless route && running_route == route[:path]
    target = Timeout.timeout(2) { connect_target(client) }
    return unless target
    return if route[:probe] && target != 'api.anthropic.com:443'
    path, _, node = route[:path]
    upstream = open_tunnel(path, target, node)
    tracked = @mutex.synchronize do
      current = @route || @probe_route
      if current && current[:path] == route[:path] && route[:expires] > now
        @tunnels[client] = upstream
        true
      end
    end
    return unless tracked
    client.write("HTTP/1.1 200 Connection established\r\n\r\n")
    other = Thread.new do
      IO.copy_stream(upstream, client)
    rescue IOError, SystemCallError
      nil
    ensure
      shutdown(client)
    end
    IO.copy_stream(client, upstream)
  rescue IOError, SystemCallError, RuntimeError, Timeout::Error
    nil
  ensure
    @mutex.synchronize { @tunnels.delete(client) }
    shutdown(upstream)
    shutdown(client)
    other&.join
  end

  def read_header(client)
    header = ''.b
    until header.end_with?("\r\n\r\n")
      char = client.read(1)
      return unless char && header.bytesize < 16_384
      header << char
    end
    header
  end

  def connect_target(client)
    header = read_header(client)
    return unless header
    target = header.lines.first[/\ACONNECT ([A-Za-z0-9.-]+:[0-9]{1,5}|\[[0-9A-Fa-f:]+\]:[0-9]{1,5}) HTTP\/1\.[01]\r\n\z/, 1]
    return unless target
    expected = 'Basic ' + Base64.strict_encode64('claude:' + @relay_secret)
    auth = header.lines.grep(/\AProxy-Authorization:/i)
    if auth.length == 1 && auth.first.split(':', 2).last.strip == expected
      target
    else
      client.write("HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"Claude Guard\"\r\nConnection: close\r\nContent-Length: 0\r\n\r\n")
      nil
    end
  end

  def shutdown(socket)
    return unless socket
    begin
      socket.shutdown(Socket::SHUT_RDWR)
    rescue IOError, SystemCallError
      nil
    ensure
      socket.close unless socket.closed?
    end
  rescue IOError, SystemCallError
    nil
  end

  def identity(pid)
    out, _, status = command('/bin/ps', '-ww', '-p', pid.to_s, '-o', 'uid=', '-o', 'lstart=')
    out.split.join(' ') if status.success? && out.split.first == Process.uid.to_s
  end

  def terminate(pids, tree: true)
    return if pids.empty?
    victims = pids.dup
    if tree
      rows, _, = command('/bin/ps', '-ax', '-o', 'uid=', '-o', 'pid=', '-o', 'ppid=')
      children = rows.lines.map { |row| row.split.map(&:to_i) }.select { |row| row.length == 3 && row[0] == Process.uid }.group_by(&:last)
      pending = pids.keys.select { |pid| identity(pid) == pids[pid] }
      until pending.empty?
        parent = pending.shift
        Array(children[parent]).each do |_, pid, _|
          next if victims.key?(pid)
          stamp = identity(pid)
          next unless stamp
          victims[pid] = stamp
          pending << pid
        end
      end
    end
    %w[TERM KILL].each do |signal|
      victims.each do |pid, expected|
        Process.kill(signal, pid) if identity(pid) == expected
      rescue Errno::ESRCH, Errno::EPERM
        next
      end
      sleep 0.3 if signal == 'TERM'
    end
  end

  def close_gate(reason)
    victims, streams = @mutex.synchronize do
      @route, @probe_route, @error = nil, nil, reason
      old, @sessions = @sessions, {}
      pipes, @tunnels = @tunnels, {}
      [old, pipes]
    end
    streams.each { |client, upstream| shutdown(client); shutdown(upstream) }
    terminate(victims)
  end

  def reject_selector
    if @selector
      socket, @selector = @selector, nil
      @selector = socket unless set_selector(socket, 'REJECT')
    end
  end

  def monitor
    loop do
      begin
        route = running_route
        path, chain, current = route
        node = chain.last
        prior = @mutex.synchronize { @route && @route[:path] }
        close_gate('全局节点正在切换') if prior && prior != route
        if current != node
          @selector = path
          raise '无法切换 Claude 专用代理组' unless set_selector(path, node)
        end
        @selector = path
        check = [path, chain, node]
        @mutex.synchronize { @probe_route = {path:check, expires:now + 7, probe:true} }
        raise '专用入站未运行、出口验证失败或当前节点无法连接 Anthropic' unless probe(health_option(@front_port))
        raise '全局节点或模式已变化' unless running_route == check
        @mutex.synchronize do
          @route = {path:check, expires:now + 12}
          @probe_route = nil
          @sessions.delete_if { |pid, stamp| identity(pid) != stamp }
          @error = nil
        end
      rescue StandardError => e
        close_gate(e.is_a?(RuntimeError) ? e.message : "节点检查失败（#{e.class}）")
        reject_selector
      end
      sleep 2
    end
  end

  def now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def atomic(path, bytes, mode = 0600)
    Tempfile.create('.claude-guard', File.dirname(path)) do |tmp|
      tmp.binmode
      tmp.write(bytes)
      tmp.chmod(mode)
      tmp.close
      File.rename(tmp.path, path)
    end
  end

  def record(*args)
    UNIXSocket.open(@control) do |socket|
      socket.puts(JSON.generate(args))
      line = Timeout.timeout(5) { socket.gets }
      JSON.parse(line.to_s)
    end
  rescue IOError, SystemCallError, JSON::ParserError, Timeout::Error
    {'ok'=>false, 'error'=>'Claude 监控尚未运行'}
  end

  def handle(socket)
    line = Timeout.timeout(0.3) { socket.gets(1024) }
    action, pid = JSON.parse(line.to_s)
    return {'ok'=>true} if action == 'installed'
    @mutex.synchronize do
      if @route && @route[:expires] > now
        if action == 'status'
          return {'ok'=>true}
        elsif action == 'launch' && pid.is_a?(Integer) && pid.positive? && (stamp = identity(pid))
          @sessions[pid] = stamp
          return {'ok'=>true, 'port'=>@front_port, 'proxy'=>health_option(@front_port)}
        end
      end
      {'ok'=>false, 'error'=>@error || '代理探测已超时'}
    end
  rescue Timeout::Error, JSON::ParserError, TypeError
    {'ok'=>false,'error'=>'无效启动请求'}
  end

  def prepare_monitor
    verify_socket_limits(@front_port)
    stage_extension unless File.file?(file('extension.json'))
    true
  rescue SandboxCheckError => e
    report_blocked(e.message)
  rescue StandardError => e
    begin
      remove_extension
    rescue StandardError
      warn '无法自动撤销 Clash 扩展，已保留回滚记录。'
    end
    report_blocked(e.is_a?(RuntimeError) ? e.message : "无法登记 Clash 扩展（#{e.class}）")
  end

  def monitor_after_activation
    sleep 0.1 until File.file?(file('installed'))
    monitor if prepare_monitor
  end

  def report_blocked(message)
    close_gate(message)
    warn message
    false
  end

  def serve
    @inbound = JSON.parse(File.read(file('inbound.json')))
    @relay_secret = SecureRandom.hex(24)
    File.rename(@control, @control + '.previous') if File.socket?(@control)
    control = UNIXServer.new(@control)
    File.chmod(0600, @control)
    relay_server = TCPServer.new('127.0.0.1', 0)
    @front_port = relay_server.addr[1]
    slots = SizedQueue.new(64)
    stopped = false
    %w[INT TERM].each { |sig| trap(sig) { stopped = true } }
    Thread.abort_on_exception = true
    monitor_thread = Thread.new { monitor_after_activation }
    until stopped
      expired = @mutex.synchronize { @route && @route[:expires] <= now }
      close_gate('代理探测已超时') if expired
      readable = IO.select([control, relay_server], nil, nil, 0.25)
      next unless readable
      readable[0].each do |server|
        client = server.accept
        if server == control
          begin
            client.puts(JSON.generate(handle(client)))
          rescue IOError, SystemCallError
            nil
          ensure
            client.close
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
              relay(connection)
            ensure
              slots.pop
            end
          end
        end
      end
    end
  ensure
    monitor_thread&.kill
    monitor_thread&.join
    close_gate('监控退出')
    reject_selector
    control&.close
    relay_server&.close
  end

  def seatbelt(port)
    <<~PROFILE
      (version 1)
      (allow default)
      (deny network*)
      (deny network-outbound)
      (deny mach-lookup (global-name "com.apple.nsurlsessiond") (global-name-prefix "com.apple.nsurlsessiond."))
      (allow network-outbound (remote tcp4 "localhost:#{port}"))
    PROFILE
  end

  def socket_tests
    <<~'TEST'
      # encoding: UTF-8
      require 'socket'
      port, tcp4_port, tcp6_port, udp6_port = ARGV.map { |value| Integer(value) }
      failures = []
      denied = lambda do |label, &test|
        test.call
        failures << "#{label}：系统未返回沙箱拒绝"
      rescue Errno::EPERM, Errno::EACCES
        nil
      rescue SystemCallError => error
        failures << "#{label}：#{error.class}，无法验证沙箱拒绝"
      end
      tcp = lambda do |family, host, destination|
        Socket.open(family, Socket::SOCK_STREAM) do |socket|
          socket.connect_nonblock(Socket.sockaddr_in(destination, host), exception: false)
        end
      end
      denied.call('IPv4 TCP 公网直连') { tcp.call(Socket::AF_INET, '192.0.2.1', port) }
      denied.call('IPv4 TCP 其他本机端口') { tcp.call(Socket::AF_INET, '127.0.0.1', tcp4_port) }
      denied.call('IPv6 TCP 回环') { tcp.call(Socket::AF_INET6, '::1', tcp6_port) }
      denied.call('IPv6 TCP IPv4 映射地址') { tcp.call(Socket::AF_INET6, '::ffff:127.0.0.1', port) }
      denied.call('IPv6 TCP 公网直连') { tcp.call(Socket::AF_INET6, '2001:db8::1', port) }
      denied.call('IPv4 UDP 代理端口') { UDPSocket.open { |socket| socket.send('x', 0, '127.0.0.1', port) } }
      denied.call('IPv4 UDP 直发') { UDPSocket.open { |socket| socket.send('x', 0, '192.0.2.53', 53) } }
      denied.call('IPv4 UDP connect') { UDPSocket.open { |socket| socket.connect('192.0.2.53', 53) } }
      denied.call('IPv6 UDP 发包') { UDPSocket.open(Socket::AF_INET6) { |socket| socket.send('x', 0, '::1', udp6_port) } }
      denied.call('IPv6 UDP connect') { UDPSocket.open(Socket::AF_INET6) { |socket| socket.connect('::1', udp6_port) } }
      denied.call('IPv6 UDP 公网直发') { UDPSocket.open(Socket::AF_INET6) { |socket| socket.send('x', 0, '2001:db8::53', 53) } }
      unless failures.empty?
        warn failures.join('；')
        exit 1
      end
    TEST
  end

  class SandboxCheckError < RuntimeError; end

  def verify_socket_limits(port)
    raise SandboxCheckError, '代理端口无效' unless port.is_a?(Integer) && port.between?(1, 65_535)
    profile = seatbelt(port)
    tcp4 = TCPServer.new('127.0.0.1', 0)
    tcp6 = TCPServer.new('::1', 0)
    udp6 = UDPSocket.new(Socket::AF_INET6)
    udp6.bind('::1', 0)
    _, errors, status = command(SBOX, '-p', profile, RUBY, '-e', socket_tests,
                                port.to_s, tcp4.addr[1].to_s, tcp6.addr[1].to_s, udp6.addr[1].to_s)
    unless status.success?
      details = errors.lines.map(&:strip).reject(&:empty?).join('；')
      details = "退出码 #{status.exitstatus}" if details.empty?
      raise SandboxCheckError, "沙箱自检失败：#{details}"
    end
    profile
  rescue SystemCallError => e
    raise SandboxCheckError, "无法运行沙箱自检（#{e.class}）"
  ensure
    [tcp4, tcp6, udp6].compact.each(&:close)
  end

  def verify_sandbox(upstream)
    port, proxy = upstream.values_at('port', 'proxy')
    raise '代理响应无效' unless proxy.is_a?(String)
    profile = verify_socket_limits(port)
    raise '沙箱内的 Claude 专用代理未通过连接测试' unless proxy_status(proxy, [SBOX, '-p', profile]) == '401'
    profile
  end

  def find_claude(pinned = nil, command = 'claude')
    search = ENV.fetch('PATH', '').split(':').select { |directory| directory.start_with?('/') }
    if command == 'claude'
      search.concat([File.join(@home, '.local/bin'), '/opt/homebrew/bin', '/usr/local/bin'])
    end
    candidates = command.start_with?('/') ? [command] : [pinned, *search.map { |directory| File.join(directory, command) }]
    candidates.compact.find do |path|
      path.start_with?('/') && File.file?(path) && File.executable?(path) &&
        %w[claude claude-ide].none? { |name| File.identical?(path, file("bin/#{name}")) }
    end
  end

  def installed_claude
    pinned = File.read(file('claude.path')).strip if File.file?(file('claude.path'))
    find_claude(pinned)
  end

  def launch(args)
    wrapper = args.first == '--ide'
    args.shift if wrapper
    if wrapper
      command = args.shift
      executable = find_claude(nil, command) if command && !command.empty?
      raise '找不到 IDE 指定的 Claude Code，或它指向受保护启动器本身' unless executable
    else
      executable = installed_claude
      raise '未找到 Claude Code。安装后重新点击启动，或在终端输入 claude。' unless executable
    end
    upstream = record('launch', Process.pid)
    raise upstream['error'] unless upstream['ok']
    profile = verify_sandbox(upstream)
    PROXY_KEYS.each { |key| ENV[key] = upstream['proxy'] }
    ENV['NO_PROXY'] = ENV['no_proxy'] = ''
    exec SBOX, '-p', profile, executable, *args
  end

  def plist_quote(text)
    text.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
  end

  def launch_description
    args = [RUBY, '-EUTF-8:UTF-8', file('guard.rb'), 'serve']
    array = args.map { |a| "<string>#{plist_quote(a)}</string>" }.join
    <<~PLIST
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0"><dict>
      <key>Label</key><string>#{JOB}</string>
      <key>ProgramArguments</key><array>#{array}</array>
      <key>KeepAlive</key><true/>
      <key>StandardErrorPath</key><string>#{plist_quote(file('guard.log'))}</string>
      </dict></plist>
    PLIST
  end

  def shell_files(zdot)
    bash = %w[.bash_profile .bash_login .profile].map { |f| File.join(@home, f) }
    [File.join(zdot, '.zshrc'), File.join(zdot, '.zprofile'), File.join(@home, '.bashrc'),
     bash.find { |p| File.file?(p) } || bash.first].uniq
  end

  def install(source, raw, zdot)
    raise '请先撤销上一版的账号级 PF' if File.exist?(File.join(@home, '.claude-clash-pf')) ||
      %w[/Library/LaunchDaemons/local.claude-clash-pf.plist
         /private/var/db/local.claude-clash-pf /private/var/db/claude-taiwan-pf].any? { |path| File.exist?(path) }
    raise '已有安装或回滚未完成' if File.exist?(@state) || File.symlink?(@state) || File.exist?(@plist) || File.symlink?(@plist)
    raise '系统缺少 sandbox-exec' unless File.executable?(SBOX)
    paths = shell_files(zdot)
    raise 'Shell 配置路径无效或为符号链接' unless paths.all? { |path| File.dirname(path).start_with?('/') &&
      File.directory?(File.dirname(path)) && !File.symlink?(path) && (!File.exist?(path) || File.file?(path)) }
    raw = find_claude(raw)
    Dir.mkdir(@state, 0700)
    committed = false
    begin
      %w[HUP INT TERM].each { |sig| trap(sig) { raise Interrupt, '安装中断' } }
      atomic(file('guard.rb'), File.read(source))
      atomic(file('claude.path'), raw + "\n") if raw
      Dir.mkdir(file('bin'), 0700)
      {'claude'=>'launch','claude-ide'=>'launch --ide'}.each do |name, args|
        atomic(file("bin/#{name}"), "#!/bin/bash\nexec /usr/bin/env -u RUBYOPT -u RUBYLIB /usr/bin/ruby -EUTF-8:UTF-8 \"$HOME/.claude-clash-guard/guard.rb\" #{args} \"$@\"\n", 0700)
      end
      records = paths.map do |path|
        existing = File.file?(path)
        old = existing ? File.binread(path) : ''
        raise 'Shell 已有 Claude 启动配置' if old.include?(SHELL_MARKER)
        [path, existing, existing ? (File.stat(path).mode & 0777) : 0600, Digest::SHA256.hexdigest(old)]
      end
      atomic(file('shell.json'), JSON.generate(records))
      port = TCPServer.open('127.0.0.1', 0) { |socket| socket.addr[1] }
      atomic(file('inbound.json'), JSON.generate('port'=>port))
      FileUtils.mkdir_p(File.dirname(@plist))
      atomic(file('launch.plist'), launch_description)
      system('/usr/bin/plutil', '-lint', file('launch.plist'), out: File::NULL) || raise('launchd 配置检查失败')
      File.link(file('launch.plist'), @plist)
      system('/bin/launchctl', 'bootstrap', "gui/#{Process.uid}", @plist) || raise('无法启动 Claude 监控')
      response = nil
      20.times do
        sleep 0.5
        response = record('installed')
        break if response['ok']
      end
      raise response['error'] unless response['ok']
      records.each do |path, _, mode, checksum|
        current = File.file?(path) ? File.binread(path) : ''
        raise 'Shell 配置在安装期间已变更' unless Digest::SHA256.hexdigest(current) == checksum && !File.symlink?(path)
        atomic(path, current + SHELL_BLOCK, mode)
      end
      raise 'Claude 监控在安装期间退出' unless record('installed')['ok']
      atomic(file('installed'), '')
      puts '监控已安装。菜单会显示沙箱自检结果和代理状态。'
      puts '尚未找到 Claude Code，安装 Claude Code 后可直接通过菜单启动。' unless raw
      puts "IDE 启动器：#{file('bin/claude-ide')}"
      puts "回滚：/usr/bin/ruby -EUTF-8:UTF-8 \"#{file('guard.rb')}\" rollback"
      committed = true
    ensure
      unless committed
        %w[HUP INT TERM].each { |sig| trap(sig, 'IGNORE') }
        warn '安装未完成，正在撤销启动器和后台监控。'
        rollback
      end
    end
  end

  def rollback
    owned_plist = File.identical?(@plist, file('launch.plist'))
    if owned_plist && system('/bin/launchctl', 'print', @job, out: File::NULL, err: File::NULL)
      stopped = system('/bin/launchctl', 'bootout', @job, out: File::NULL, err: File::NULL)
      raise '无法停止 Claude 监控，已保留回滚记录' unless stopped
    end
    remove_extension
    archive = Dir.mktmpdir(".claude-clash-guard.rollback.#{Time.now.strftime('%Y%m%d-%H%M%S')}.", File.dirname(@state))
    if File.file?(file('shell.json'))
      JSON.parse(File.read(file('shell.json'))).each do |path, existing, mode, _|
        next unless File.file?(path) && !File.symlink?(path)
        body = File.binread(path)
        next unless body.include?(SHELL_BLOCK)
        restored = body.sub(SHELL_BLOCK, '')
        if !existing && restored.empty?
          File.rename(path, file("unused-shell-#{File.basename(path)}"))
        else
          atomic(path, restored, mode)
        end
      end
    end
    if owned_plist
      File.rename(@plist, file('unloaded.plist'))
    end
    File.rename(@state, File.join(archive, 'installation')) if File.directory?(@state)
  end

  def main(args)
    case args.shift
    when 'serve' then serve
    when 'launch' then launch(args)
    when 'install' then install(*args)
    when 'rollback' then rollback; puts 'Claude 启动器和监控已撤销。重新打开终端。'
    when 'status'
      state = record('status')
      raise state['error'] unless state['ok']
      desktop = ['/Applications/Claude.app', File.join(@home, 'Applications/Claude.app')].any? do |bundle|
        File.executable?(File.join(bundle, 'Contents/MacOS/Claude'))
      end
      if desktop && !installed_claude
        raise '代理可达；已找到 Claude 桌面版，桌面全局保护尚未配置完成'
      end
      puts 'UP：当前全局节点经 Claude 专用代理可达'
      puts '尚未找到 Claude Code' unless installed_claude
    else
      raise '请选择 install、status 或 rollback'
    end
  end
end

if $PROGRAM_NAME == __FILE__ || $PROGRAM_NAME == '-'
  begin
    if $PROGRAM_NAME == '-'
      source, raw, zdot = ARGV
      script = File.read(source).split(/^CLAUDE_GUARD_RUBY\n/, 2).first.split(/<<'CLAUDE_GUARD_RUBY'\n/, 2).last
      Tempfile.create('claude-guard') do |rb|
        rb.write(script)
        rb.flush
        ClaudeGuard.new.main(['install', rb.path, raw, zdot])
      end
    else
      ClaudeGuard.new.main(ARGV)
    end
  rescue StandardError, Interrupt => e
    warn e.is_a?(RuntimeError) || e.is_a?(Interrupt) ? e.message : "Claude 保护执行失败（#{e.class}）"
    exit 1
  end
end
CLAUDE_GUARD_RUBY
    ;;
*)
    exec /usr/bin/env -u RUBYOPT -u RUBYLIB /usr/bin/ruby -EUTF-8:UTF-8 "$state/guard.rb" "$@"
    ;;
esac
