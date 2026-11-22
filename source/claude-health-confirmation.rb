require 'openssl'
# One bounded confirmation after a transient health error. Never opens the UI gate during review.
module ClaudeHealthConfirmation
  attr_reader :confirmed_close_reason

  def health_review_pending?
    return true if @visibility_hold_started
    deadline=@health_review_until
    deadline && now < deadline
  end
  def health_diagnostics
    {'policy'=>'disconnect_unverified_terminate_only_clash_absent_or_direct','confirmation_deadline_seconds'=>10,'review_pending'=>!!health_review_pending?, 'last_probe'=>@last_probe,
     'visibility_hold_limit_seconds'=>nil,'visibility_hold_active'=>!!@visibility_hold_started,'last_failure_pair'=>@last_failure_pair,'last_launch_probe'=>@last_launch_probe,'last_tunnel_failure'=>@last_tunnel_failure,'last_failure'=>@last_health_failure, 'last_close_reason'=>@last_close_reason}
  end
  # Only positive evidence about Clash can authorize a runtime termination.
  def clash_stop_reason
    gui=clash_process_status('clash-verge',true)
    return 'clash_gui_absent' if gui==1
    core=clash_process_status('verge-mihomo',false)
    return 'clash_core_absent' if core==1
    return unless gui==0 && core==0
    path=socket_paths.find{|candidate| File.socket?(candidate) && [0,Process.uid].include?(File.stat(candidate).uid)}
    return unless path
    config=controller(path,'/configs')
    mode=config && config['mode'].to_s.downcase
    return 'clash_direct_mode' if mode=='direct'
    return unless mode=='global'
    proxies=controller(path,'/proxies')
    return 'clash_global_direct' if global_direct?(proxies && proxies['proxies'])
    nil
  rescue StandardError
    nil
  end

  def clash_process_status(name,user_only)
    args=['/usr/bin/pgrep','-x']
    args+=['-u',Process.uid.to_s] if user_only
    Open3.capture3(*args,name).last.exitstatus
  end

  def global_direct?(proxies)
    return false unless proxies.is_a?(Hash)
    name='GLOBAL'
    seen={}
    until seen[name]
      seen[name]=true
      entry=proxies[name]
      return false unless entry.is_a?(Hash)
      return true if entry['type'].to_s.downcase=='direct'
      name=entry['now']
      return false unless name.is_a?(String) && Array(entry['all']).include?(name)
    end
    false
  end

  def terminate(pids,tree:true)
    return if pids.empty?
    # Icon adoption replaces a fresh, unprotected process with the protected launch.
    return super if Thread.current[:claude_termination_cause]=='unprotected_icon_launch'
    reason=clash_stop_reason
    return unless reason
    prior=Thread.current[:claude_termination_cause]
    begin
      Thread.current[:claude_termination_cause]=reason
      super
    ensure
      Thread.current[:claude_termination_cause]=prior
    end
  end

  def probe_result(output, status, started, purpose)
    fields=output.to_s.split('|',-1)
    http,connect,tcp,tls,total,local_port=fields
    valid=[5,6].include?(fields.size) && http.match?(/\A[2-5]\d\d\z/)
    tls_ok=tls.to_f>0 && connect=='200'
    stage=if connect!='200'; 'proxy_connect_or_route_validation'
    elsif tls.to_f<=0; 'tls_handshake'
    elsif !valid; 'http_response'
    elsif !status.success?; 'http_transfer'
    else; 'reachable';end
    {'time'=>Time.now.utc.iso8601,'purpose'=>purpose,'http_status'=>http,'proxy_connect_status'=>connect,
      'curl_exit'=>status.exitstatus,'duration_seconds'=>(now-started).round(3),
      'tcp_seconds'=>tcp.to_f,'tls_seconds'=>tls.to_f,'total_seconds'=>total.to_f,
      'stage'=>stage,'reachable'=>status.success? && valid && tls_ok,
      'local_port'=>local_port.to_i,'service_response'=>http=='401' ? 'expected_unauthenticated' : 'other_http_response'}
  end
  def perform_health_probe(proxy, purpose='primary')
    started=now
    url=purpose=='confirmation' ? 'https://api.anthropic.com/' : ClaudeGuard::URL
    output,_,status=Open3.capture3(ClaudeGuard::CURL,'-q','--config','-','-s','--noproxy','',
      '--head','--connect-timeout','8','--max-time','8','-o','/dev/null',
      '-w','%{http_code}|%{http_connect}|%{time_connect}|%{time_appconnect}|%{time_total}|%{local_port}',url,
      stdin_data:"proxy = #{JSON.generate(proxy)}\n")
    result=probe_result(output,status,started,purpose)
    failure=@mutex.synchronize{(@tunnel_failures_by_port || {}).delete(result.delete('local_port'))}
    result['tunnel_failure']=failure[1] if failure && failure[0]>=started
    result
  end
  def close_health_transport
    stream=@health_stream;@health_stream=nil
    if stream
      begin;stream[:tls].close;rescue StandardError;end;shutdown(stream[:raw])
    end
  end
  # Only credential-free HEAD requests to the fixed health host use this persistent stream.
  # It goes through the same authenticated relay and mandatory per-connection route verification.
  def measured_probe(purpose='primary')
    started=now;phase='proxy_connect_or_route_validation';port=nil
    reused=!!@health_stream;tcp=0;tls_time=0;http='000';connect='000'
    raw=tls=nil
    begin
      Timeout.timeout(8) do
        unless @health_stream
          proxy=URI.parse(health_option(@front_port))
          raise '健康入口必须为本机HTTP代理' unless proxy.scheme=='http' && proxy.host=='127.0.0.1'
          raw=Socket.tcp(proxy.host,proxy.port,connect_timeout:1);port=raw.local_address.ip_port;tcp=now-started
          auth=proxy.user ? "Proxy-Authorization: Basic #{Base64.strict_encode64("#{URI.decode_www_form_component(proxy.user)}:#{URI.decode_www_form_component(proxy.password.to_s)}")}\r\n" : ''
          raw.write("CONNECT api.anthropic.com:443 HTTP/1.1\r\nHost: api.anthropic.com:443\r\n#{auth}\r\n")
          header=read_header(raw);connect=header.to_s[/\AHTTP\/1\.[01] (\d{3}) /,1] || '000'
          raise '健康入口未建立已核验隧道' unless connect=='200'
          phase='tls_handshake';ctx=OpenSSL::SSL::SSLContext.new;ctx.set_params
          # Match the prior curl test trust override, without changing system certificate settings.
          if ENV['CURL_CA_BUNDLE'] && !ENV['CURL_CA_BUNDLE'].empty?
            store=OpenSSL::X509::Store.new;store.set_default_paths;store.add_file(ENV['CURL_CA_BUNDLE']);ctx.cert_store=store
          end
          tls=OpenSSL::SSL::SSLSocket.new(raw,ctx);tls.hostname='api.anthropic.com';tls.sync_close=true
          tls.connect;tls.post_connection_check('api.anthropic.com');tls_time=now-started
          @health_stream={tls:tls,raw:raw,port:port};@health_connections=(@health_connections || 0)+1
        end
        stream=@health_stream;port=stream[:port];connect='200';phase='http_response'
        path=purpose=='confirmation' ? '/' : '/v1/models'
        stream[:tls].write("HEAD #{path} HTTP/1.1\r\nHost: api.anthropic.com\r\nConnection: keep-alive\r\nUser-Agent: ClaudeGuard-Health/1\r\n\r\n")
        response=read_header(stream[:tls]);http=response.to_s[/\AHTTP\/1\.[01] ([2-5]\d\d) /,1] || '000'
        raise '健康目标未返回有效HTTP响应' if http=='000'
        close_health_transport if response.match?(/^Connection:\s*close\s*$/i)
      end
      @last_probe={'time'=>Time.now.utc.iso8601,'purpose'=>purpose,'transport'=>'verified_persistent_tls',
        'http_status'=>http,'proxy_connect_status'=>connect,'duration_seconds'=>(now-started).round(3),
        'stage'=>'reachable','reachable'=>true,'reused_connection'=>reused,'transport_connections'=>@health_connections,
        'tcp_seconds'=>tcp.round(3),'tls_seconds'=>tls_time.round(3)}
      true
    rescue StandardError=>e
      failure=@mutex.synchronize{(@tunnel_failures_by_port || {}).delete(port)}
      @last_probe={'time'=>Time.now.utc.iso8601,'purpose'=>purpose,'transport'=>'verified_persistent_tls',
        'http_status'=>http,'proxy_connect_status'=>connect,'duration_seconds'=>(now-started).round(3),
        'stage'=>phase,'reachable'=>false,'reused_connection'=>reused,'error_class'=>e.class.to_s}
      @last_probe['tunnel_failure']=failure[1] if failure && failure[0]>=started
      close_health_transport;begin;tls.close if tls;rescue StandardError;end;shutdown(raw)
      false
    end
  end
  def desktop_probe_ready?(proxy)
    @last_launch_probe=perform_health_probe(proxy,'launch')
    @last_launch_probe['reachable']
  end
  # Associate failures with the exact curl->relay connection, never another app's tunnel.
  def relay(client)
    Thread.current[:claude_relay_port]=client.peeraddr[1]
    super
  ensure
    Thread.current[:claude_relay_port]=nil
  end
  def open_tunnel(path,target,node)
    started=now;verified=false;stage='connect'
    upstream=Socket.tcp('127.0.0.1',@inbound.fetch('port'),connect_timeout:1)
    Timeout.timeout(3) do
      upstream.write("CONNECT #{target} HTTP/1.1\r\nHost: #{target}\r\n\r\n")
      response=read_header(upstream)
      raise '专用入口拒绝连接' unless response && response.match?(/\AHTTP\/1\.[01] 200 /)
    end
    stage='route_visibility';deadline=started+6;connection=nil;controller_seen=false
    loop do
      listing=controller(path,'/connections');controller_seen ||= listing.is_a?(Hash) && listing['connections'].is_a?(Array)
      connection=Array(listing && listing['connections']).find do |entry|
        m=entry['metadata']
        m && m['sourceIP']=='127.0.0.1' && m['sourcePort'].to_i==upstream.local_address.ip_port && m['inboundPort'].to_i==@inbound.fetch('port')
      end
      break if connection || now>=deadline
      sleep 0.08
    end
    unless connection
      stage=controller_seen ? 'route_visibility_pending' : 'controller_unavailable'
      raise(controller_seen ? 'Mihomo尚未提供该专用连接的出口记录' : 'Mihomo连接核验接口不可用')
    end
    stage='route_mismatch';m=connection.fetch('metadata');chain=Array(connection['chains'])
    verified=m['inboundName']==ClaudeGuard::INBOUND && m['specialProxy']==ClaudeGuard::GROUP && chain.first==node && chain.include?(ClaudeGuard::GROUP) && !chain.include?('DIRECT')
    raise '专用出口记录不符合安全要求' unless verified
    upstream
  rescue StandardError=>e
    event={'time'=>Time.now.utc.iso8601,'duration_seconds'=>(now-started).round(3),'stage'=>stage,
      'error_class'=>e.class.to_s,'reason'=>e.is_a?(RuntimeError) ? e.message : '专用隧道建立失败'}
    @last_tunnel_failure=event
    port=Thread.current[:claude_relay_port]
    @mutex.synchronize do
      @tunnel_failures_by_port ||= {};@tunnel_failures_by_port[port]=[now,event] if port
      @tunnel_failures_by_port.delete_if{|_,(at,_)|now-at>30}
    end
    warn JSON.generate('claude_tunnel_failure'=>event)
    raise
  ensure
    shutdown(upstream) unless verified
  end
  def suspend_health_connections
    close_health_transport
    # Inconclusive visibility holds retain processes until verified recovery or a hard failure.
    @health_review_until=@visibility_hold_started ? nil : now+10
    pipes=@mutex.synchronize do
      @route=nil; @error='健康探测异常，断流复核中'
      old=@tunnels; @tunnels={}; old
    end
    pipes.each{|a,b|shutdown(a);shutdown(b)}
    @audit_mutex.synchronize { @audit['events']+=1; @audit['tunnels_closed']+=pipes.size; @audit['time']=Time.now.utc.iso8601 }
  end
  def close_gate(reason)
    if reason=='代理探测已超时'
      pipes=@mutex.synchronize do
        return unless @route && @route[:expires]<=now
        @route=nil
        @error=reason
        old=@tunnels
        @tunnels={}
        old
      end
      pipes.each{|client,upstream|shutdown(client);shutdown(upstream)}
      warn JSON.generate('claude_engine_decision'=>{'time'=>Time.now.utc.iso8601,'reason'=>reason,'decision'=>'disconnect_retain'})
      return
    end
    close_health_transport
    @visibility_hold_started=nil
    @confirmed_close_reason=nil
    @last_close_reason={'time'=>Time.now.utc.iso8601,'reason'=>reason}
    @health_review_until=nil
    super
    @confirmed_close_reason=clash_stop_reason
  end
  def probe_failure_kind(probe)
    tunnel=probe.dig("tunnel_failure","stage")
    return "route_visibility_pending" if tunnel=="route_visibility_pending"
    return "hard_or_other_failure" if tunnel
    timeout=probe["error_class"]=="Timeout::Error" || probe["error_class"]=="Net::ReadTimeout" || probe["curl_exit"]==28
    return "http_timeout" if probe["stage"]=="http_response" && timeout
    "hard_or_other_failure"
  end
  def inconclusive_failure_pair?(first,confirmation)
    kinds=[probe_failure_kind(first),probe_failure_kind(confirmation)]
    kinds.include?("route_visibility_pending") && kinds.all?{|kind|["route_visibility_pending","http_timeout"].include?(kind)}
  end
  def monitor
    loop do
      begin
        route=running_route
        path,chain,current=route; node=chain.last
        previous=@mutex.synchronize{@route && @route[:path]}
        close_gate('全局节点正在切换') if previous && previous!=route
        if current!=node
          @selector=path
          raise '无法切换 Claude 专用代理组' unless set_selector(path,node)
        end
        @selector=path; check=[path,chain,node]
        @mutex.synchronize{@probe_route={path:check,expires:now+10,probe:true}}
        healthy=measured_probe
        unless healthy
          @last_health_failure=@last_probe.dup.merge('failure_phase'=>'first_failure')
          warn JSON.generate('claude_health_failure'=>@last_health_failure)
          first_failure=@last_probe.dup
          suspend_health_connections
          raise '复核前全局节点或模式已变化' unless running_route==check
          @mutex.synchronize{@probe_route={path:check,expires:now+10,probe:true}}
          healthy=measured_probe('confirmation')
          unless healthy
            @last_health_failure=@last_probe.dup.merge('failure_phase'=>'confirmation_failed')
            warn JSON.generate('claude_health_failure'=>@last_health_failure)
            pending=inconclusive_failure_pair?(first_failure,@last_probe)
            @last_failure_pair={"time"=>Time.now.utc.iso8601,"primary"=>probe_failure_kind(first_failure),"confirmation"=>probe_failure_kind(@last_probe),"decision"=>pending ? "hold_inconclusive" : "disconnect_check_clash_state"}
            warn JSON.generate("claude_failure_pair"=>@last_failure_pair)
            if pending
              @visibility_hold_started ||= now
              @health_review_until=nil
              @mutex.synchronize{@error='出口记录未确认：持续断流并保留Claude，等待核验恢复';@probe_route=nil}
              sleep 2
              next
            end
            raise "专用路径复核失败（#{@last_probe['stage'] || 'unknown'}，#{@last_probe['error_class'] || @last_probe['curl_exit']}），已保持断流"
          end
        end
        raise '全局节点或模式已变化' unless running_route==check
        @mutex.synchronize do
          @confirmed_close_reason=nil
          @route={path:check,expires:now+14};@probe_route=nil;@error=nil
          @sessions.delete_if{|pid,stamp|identity(pid)!=stamp}
        end
        @health_review_until=nil
        @visibility_hold_started=nil
      rescue StandardError=>e
        reason=e.is_a?(RuntimeError) ? e.message : "健康监控异常（#{e.class}）"
        close_gate(reason);reject_selector
      end
      sleep 2
    end
  end
