require 'tmpdir';require 'time'
class ClaudeDesktopService
  attr_reader :events
  def initialize(ready)
    @ready=ready; @events=[]; @launch_mutex=Mutex.new; @raw=true
    owner=self; @guard=Object.new
    @guard.define_singleton_method(:identity){|_| 'birth'}
    @guard.define_singleton_method(:terminate){|_|owner.events << :terminate; owner.instance_variable_set(:@raw,false)}
  end
  def processes; @raw ? {11=>'birth'} : {}; end
  def proxy; @ready; end
  def verify_firewall!; @events << :firewall; end
  def launch; @events << :launch; end
end
require_relative 'claude-icon-launch'
class TestIconService < ClaudeDesktopService
  def unprotected_desktop_main; @raw ? [11,'birth'] : nil; end
end
Dir.mktmpdir do |dir|
  ClaudeDesktopService.const_set(:STATE,dir)
  s=TestIconService.new(true);s.icon_launch_once;raise unless s.events==[:terminate,:firewall,:launch]
  s.icon_launch_once;raise 'duplicate launch' unless s.events.count(:launch)==1
  s=TestIconService.new(false);s.icon_launch_once;raise unless s.events==[:terminate]
  s.instance_variable_set(:@ready,true);s.icon_launch_once;raise 'reopened after failure' if s.events.include?(:launch)
  lock=File.open(File.join(dir,'selfcheck.lock'),'w');lock.flock(File::LOCK_EX)
  s=TestIconService.new(true);s.icon_launch_once;raise 'interfered with selfcheck' unless s.events.empty?;lock.close
end
puts 'PASS adoption order, no retry after failure, no duplicate reopen, selfcheck exclusion'
