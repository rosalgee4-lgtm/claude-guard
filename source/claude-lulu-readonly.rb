# encoding: UTF-8
# Read-only inventory. Never reads Claude credentials or changes LuLu preferences.
require 'open3'
require 'rexml/document'
require 'json'
module LuLuReadOnly
  def self.value(element)
    case element.name
    when 'dict'
      element.elements.to_a.each_slice(2).to_h { |key, val| [key.text.to_s, value(val)] }
    when 'array' then element.elements.map { |child| value(child) }
    when 'integer' then Integer(element.text)
    when 'real' then Float(element.text)
    when 'true' then true
    when 'false' then false
    when 'string', 'date' then element.text.to_s
    else nil
    end
  end
  def self.plist(path)
    xml, _, status = Open3.capture3('/usr/bin/plutil', '-convert', 'xml1', '-o', '-', path)
    raise '无法读取 plist（权限不足或格式不支持）' unless status.success?
    value(REXML::Document.new(xml).root.elements[1])
  end
  def self.decode(item, objects, depth = 0)
    raise '存档嵌套超限' if depth > 60
    if item.is_a?(Hash)
      return decode(objects.fetch(item['CF$UID']), objects, depth + 1) if item.keys == ['CF$UID']
      if item.key?('NS.keys')
        keys = item.fetch('NS.keys').map { |key| decode(key, objects, depth + 1) }
        vals = item.fetch('NS.objects').map { |val| decode(val, objects, depth + 1) }
        return keys.zip(vals).to_h
      end
      return decode(item['NS.objects'], objects, depth + 1) if item.key?('NS.objects')
      return item.reject { |key, _| key == '$class' }.transform_values { |val| decode(val, objects, depth + 1) }
    end
    return item.map { |val| decode(val, objects, depth + 1) } if item.is_a?(Array)
    item == '$null' ? nil : item
  end
  def self.rules(archive)
    raise '不是预期的 LuLu 规则存档' unless archive['$archiver'] == 'NSKeyedArchiver'
    root = decode(archive.fetch('$top').fetch('root'), archive.fetch('$objects'))
    raise '规则根对象不是字典' unless root.is_a?(Hash)
    root.values.flat_map { |group| group.is_a?(Hash) ? Array(group['rules']) : [] }.select { |rule| rule.is_a?(Hash) }
  end
  def self.run
    puts '只读清单；不是实际拦截测试，不会修改或重启任何服务。'
    begin
      prefs = plist('/Library/Objective-See/LuLu/preferences.plist')
      selected = %w[disabled allowLocalHost useAllowList allowDNS passiveMode passiveModeAction currentProfile].to_h { |key| [key, prefs.fetch(key, '未设置')] }
      # Profile names can be user-defined; do not print their contents.
      selected['currentProfile'] = prefs.key?('currentProfile') ? '已设置' : '未设置'
      puts 'LuLu 设置: ' + JSON.generate(selected)
    rescue StandardError
      puts 'LuLu 设置: 未读取成功（需检查读取权限/格式）'
    end
    paths = ['/Applications/Claude.app/Contents/MacOS/Claude']
    paths += Dir.glob('/Applications/Claude.app/Contents/Frameworks/*.app/Contents/MacOS/*')
    paths += ['/Applications/Claude.app/Contents/Frameworks/Electron Framework.framework/Helpers/chrome_crashpad_handler']
    paths += ENV.fetch('PATH', '').split(':').map { |dir| File.join(dir, 'claude') }
    paths += [File.join(Dir.home, '.local/bin/claude'), File.join(Dir.home, '.claude/local/claude')]
    paths = paths.select { |path| File.file?(path) && File.executable?(path) }.map { |path| File.realpath(path) }.uniq
    identities = paths.map do |path|
      _, text, status = Open3.capture3('/usr/bin/codesign', '-dv', '--verbose=2', path)
      identifier = text[/^Identifier=(.+)$/, 1]
      puts JSON.generate('executable' => path, 'signatureIdentifier' => identifier, 'codesignReadable' => status.success?)
      identifier
    end.compact
    begin
      list = rules(plist('/Library/Objective-See/LuLu/rules.plist'))
      relevant = list.select do |r|
        path = r['path'].to_s
        path == '*' || path.end_with?('/*') || paths.include?(path) || path.include?('/Claude.app/') ||
          identities.include?(r.dig('csInfo', 'signatureIdentifier')) || File.basename(path).downcase == 'claude'
      end
      puts "相关及全局/目录规则: #{relevant.size} 条（仅静态清单，不代表已加载或匹配成功）"
      relevant.each do |r|
        addr = r['endpointAddr'].to_s
        port = r['endpointPort'].to_s
        puts JSON.generate('path' => r['path'], 'action' => r['action'], 'disabled' => r['isDisabled'],
          'addressClass' => %w[* 127.0.0.1 ::1 localhost].include?(addr) ? addr : '其他目标（已隐藏）',
          'portClass' => %w[* 17893].include?(port) ? port : '其他端口',
          'scope' => r['scope'], 'temporary' => !r['pid'].nil? || !r['expiration'].nil?,
          'signatureIdentifier' => r.dig('csInfo', 'signatureIdentifier'))
      end
    rescue StandardError
      puts 'LuLu 规则: 未读取成功（权限不足或存档结构不匹配）；未做任何修改。'
    end
  end
end
LuLuReadOnly.run if $PROGRAM_NAME == __FILE__
