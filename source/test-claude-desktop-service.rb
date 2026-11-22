require 'securerandom'
require 'socket'
require 'base64'
require 'timeout'
require 'uri'
require 'json'
require 'open3'
require 'fileutils'

# Exercise the bridge without loading or contacting the user's guard.
$LOADED_FEATURES << File.join(Dir.home, '.claude-clash-guard', 'guard.rb')
class ClaudeGuard
  def read_header(socket)
    result = ''.b
    until result.end_with?("\r\n\r\n")
      character = socket.read(1)
      return unless character && result.bytesize < 16_384
      result << character
    end
    result
  end

  def shutdown(socket)
    return unless socket
    socket.shutdown rescue nil
    socket.close rescue nil
  end

  def terminate(victims)
    raise 'unexpected victim' unless victims.empty?
  end
end
require_relative ENV.fetch('CLAUDE_TEST_SERVICE', 'claude-desktop-service')
class TestService < ClaudeDesktopService
  def processes
    {}
  end
end

service = TestService.new
upstream = TCPServer.new('127.0.0.1', 0)
secret = SecureRandom.hex(12)
service.instance_variable_set(:@proxy, URI.parse("http://test:#{secret}@127.0.0.1:#{upstream.addr[1]}"))
service.instance_variable_set(:@expires, service.now + 30)
relay = TCPServer.new('127.0.0.1', 0)
server = Thread.new do
  socket = upstream.accept
  header = ClaudeGuard.new.read_header(socket)
  expected = Base64.strict_encode64("test:#{secret}")
  raise 'missing authentication' unless header.include?("Proxy-Authorization: Basic #{expected}\r\n")
  socket.write("HTTP/1.1 200 OK\r\n\r\n")
  socket.write(socket.read(4))
  socket.read
ensure
  socket&.close
end
bridge = Thread.new { service.bridge(relay.accept) }
client = TCPSocket.new('127.0.0.1', relay.addr[1])
client.write("CONNECT example.com:443 HTTP/1.1\r\nHost: example.com\r\n\r\n")
Timeout.timeout(3) do
  raise 'CONNECT failed' unless ClaudeGuard.new.read_header(client).start_with?('HTTP/1.1 200')
  client.write('ping')
  raise 'tunnel failed' unless client.read(4) == 'ping'
  service.close_gate('test outage')
  raise 'stream remained open' unless client.read.empty?
  bridge.join
  server.join
end
client.close
upstream.close
relay.close
raise 'gate remained open' if service.proxy
puts 'PASS authenticated CONNECT, bidirectional tunnel, outage closes established stream, gate denies access'

class ClaudeGuard
  def identity(pid)
    {101 => 'claude-start', 102 => 'helper-start', 103 => 'shell-start', 104 => 'uu-start'}[pid]
  end
end
module Open3
  class << self
    alias_method :actual_capture3, :capture3
    def capture3(*arguments)
      return actual_capture3(*arguments) unless arguments.first == '/bin/ps'
      uid = Process.uid
      output = "#{uid} 101 1 /Applications/Claude.app/Contents/MacOS/Claude\n" \
               "#{uid} 102 101 /Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper\n" \
               "#{uid} 103 101 /bin/zsh\n" \
               "#{uid} 104 1 /Applications/UU.app/Contents/MacOS/UURemotes\n"
      [output, '', Struct.new(:success?).new(true)]
    end
  end
end
tracked = ClaudeDesktopService.new
# A previously tracked PID now belongs to UU and must be discarded.
tracked.instance_variable_set(:@tracked, {104 => 'different-start'})
raise 'process isolation failed' unless tracked.processes.keys.sort == [101, 102, 103]
puts 'PASS Claude/helper/child selection excludes unrelated UU and reused PID'
