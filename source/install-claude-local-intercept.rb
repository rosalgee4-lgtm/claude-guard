# encoding: UTF-8
require 'tempfile'
require 'open3'
class ClaudeLocalInterceptInstaller
  STATE = File.join(Dir.home, '.claude-unified')
  def atomic(path, bytes, mode)
    Tempfile.create('.intercept-update-', File.dirname(path)) do |file|
      file.binmode
      file.write(bytes)
      file.flush
      File.chmod(mode, file.path)
      File.rename(file.path, path)
    end
  end
  def verify_environment
    raise '请在Mac当前账号执行，不要sudo' unless RUBY_PLATFORM.include?('darwin') && Process.uid != 0
  end
  def verify_menu
    menu = File.join(Dir.home, '.claude-clash-menu', 'menu.js')
    raise '未找到已有一键自检菜单，未修改' unless File.file?(menu) && File.read(menu).include?('/.claude-unified/selfcheck.rb')
  end
  def syntax(path)
    _, _, status = Open3.capture3('/usr/bin/ruby', '-EUTF-8:UTF-8', '-c', path)
    raise 'Ruby语法检查失败，未安装' unless status.success?
  end
  def install
    verify_environment
    verify_menu
    path = File.join(STATE, 'selfcheck.rb')
    raise '请先安装已有菜单自检版本' unless File.file?(path)
    lock = File.open(File.join(STATE, 'selfcheck.lock'), File::RDWR | File::CREAT, 0600)
    raise '自检或更新正在运行，请完成后再更新' unless lock.flock(File::LOCK_EX | File::LOCK_NB)
    original = File.binread(path)
    source = original.dup.force_encoding('UTF-8')
    old_cleanup = "report('故障清理 Claude 进程', observed_cleanup ? '通过' : '失败', '核对测试前 PID 身份及当前识别到的 Claude/子进程')"
    new_cleanup = "report('故障清理 Claude 进程', observed_cleanup ? '未验证' : '失败', '已核对 PID 身份和当前进程；进程消失不能区分监控清理与应用自行退出，尚缺少终止归因证据')"
    source = source.sub(old_cleanup, new_cleanup)
    marker = "\nif $PROGRAM_NAME == __FILE__\n"
    hook = <<~'CODE'
      # BEGIN local interception test v1
      require_relative 'claude-local-intercept'
      class ClaudeSelfcheck
        def direct_test
          ClaudeLocalIntercept.new(self).run
        end
      end
      # END local interception test v1
    CODE
    unless source.include?('# BEGIN local interception test v1')
      raise '自检版本不匹配，未修改' unless source.scan(marker).size == 1 && source.include?('def direct_test') && source.include?('def outage_test')
      source = source.sub(marker, "\n" + hook + marker)
    end
    updates = {path => [source, File.stat(path).mode & 0777]}
    %w[claude-local-intercept.rb claude-lulu-readonly.rb].each do |name|
      updates[File.join(STATE, name)] = [File.binread(File.join(__dir__, name)), 0600]
    end
    originals = updates.keys.to_h do |target|
      raise '文件是符号链接，未修改' if File.symlink?(target)
      [target, File.exist?(target) ? [File.binread(target), File.stat(target).mode & 0777] : nil]
    end
    raise '自检文件已被其他任务修改' unless originals[path][0] == original
    updates.each_value do |bytes, _|
      Tempfile.create(['intercept-syntax-', '.rb']) do |file|
        file.binmode; file.write(bytes); file.flush
        syntax(file.path)
      end
    end
    written = []
    begin
      updates.each do |target, (bytes, mode)|
        prior = originals[target]
        next if prior == [bytes.b, mode]
        raise '文件在更新期间改变' if File.symlink?(target) || (prior ? File.binread(target) != prior[0] : File.exist?(target))
        atomic(target, bytes, mode)
        written << target
      end
    rescue Exception
      errors = []
      written.reverse_each do |target|
        begin
          prior = originals[target]
          prior ? atomic(target, prior[0], prior[1]) : File.unlink(target)
        rescue StandardError
          errors << target
        end
      end
      warn(errors.empty? ? '更新失败，本次文件改动已回滚。' : '更新失败，部分文件回滚未完成。')
      raise
    end
    puts '已接入原“一键自检”菜单：下次点击自动使用无Node的本机实际连接测试。'
    puts '没有新增或重启服务，没有修改LuLu/Clash/UU。'
  ensure
    lock&.close
  end
end
if $PROGRAM_NAME == __FILE__
  begin
    ClaudeLocalInterceptInstaller.new.install
  rescue StandardError => error
    warn(error.is_a?(RuntimeError) ? error.message : "更新失败（#{error.class}）")
    exit 1
  end
end
