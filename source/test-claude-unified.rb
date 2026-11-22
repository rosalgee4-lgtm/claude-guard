require 'tmpdir'
require 'stringio'

# Load the local original engine definition without running its installer.
source = File.read(File.join(__dir__, 'legacy', 'install-claude-clash-shared-macos.sh'))
engine = source.split("<<'CLAUDE_GUARD_RUBY'\n", 2).last.split("\nif $PROGRAM_NAME == __FILE__", 2).first
eval(engine, TOPLEVEL_BINDING, 'guard-engine-fixture.rb')
$LOADED_FEATURES << File.join(Dir.home, '.claude-clash-guard', 'guard.rb')
require_relative 'claude-embedded-engine'

guard = EmbeddedClaudeGuard.new
guard.instance_variable_set(:@route, {expires: guard.now + 30})
guard.instance_variable_set(:@front_port, 12345)
guard.instance_variable_set(:@relay_secret, SecureRandom.hex(12))
result = guard.record('launch', Process.pid)
raise 'embedded credentials unavailable' unless result['ok']
raise 'shared process registered for termination' unless guard.instance_variable_get(:@sessions).empty?
guard.close_gate('test')
raise 'gate stayed available' if guard.record('launch', Process.pid)['ok']
puts 'PASS embedded credentials, shared PID exclusion, gate closure'

Dir.mktmpdir('unified-engine-') do |directory|
  runtime = EmbeddedClaudeGuard.new
  runtime.instance_variable_set(:@state, directory)
  runtime.instance_variable_set(:@control, File.join(directory, 'guard.sock'))
  File.write(File.join(directory, 'inbound.json'), '{}')
  def runtime.monitor_after_activation
    loop { sleep 0.1 }
  end
  thread = Thread.new { runtime.serve }
  Timeout.timeout(3) { sleep 0.01 until runtime.ready }
  raise 'control response missing' unless runtime.record('status')['ok'] == false
  runtime.stop
  Timeout.timeout(3) { thread.join }
  raise 'embedded engine remains ready' if runtime.ready
end
puts 'PASS embedded engine thread starts, responds, and shuts down without separate daemon'
