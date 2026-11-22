require 'tmpdir'
require 'fileutils'
require_relative 'install-claude-selfcheck-menu'
fixture = File.read(File.join(__dir__, 'legacy', 'install-claude-clash-menu-macos.sh')).split("<<'JXA'\n", 2).last.split("\nJXA", 2).first
addition = File.read('claude-selfcheck-menu.js')
installer = SelfcheckMenuInstaller.new
patched = installer.patch(fixture, addition)
raise 'duplicate action' unless patched.scan("'selfcheck:': {").size == 1
raise 'missing timer hook' unless patched.include?('updateStatus(); pollSelfcheck();')
raise 'not idempotent' unless installer.patch(patched, addition) == patched
if RUBY_PLATFORM.include?('darwin')
  installer.validate(patched)
else
  _, errors, status = Open3.capture3(ENV.fetch('NODE_BIN', 'node'), '--check', stdin_data: patched)
  raise "JS syntax error: #{errors}" unless status.success?
end
older = patched.sub('const data = $.NSData.dataWithContentsOfFile(completed.outputPath);', 'const data = oldPipe;')
raise 'existing menu not upgraded' unless installer.patch(older, addition) == patched
raise 'blocking pipe remains' if addition.include?('readDataToEndOfFile') || addition.include?('$.NSPipe')
class SimulatedMenuInstaller < SelfcheckMenuInstaller
  attr_accessor :fail_restart
  def verify_environment; end
  def validate(source); end
  def restart
    if @fail_restart
      @fail_restart = false
      raise 'injected restart failure'
    end
  end
end
[false, true].each do |fail_restart|
  Dir.mktmpdir do |dir|
    state = File.join(dir, 'state'); menu = File.join(dir, 'menu')
    FileUtils.mkdir_p([state, menu])
    {STATE: state, MENU: menu}.each do |key, val|
      SelfcheckMenuInstaller.send(:remove_const, key)
      SelfcheckMenuInstaller.const_set(key, val)
    end
    path = File.join(menu, 'menu.js')
    File.write(path, fixture)
    manifest_path = File.join(state, 'migration.json')
    original_manifest = JSON.generate('note' => '中文迁移记录', 'menus' => [{'path' => path, 'after' => Digest::SHA256.hexdigest(fixture), 'backup' => 'original-menu'}])
    File.write(manifest_path, original_manifest)
    sim = SimulatedMenuInstaller.new
    sim.fail_restart = fail_restart
    begin
      sim.install
      raise 'expected restart failure' if fail_restart
      installed = File.binread(path)
      entry = JSON.parse(File.read(manifest_path))['menus'][0]
      raise 'wrong digest' unless entry['after'] == Digest::SHA256.hexdigest(installed)
      raise 'lost original backup' unless entry['backup'] == 'original-menu'
      sim.install
    rescue RuntimeError => e
      raise unless fail_restart && e.message == 'injected restart failure'
      raise 'menu not restored' unless File.binread(path) == fixture.b
      raise 'manifest not restored' unless File.binread(manifest_path) == original_manifest.b
    end
  end
end
puts 'PASS menu wiring, JavaScript syntax, idempotency, manifest preservation, restart-failure rollback'
