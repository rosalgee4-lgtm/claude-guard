require 'tmpdir'
require 'rbconfig'
require_relative 'install-claude-local-intercept'
class SimulatedInterceptInstaller < ClaudeLocalInterceptInstaller
  attr_accessor :fail_path
  def verify_environment; end
  def verify_menu; end
  def syntax(path)
    raise 'syntax failure' unless system(RbConfig.ruby, '--disable-gems', '-c', path, out: File::NULL)
  end
  def atomic(path, *args)
    if path == @fail_path
      @fail_path = nil
      raise 'injected write failure'
    end
    super
  end
end
[false, true].each do |failure|
  Dir.mktmpdir do |directory|
    ClaudeLocalInterceptInstaller.send(:remove_const, :STATE)
    ClaudeLocalInterceptInstaller.const_set(:STATE, directory)
    path = File.join(directory, 'selfcheck.rb')
    original = File.binread('claude-selfcheck.rb')
    original = original.sub("report('故障清理 Claude 进程', observed_cleanup ? '未验证' : '失败', '已核对 PID 身份和当前进程；进程消失不能区分监控清理与应用自行退出，尚缺少终止归因证据')".b,
      "report('故障清理 Claude 进程', observed_cleanup ? '通过' : '失败', '核对测试前 PID 身份及当前识别到的 Claude/子进程')".b)
    File.binwrite(path, original)
    File.chmod(0600, path)
    installer = SimulatedInterceptInstaller.new
    installer.fail_path = File.join(directory, 'claude-lulu-readonly.rb') if failure
    begin
      installer.install
      raise 'expected failure' if failure
      once = File.binread(path)
      installer.install
      raise 'duplicate hook' unless once == File.binread(path) && once.scan('# BEGIN local interception test v1').size == 1
      raise 'missing hook' unless once.include?('ClaudeLocalIntercept.new(self).run')
      raise 'legacy cleanup false pass retained' unless once.include?("observed_cleanup ? '未验证'".b)
    rescue RuntimeError => e
      raise unless failure && e.message == 'injected write failure'
      raise 'old selfcheck not restored' unless File.binread(path) == original
      raise 'new module leaked' if File.exist?(File.join(directory, 'claude-local-intercept.rb'))
    end
  end
end
puts 'PASS existing menu script hook, repeat installation, syntax, partial-write rollback'
