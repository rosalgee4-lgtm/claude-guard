require 'tmpdir'
require 'fileutils'
require 'rbconfig'
require_relative 'install-claude-selfcheck'
class TestSelfcheckInstaller < SelfcheckInstaller
  attr_accessor :fail_once
  def verify_environment; end
  def loaded; true; end
  def stop
    @server&.close
    @thread&.join
    @server = nil
  end
  def run(*args)
    if args.first == '/usr/bin/ruby'
      raise 'syntax error' unless system(RbConfig.ruby, '--disable-gems', '-c', args.last, out: File::NULL)
    elsif args[1] == 'bootstrap'
      if @fail_once
        @fail_once = false
        raise 'injected startup failure'
      end
      path = File.join(SelfcheckInstaller::STATE, 'control.sock')
      File.unlink(path) if File.socket?(path)
      @server = UNIXServer.new(path)
      @thread = Thread.new do
        begin
          socket = @server.accept
          socket.gets
          socket.puts(JSON.generate('diagnostics' => {}))
          socket.close
        rescue IOError, SystemCallError
          nil
        end
      end
    else
      raise 'unexpected command'
    end
  end
end
[false, true].each do |fail_start|
  Dir.mktmpdir do |directory|
    state = File.join(directory, 'state')
    Dir.mkdir(state)
    menu = File.join(directory, '状态与日志.command')
    {STATE: state, MENU_LOG: menu, PLIST: File.join(directory, 'agent.plist')}.each do |key, value|
      SelfcheckInstaller.send(:remove_const, key)
      SelfcheckInstaller.const_set(key, value)
    end
    source = File.binread(File.join(__dir__, 'claude-unified-service.rb'))
    File.binwrite(File.join(state, 'service.rb'), source)
    File.binwrite(menu, '旧菜单 ✓')
    File.chmod(0700, menu)
    original_manifest = JSON.generate('menus' => [])
    File.write(File.join(state, 'migration.json'), original_manifest)
    installer = TestSelfcheckInstaller.new
    installer.fail_once = fail_start
    begin
      installer.install
      raise 'failure not raised' if fail_start
      raise 'missing support hook' unless File.read(File.join(state, 'service.rb')).include?("require_relative 'selfcheck-support'")
      manifest = JSON.parse(File.read(File.join(state, 'migration.json')))
      item = manifest['menus'].first
      raise 'backup bytes changed' unless File.binread(File.join(state, item['backup'])) == '旧菜单 ✓'.b
      raise 'manifest mismatch' unless Digest::SHA256.file(menu).hexdigest == item['after']
      raise 'old log still displayed' if File.read(menu).include?('.claude-clash-guard/guard.log')
      installer.stop
      installer.install # repeated update retains original backup
      raise 'duplicate manifest entry' unless JSON.parse(File.read(File.join(state, 'migration.json')))['menus'].size == 1
    rescue RuntimeError => error
      raise unless fail_start && error.message == 'injected startup failure'
      raise 'service not restored' unless File.binread(File.join(state, 'service.rb')) == source
      raise 'menu not restored' unless File.binread(menu) == '旧菜单 ✓'.b
      raise 'manifest not restored' unless File.read(File.join(state, 'migration.json')) == original_manifest
      raise 'new files left behind' if File.exist?(File.join(state, 'selfcheck.rb'))
    ensure
      installer.stop
    end
  end
end
puts 'PASS installer syntax, UTF-8 menu backup, manifest, repeated install, startup-failure rollback'
