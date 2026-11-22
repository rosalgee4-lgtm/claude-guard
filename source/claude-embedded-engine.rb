# encoding: UTF-8
require File.join(Dir.home, '.claude-clash-guard', 'guard.rb')

# Run the existing Mihomo logic within the unified service process.
class EmbeddedClaudeGuard < ClaudeGuard
  attr_reader :ready

  def stop
    @stop_requested = true
  end

  def record(*args)
    # Registering the shared PID would make close_gate kill its own service.
    if args == ['launch', Process.pid]
      return @mutex.synchronize do
        if @route && @route[:expires] > now
          {'ok' => true, 'proxy' => health_option(@front_port), 'port' => @front_port}
        else
          {'ok' => false, 'error' => @error || '代理未就绪'}
        end
      end
    end
    super
  end

  def serve
    @inbound = JSON.parse(File.read(file('inbound.json')))
    @relay_secret = SecureRandom.hex(24)
    File.rename(@control, @control + '.previous') if File.socket?(@control)
    control = UNIXServer.new(@control)
    File.chmod(0600, @control)
    relay_server = TCPServer.new('127.0.0.1', 0)
    @front_port = relay_server.addr[1]
    @ready = true
    slots = SizedQueue.new(64)
    monitor_thread = Thread.new { monitor_after_activation }
    until @stop_requested
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
    @ready = false
    monitor_thread&.kill
    monitor_thread&.join
    close_gate('监控退出')
    reject_selector
    control&.close
    relay_server&.close
  end

end
