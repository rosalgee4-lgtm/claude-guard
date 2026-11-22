# Exercise the new method without loading the real service or contacting launchd.
class EmbeddedClaudeGuard; end
class ClaudeDesktopService; end
require_relative 'claude-desktop-lulu'
class RegistrationFixture < EmbeddedClaudeGuard
  attr_accessor :stamp, :expiry
  attr_reader :sessions
  def initialize
    @mutex=Mutex.new; @route={expires:20}; @sessions={}; @stamp='birth-a'
  end
  def now; 10; end
  def identity(pid); @stamp; end
  def expired!; @route={expires:0}; end
end
f=RegistrationFixture.new
raise unless f.register_expected(42,'birth-a')['ok'] && f.sessions[42]=='birth-a'
f=RegistrationFixture.new; f.stamp=nil
r=f.register_expected(42,'birth-a')
raise 'exited process closed healthy gate' unless r['ok'] && r['skipped'] && f.sessions.empty?
f.stamp='birth-b'; r=f.register_expected(42,'birth-a')
raise 'reused PID registered' unless r['ok'] && r['skipped'] && f.sessions.empty?
f.expired!
raise 'expired proxy accepted registration' if f.register_expected(42,'birth-b')['ok']
puts 'PASS live identity registration, stale process exit, PID reuse, expired proxy refusal'