end
EmbeddedClaudeGuard.prepend(ClaudeHealthConfirmation)

module ClaudeDesktopHealthConfirmation
  def close_gate(reason)
    trigger=reason
    evidence=@guard.confirmed_close_reason
    retain=!evidence
    decision=retain ? 'disconnect_retain' : 'terminate'
    reason=evidence if evidence && @firewall && reason!='监控退出'
    entry={'trigger'=>trigger,'reason'=>reason,'decision'=>decision,'firewall_verified'=>!!@firewall}
    unless @last_desktop_close && entry.all?{|key,value| @last_desktop_close[key]==value}
      @last_desktop_close=entry.merge('time'=>Time.now.utc.iso8601)
      warn JSON.generate('claude_desktop_decision'=>@last_desktop_close)
    end
    if retain
      sockets=@mutex.synchronize do
        @expires=0;@proxy=nil;@reason='代理断流复核中'
        current=@streams.keys;@streams.clear;current
      end
      sockets.each{|s|@guard.shutdown(s)}
      return
    end
    super
  end
  def selfcheck_snapshot
    super.merge('health_check'=>@guard.health_diagnostics,'last_desktop_close'=>@last_desktop_close)
  end
end
ClaudeDesktopService.prepend(ClaudeDesktopHealthConfirmation)
