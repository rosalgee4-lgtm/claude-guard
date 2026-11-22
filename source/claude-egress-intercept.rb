# encoding: UTF-8
require_relative 'claude-native-intercept'
class ClaudeEgressIntercept < ClaudeNativeIntercept
  PUBLIC_TARGETS = ['1.1.1.1', '2606:4700:4700::1111'].freeze
  def endpoint_map(host,port)
    host.include?(':') ? {"[#{host}]:#{port}"=>'IPv6',"#{host}.#{port}"=>'IPv6',"#{host}:#{port}"=>'IPv6'} : {"#{host}:#{port}"=>'IPv4'}
  end
  def browser_arguments(address,data)
    return super unless @quic
    ["--user-data-dir=#{data}","--proxy-server=#{address.sub('http:', 'quic:')}",'--proxy-bypass-list=<-loopback>']
  end
  def inspect_connections(port)
    super
    return unless @quic
    output,_,_=Open3.capture3('/usr/sbin/lsof','-nP',"-iUDP:#{port}",'-Fpn')
    pid=nil
    output.each_line do |line|
      if line.start_with?('p'); pid=line[1..-1].to_i
      elsif line.start_with?('n') && pid
        if line.include?("->127.0.0.1:#{port}") || line.include?("->[::1]:#{port}")
          id=resolve(pid)
          @udp_paths[id[:path]]=true if id
        end
      end
    end
  end
  def assess(name,evidence,protocol_proven: true)
    if !evidence.allowed.empty?
      report(name,'失败','LuLu允许了目标连接；不能计为拦截成功')
    elsif !@log_failed && protocol_proven && evidence.blocked.keys.any? { |key| block_has_control?(key) }
      paths=evidence.blocked.keys.select { |key| block_has_control?(key) }.map { |key| File.basename(key[0]) }.uniq
      report(name,'通过',"#{paths.join('、')} 的目标端点、当前进程身份、阻止规则和最终block判决匹配，且具有固定代理端口正对照；保持现有TUN")
    else
      report(name,'未验证','没有取得该测试所需的完整拒绝及协议证据；无流量或超时不算通过')
    end
  end
  def prepare_tests
    super
    saved=@evidence
    PUBLIC_TARGETS.each do |host|
      family=host.include?(':') ? 'IPv6' : 'IPv4'
      begin
        Socket.tcp(host,443,connect_timeout:3) { |s| s.close }
        report("公网#{family}可达对照",'通过','非Claude TCP连接目标443端口成功；仅作为可达对照')
      rescue SystemCallError, IOError
        report("公网#{family}可达对照",'未验证','对照不可达，跳过该目标')
        next
      end
      @evidence=ClaudeLuLuEvidence.new(443,method(:resolve),endpoints:endpoint_map(host,443))
      launch_test(nil,host,443)
      cleanup_claude
      assess("Claude Helper 公网#{family}目标连接",@evidence)
    end
    @quic=true
    @udp_paths={}
    @udp_sink=UDPSocket.new
    @udp_sink.bind('127.0.0.1',0)
    port=@udp_sink.addr[1]
    @evidence=ClaudeLuLuEvidence.new(port,method(:resolve))
    launch_test(nil,'127.0.0.1',port)
    cleanup_claude
    # LuLu's available rule-match messages omit transport protocol.
    # Socket observations alone must not be promoted to a per-flow UDP proof.
    report('UDP套接字触发',@udp_paths.empty? ? '未验证' : '通过',
      @udp_paths.empty? ? 'QUIC代理参数没有生成可确认的真实Claude UDP套接字' : '观察到真实Claude进程指向测试端口的UDP套接字；尚不等同该UDP流的最终拒绝证据')
    assess('Claude UDP精确拦截',@evidence,protocol_proven:false)
  ensure
    @quic=false
    @udp_sink&.close
    cleanup_claude
    @evidence=saved if saved
  end
end
