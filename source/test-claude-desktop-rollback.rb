require 'tmpdir'
require 'json'
require 'digest'
require 'open3'
require 'fileutils'
require 'socket'
require 'timeout'
require 'cgi'

source = File.read(File.join(__dir__, 'install-claude-desktop.rb'))
eval(source.split("\nbegin\n  installer = DesktopInstaller.new", 2).first, TOPLEVEL_BINDING, 'install-claude-desktop.rb')

# Avoid calling launchctl outside macOS; filesystem restoration is real.
module Open3
  class << self
    alias_method :real_capture3, :capture3
    def capture3(*arguments)
      return ['', '', Struct.new(:success?).new(arguments[1] != 'print')] if arguments[0] == '/bin/launchctl'
      real_capture3(*arguments)
    end
  end
end

Dir.mktmpdir('desktop-rollback-') do |root|
  state = File.join(root, 'state')
  plist = File.join(root, 'agent.plist')
  menu = File.join(root, 'menu.command')
  DesktopInstaller.send(:remove_const, :STATE)
  DesktopInstaller.const_set(:STATE, state)
  DesktopInstaller.send(:remove_const, :PLIST)
  DesktopInstaller.const_set(:PLIST, plist)
  FileUtils.mkdir(state)
  File.write(menu, 'new menu')
  File.binwrite(File.join(state, 'original-0'), '旧菜单 ✓')
  File.write(plist, 'agent')
  entry = {'path' => menu, 'backup' => 'original-0', 'mode' => 0700,
           'before' => Digest::SHA256.hexdigest('旧菜单 ✓'), 'after' => Digest::SHA256.hexdigest('new menu')}
  manifest = {'files' => [entry], 'plist' => Digest::SHA256.hexdigest('agent')}
  File.write(File.join(state, 'manifest.json'), JSON.generate(manifest))
  DesktopInstaller.new.rollback
  raise 'original menu not restored' unless File.binread(menu) == '旧菜单 ✓'.b
  raise 'launch agent remains' if File.exist?(plist)
  raise 'state not archived' if File.exist?(state)
  raise 'backup missing' unless Dir.glob(state + '.rollback.*/original-0').length == 1
  raise 'wrong permissions' unless File.stat(menu).mode & 0777 == 0700
end
puts 'PASS rollback restores menu and permissions, removes owned agent, retains backup archive'
