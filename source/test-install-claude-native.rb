require 'tmpdir'
require 'fileutils'
require_relative 'install-claude-native'
class FakeNativeInstaller < ClaudeNativeInstaller
  attr_accessor :fail_start, :fail_write
  attr_reader :starts, :stops
  def initialize; @starts=0; @stops=0; end
  def validate_environment; end
  def loaded?; true; end
  def stop; @stops+=1; end
  def start
    @starts+=1
    if @fail_start; @fail_start=false; raise 'injected start failure'; end
  end
  def atomic(path,*rest)
    if @fail_write && path.end_with?('claude-native-intercept.rb')
      @fail_write=false; raise 'injected write failure'
    end
    super
  end
end
[:normal,:write,:start].each do |mode|
  Dir.mktmpdir do |dir|
    ClaudeNativeInstaller.send(:remove_const,:STATE); ClaudeNativeInstaller.const_set(:STATE,dir)
    service=File.binread(File.join(__dir__,'claude-unified-service.rb'))
    check=File.binread(File.join(__dir__,'claude-selfcheck.rb')).sub("\nif $PROGRAM_NAME == __FILE__\n".b, "\nrequire_relative 'claude-local-intercept'\nclass ClaudeSelfcheck\n  def direct_test; ClaudeLocalIntercept.new(self).run; end\nend\nif $PROGRAM_NAME == __FILE__\n".b)
    File.binwrite(File.join(dir,'service.rb'),service); File.binwrite(File.join(dir,'selfcheck.rb'),check)
    installer=FakeNativeInstaller.new; installer.fail_start=(mode==:start); installer.fail_write=(mode==:write)
    begin
      installer.install
      raise 'failure not injected' unless mode==:normal
      patched=File.binread(File.join(dir,'service.rb'))
      raise 'monitor gate absent' unless patched.include?('verify_firewall!')
      raise 'native launcher absent' unless patched.include?("require_relative 'claude-desktop-lulu'")
      installer.install
      raise 'idempotent update restarted service' unless installer.starts==1 && installer.stops==1
    rescue RuntimeError => e
      raise unless mode!=:normal && e.message.start_with?('injected ')
      raise 'service rollback failed' unless File.binread(File.join(dir,'service.rb'))==service
      raise 'selfcheck rollback failed' unless File.binread(File.join(dir,'selfcheck.rb'))==check
      raise 'module leaked after rollback' if File.exist?(File.join(dir,'claude-lulu-gate.rb'))
      raise 'old service not restarted' unless installer.starts >= 1
    end
  end
end
puts 'PASS native install, monitor gating, idempotency, partial write and startup failure rollback'
