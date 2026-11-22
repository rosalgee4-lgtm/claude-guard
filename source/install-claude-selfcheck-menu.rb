# encoding: UTF-8
require 'json'
require 'digest'
require 'tempfile'
require 'open3'

class SelfcheckMenuInstaller
  STATE = File.join(Dir.home, '.claude-unified')
  MENU = File.join(Dir.home, '.claude-clash-menu')
  JOB = "gui/#{Process.uid}/local.claude-clash-menu"

  def patch(source, addition)
    if source.include?('// BEGIN Claude selfcheck menu v1')
      block = %r{// BEGIN Claude selfcheck menu v1.*?// END Claude selfcheck menu v1}m
      raise '菜单自检区块不完整或重复，未修改' unless source.scan(block).size == 1 && source.scan('// BEGIN Claude selfcheck menu v1').size == 1
      return source.sub(block, addition.strip)
    end
    tick = 'implementation: function () { updateStatus(); }'
    insertion = "    menu.addItem(menuItem('刷新状态', 'refresh:'));"
    action = "        'refresh:': {"
    raise '菜单版本不匹配，未修改文件' unless source.scan(tick).size == 2 && source.scan(insertion).size == 1 && source.scan(action).size == 1
    result = source.sub(tick, 'implementation: function () { updateStatus(); pollSelfcheck(); }')
    result = result.sub(action, "        'selfcheck:': {\n            types: ['void', ['id']],\n            implementation: function () { startSelfcheck(); }\n        },\n" + action)
    result = result.sub(insertion, "    checkItem = menuItem('一键自检（会关闭 Claude）', 'selfcheck:');\n    menu.addItem(checkItem);\n" + insertion)
    result = result.sub('startItem.enabled = ready;', 'startItem.enabled = ready && !checkRun;')
    addition + "\n" + result
  end

  def atomic(path, data, mode)
    Tempfile.create('.menu-update-', File.dirname(path)) do |file|
      file.binmode
      file.write(data)
      file.flush
      File.chmod(mode, file.path)
      File.rename(file.path, path)
    end
  end

  def run(*args)
    _, _, status = Open3.capture3(*args)
    raise '菜单命令执行失败' unless status.success?
  end

  def verify_environment
    raise '请在 Mac 当前桌面账号执行，不要用 sudo' unless RUBY_PLATFORM.include?('darwin') && Process.uid != 0
    raise '请先安装上一版自检更新包' unless File.file?(File.join(STATE, 'selfcheck.rb')) && File.file?(File.join(STATE, 'selfcheck-support.rb'))
    run('/bin/launchctl', 'print', JOB)
  end

  def validate(source)
    Tempfile.create(['menu-syntax-', '.js']) do |file|
      file.binmode
      file.write(source)
      file.flush
      Tempfile.create(['menu-compiled-', '.scpt']) do |compiled|
        run('/usr/bin/osacompile', '-l', 'JavaScript', '-o', compiled.path, file.path)
      end
    end
  end

  def restart
    ready = File.join(MENU, 'menu.ready')
    previous = File.read(ready).strip rescue ''
    run('/bin/launchctl', 'kickstart', '-k', JOB)
    60.times do
      current = File.read(ready).strip rescue ''
      if current.match?(/\A[1-9][0-9]*\z/) && current != previous
        begin
          Process.kill(0, current.to_i)
          return
        rescue Errno::ESRCH
          nil
        end
      end
      sleep 0.25
    end
    raise '菜单未通过启动检查'
  end

  def install
    verify_environment
    lock = File.open(File.join(STATE, 'selfcheck.lock'), File::RDWR | File::CREAT, 0600)
    raise '自检正在运行，未更新菜单' unless lock.flock(File::LOCK_EX | File::LOCK_NB)
    menu_path = File.join(MENU, 'menu.js')
    manifest_path = File.join(STATE, 'migration.json')
    [menu_path, manifest_path].each do |path|
      raise '目标缺失或为符号链接' unless File.file?(path) && !File.symlink?(path)
    end
    original = File.binread(menu_path)
    manifest_original = File.binread(manifest_path)
    # macOS Ruby 2.6 JSON may force the input string to UTF-8 in place.
    # Preserve the binary snapshot for concurrency checks and rollback.
    manifest = JSON.parse(manifest_original.dup)
    entry = manifest.fetch('menus').find { |item| item['path'] == menu_path }
    raise '菜单与迁移记录不一致，未修改文件' unless entry && entry['after'] == Digest::SHA256.hexdigest(original)
    updated = patch(original.dup.force_encoding('UTF-8'), File.read(File.join(__dir__, 'claude-selfcheck-menu.js'), encoding: 'UTF-8'))
    if updated.b == original
      puts '菜单已包含一键自检，无需重复更新。'
      return
    end
    validate(updated)
    entry['after'] = Digest::SHA256.hexdigest(updated)
    mode = File.stat(menu_path).mode & 0777
    manifest_mode = File.stat(manifest_path).mode & 0777
    raise '文件在检查期间发生变化' unless File.binread(menu_path) == original && File.binread(manifest_path) == manifest_original
    begin
      atomic(menu_path, updated, mode)
      atomic(manifest_path, JSON.generate(manifest), manifest_mode)
      restart
    rescue Exception
      atomic(menu_path, original, mode)
      atomic(manifest_path, manifest_original, manifest_mode)
      begin
        restart
      rescue StandardError
        warn '原菜单文件已恢复，但菜单重新启动失败。监控未被停止。'
      end
      raise
    end
    puts '菜单已加入“一键自检（会关闭 Claude）”。点击后自动检查、恢复代理并弹出结果，无需终端。'
  ensure
    lock&.close
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    SelfcheckMenuInstaller.new.install
  rescue StandardError => error
    warn(error.is_a?(RuntimeError) ? error.message : "菜单更新失败（#{error.class}）")
    exit 1
  end
end
