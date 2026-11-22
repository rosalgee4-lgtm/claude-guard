require_relative 'migrate-claude-unified'

class DelayedStop < UnifiedMigration
  attr_reader :waits, :commands
  def initialize(remaining)
    @remaining = remaining
    @waits = 0
    @commands = []
  end
  def run(*args)
    @commands << args
  end
  def loaded(label)
    @remaining -= 1
    @remaining >= 0
  end
  def sleep(seconds)
    raise 'incorrect wait' unless seconds == 0.2
    @waits += 1
  end
end

task = DelayedStop.new(4)
task.stop_job('local.claude-clash-guard')
raise 'did not wait for disappearance' unless task.waits == 3
raise 'wrong command' unless task.commands.length == 1 && task.commands.first[1] == 'bootout'
stuck = DelayedStop.new(1000)
begin
  stuck.stop_job('local.claude-clash-guard')
  raise 'stuck task accepted'
rescue RuntimeError => error
  raise unless error.message.include?('local.claude-clash-guard') && stuck.waits == 100
end
puts 'PASS waits for asynchronous unload and rejects a task that remains present'
