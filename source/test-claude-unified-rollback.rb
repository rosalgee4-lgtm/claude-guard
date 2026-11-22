require 'tmpdir'
require_relative 'migrate-claude-unified'

class SimulatedMigration < UnifiedMigration
  attr_reader :calls
  def initialize
    @calls = []
    @stopped = false
  end
  def loaded(label)
    label == self.class::LABEL && !@stopped
  end
  def run(*args)
    @calls << args
    @stopped = true if args[1] == 'bootout'
    ''
  end
end

[false, true].each do |had_desktop|
  Dir.mktmpdir('unified-restore-') do |directory|
    state = File.join(directory, 'state')
    plist = File.join(directory, 'new.plist')
    UnifiedMigration.send(:remove_const, :STATE)
    UnifiedMigration.const_set(:STATE, state)
    UnifiedMigration.send(:remove_const, :PLIST)
    UnifiedMigration.const_set(:PLIST, plist)
    FileUtils.mkdir(state)
    menu = File.join(directory, 'menu.sh')
    before = '旧菜单 ✓'
    after = 'new menu'
    File.binwrite(menu, after)
    File.binwrite(File.join(state, 'menu-backup'), before)
    File.binwrite(plist, 'new agent')
    labels = ['local.claude-clash-guard']
    labels << 'local.claude-desktop-service' if had_desktop
    old = labels.map do |label|
      File.write(File.join(state, label), label)
      {'label' => label, 'path' => File.join(directory, label + '.plist'), 'backup' => label, 'loaded' => true}
    end
    entry = {'path' => menu, 'before' => Digest::SHA256.hexdigest(before), 'after' => Digest::SHA256.hexdigest(after),
             'backup' => 'menu-backup', 'mode' => 0700}
    manifest = {'old' => old, 'menus' => [entry], 'plist' => Digest::SHA256.hexdigest('new agent')}
    File.write(File.join(state, 'migration.json'), JSON.generate(manifest))
    migration = SimulatedMigration.new
    migration.restore
    raise 'menu restoration failed' unless File.binread(menu) == before.b
    raise 'new agent still present' if File.exist?(plist)
    old.each { |item| raise 'old agent not restored' unless File.read(item['path']) == item['label'] }
    expected = labels.size
    raise 'wrong number of restored jobs' unless migration.calls.count { |args| args[1] == 'bootstrap' } == expected
    raise 'unified service not stopped first' unless migration.calls.first[1] == 'bootout'
  end
end
puts 'PASS restores original one-service and two-service installations, including UTF-8 menus'
