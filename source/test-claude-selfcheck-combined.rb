require 'tmpdir'
require 'fileutils'
require 'rbconfig'
require_relative 'install-claude-selfcheck-combined'
class FakeCombinedMenu < SelfcheckMenuInstaller
  attr_accessor :fail_next
  attr_reader :restarts
  def initialize; @restarts = 0; end
  def validate(source)
    _, errors, status = Open3.capture3(ENV.fetch('NODE_BIN', 'node'), '--check', stdin_data: source)
    raise errors unless status.success?
  end
  def restart
    @restarts += 1
    if @fail_next
      @fail_next = false
      raise 'injected menu failure'
    end
  end
end
class FakeCombined < CombinedSelfcheckInstaller
  attr_reader :bootstraps, :stops, :menu
  attr_accessor :fail_service
  def initialize
    @bootstraps = @stops = 0
    @menu = FakeCombinedMenu.new
  end
  def verify_environment; end
  def verify_jobs; end
  def loaded; true; end
  def stop; @stops += 1; end
  def menu_installer; @menu; end
  def verify_diagnostics
    if @fail_service
      @fail_service = false
      raise 'injected service failure'
    end
  end
  def run(*args)
    if args.first == '/usr/bin/ruby'
      raise 'Ruby syntax error' unless system(RbConfig.ruby, '--disable-gems', '-c', args.last, out: File::NULL)
    elsif args[1] == 'bootstrap'
      @bootstraps += 1
    else
      raise 'unexpected operation'
    end
  end
end
fixture = File.read(File.join(__dir__, 'legacy', 'install-claude-clash-menu-macos.sh')).split("<<'JXA'\n", 2).last.split("\nJXA", 2).first
service = File.binread('claude-unified-service.rb')
def snapshot(dir)
  Dir.glob(File.join(dir, '**', '*')).select { |path| File.file?(path) && !path.end_with?('selfcheck.lock') }.to_h { |path| [path, [File.binread(path), File.stat(path).mode & 0777]] }
end
%w[base selfcheck_only all menu_failure service_failure].each do |variant|
  Dir.mktmpdir do |dir|
    state = File.join(dir, 'state'); menu = File.join(dir, 'menu')
    FileUtils.mkdir_p([state, menu])
    {STATE: state, MENU_LOG: File.join(menu, '状态与日志.command'), PLIST: File.join(dir, 'agent.plist')}.each do |key, val|
      CombinedSelfcheckInstaller.send(:remove_const, key)
      CombinedSelfcheckInstaller.const_set(key, val)
    end
    menu_path = File.join(menu, 'menu.js')
    manifest_path = File.join(state, 'migration.json')
    File.binwrite(File.join(state, 'service.rb'), service)
    File.write(menu_path, fixture)
    File.write(CombinedSelfcheckInstaller::MENU_LOG, '旧日志 ✓')
    File.write(manifest_path, JSON.generate('menus' => [{'path' => menu_path, 'after' => Digest::SHA256.hexdigest(fixture), 'backup' => 'original-menu'}]))
    if %w[selfcheck_only all].include?(variant)
      FakeCombined.new.install
      if variant == 'selfcheck_only'
        File.write(menu_path, fixture)
        data = JSON.parse(File.read(manifest_path))
        data['menus'].find { |entry| entry['path'] == menu_path }['after'] = Digest::SHA256.hexdigest(fixture)
        File.write(manifest_path, JSON.generate(data))
      end
    end
    before = snapshot(dir)
    installer = FakeCombined.new
    installer.menu.fail_next = variant == 'menu_failure'
    installer.fail_service = variant == 'service_failure'
    begin
      installer.install
      raise 'expected failure' if variant.end_with?('failure')
      expected_boots = variant == 'base' ? 1 : 0
      raise 'unexpected service restart count' unless installer.bootstraps == expected_boots
      expected_menus = variant == 'all' ? 0 : 1
      raise 'unexpected menu restart count' unless installer.menu.restarts == expected_menus
      boot_before = installer.bootstraps
      menu_before = installer.menu.restarts
      installer.install
      raise 'repeat started service' unless installer.bootstraps == boot_before && installer.menu.restarts == menu_before
      raise 'repeat changed bytes' unless variant != 'all' || snapshot(dir) == before
    rescue RuntimeError => e
      raise unless variant.end_with?('failure') && e.message.start_with?('injected')
      raise 'transaction did not restore every file' unless snapshot(dir) == before
      raise 'original service not restarted once' unless installer.bootstraps == 2
    end
    puts "PASS #{variant}"
  end
end
