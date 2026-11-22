require 'tmpdir';require 'json';require 'time';require 'digest';require 'fileutils'
class ClaudeSelfcheck
  def initialize; @results={'本次项目'=>{'state'=>'未验证','detail'=>'no observation'}}; end
end
require_relative 'claude-selfcheck-evidence'
Dir.mktmpdir do |dir|
  ClaudeSelfcheck.const_set(:STATE,dir); FileUtils.mkdir_p(File.join(dir,'evidence'))
  File.write(File.join(dir,'claude-failure-grace.rb'),'policy')
  File.write(File.join(dir,'evidence','case.json'),'{}')
  m={'policy_sha256'=>Digest::SHA256.hexdigest('policy'),'tests'=>{'历史项目'=>{'state'=>'通过','detail'=>'limited','sources'=>{'case.json'=>Digest::SHA256.hexdigest('{}')}}}}
  File.write(File.join(dir,'evidence','manifest.json'),JSON.generate(m))
  p=ClaudeSelfcheck.new.selfcheck_payload
  raise 'scope mixing' unless p['results']['本次项目']['state']=='未验证' && p['historical_tests']['历史项目']['state']=='通过' && !p['summary']['all_network_paths_verified']
  File.write(File.join(dir,'evidence','case.json'),'changed')
  raise 'corrupt evidence passed' unless ClaudeSelfcheck.new.selfcheck_payload['historical_tests']['历史项目']['state']=='未验证'
end
puts 'PASS separate current/history scopes and reject altered evidence'
