# encoding: UTF-8
require_relative 'claude-lulu-readonly'
require 'digest'

# Strict read-only preflight for the existing per-application firewall policy.
# Does not change any LuLu rule or system-wide networking preference.
class ClaudeLuLuGate
  PREFS = '/Library/Objective-See/LuLu/preferences.plist'
  RULES = '/Library/Objective-See/LuLu/rules.plist'
  APP = '/Applications/Claude.app/Contents/MacOS/Claude'
  CRASH = '/Applications/Claude.app/Contents/Frameworks/Electron Framework.framework/Helpers/chrome_crashpad_handler'
  LEAF = 'Developer ID Application: Anthropic PBC (Q6L2SF6YDW)'
  def self.targets
    [APP] + Dir.glob('/Applications/Claude.app/Contents/Frameworks/*.app/Contents/MacOS/*').select { |p| File.file?(p) } + [CRASH]
  end
  def self.validate_policy!(prefs, rules, identities)
    raise 'LuLu 必需设置不匹配，拒绝启动' unless prefs['disabled'] == false && prefs['allowLocalHost'] == false &&
      [false, 0].include?(prefs['useAllowList']) && (prefs['currentProfile'].nil? || prefs['currentProfile'].to_s.empty?)
    raise '存在全局或目录规则，无法确认 Claude 的有效规则优先级' if rules.any? { |r| r['path'] == '*' || r['path'].to_s.end_with?('/*') }
    identities.each do |path, identifier|
      key = "#{identifier}:#{LEAF}"
      selected = rules.select { |r| r['key'] == key || r['path'] == path }
      expected = path == CRASH ? [[0, '*', '*']] : [[0, '*', '*'], [1, '127.0.0.1', '17893']]
      actual = selected.map do |r|
        cs = r['csInfo'] || {}
        raise 'Claude 规则签名或持久性不匹配' unless r['key'] == key && cs['signatureIdentifier'] == identifier &&
          cs['signatureAuthorities'].is_a?(Array) && cs['signatureAuthorities'].first == LEAF &&
          cs['signatureSigner'] == 3 && cs['signatureStatus'] == 0 && [nil, false, 0].include?(r['isDisabled']) &&
          r['pid'].nil? && r['expiration'].nil? && [nil, 0].include?(r['isEndpointAddrRegex'])
        [r['action'], r['endpointAddr'], r['endpointPort']]
      end
      raise 'Claude 规则未严格限制到固定代理端口' unless actual.sort_by(&:to_s) == expected.sort_by(&:to_s)
    end
    true
  end
  def fingerprint
    [PREFS, RULES, *self.class.targets].map do |path|
      stat = File.stat(path)
      [path, stat.ino, stat.size, stat.mtime.to_f, stat.ctime.to_f]
    end
  end
  def verify!
    before = fingerprint
    version, _, version_status = Open3.capture3('/usr/libexec/PlistBuddy', '-c', 'Print :CFBundleShortVersionString', '/Applications/LuLu.app/Contents/Info.plist')
    raise 'LuLu 版本未验收，拒绝启动' unless version_status.success? && version.strip == '4.5.7'
    identities = self.class.targets.to_h do |path|
      _, _, verify = Open3.capture3('/usr/bin/codesign', '--verify', '--strict', path)
      _, detail, status = Open3.capture3('/usr/bin/codesign', '-dv', '--verbose=2', path)
      identifier = detail[/^Identifier=(.+)$/, 1]
      expected = path == APP ? 'com.anthropic.claudefordesktop' : (path == CRASH ? 'chrome_crashpad_handler' : 'com.anthropic.claudefordesktop.helper')
      raise 'Claude 可执行文件签名核验失败' unless verify.success? && status.success? && identifier == expected && detail.lines.map(&:strip).include?("Authority=#{LEAF}")
      [path, identifier]
    end
    self.class.validate_policy!(LuLuReadOnly.plist(PREFS), LuLuReadOnly.rules(LuLuReadOnly.plist(RULES)), identities)
    extensions, _, status = Open3.capture3('/usr/bin/systemextensionsctl', 'list')
    raise 'LuLu 扩展未启用' unless status.success? && extensions.lines.any? { |line| line.include?('com.objective-see.lulu.extension') && line.include?('[activated enabled]') }
    raise '核验期间规则或程序发生变化' unless before == fingerprint
    @fingerprint = before
    true
  end
  def unchanged!
    raise 'LuLu 规则、设置或 Claude 程序已变化，停止测试' unless @fingerprint && @fingerprint == fingerprint
    true
  end
end
