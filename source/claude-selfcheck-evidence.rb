require 'digest'
module ClaudeSelfcheckEvidence
  def selfcheck_payload
    historical={}
    manifest_path=File.join(self.class::STATE,'evidence','manifest.json')
    begin
      manifest=JSON.parse(File.read(manifest_path))
      manifest.fetch('tests').each do |name,entry|
        valid=entry.fetch('sources').all? do |file,hash|
          path=File.join(self.class::STATE,'evidence',File.basename(file))
          File.file?(path) && Digest::SHA256.file(path).hexdigest==hash
        end
        valid &&= manifest.fetch('policy_sha256')==Digest::SHA256.file(File.join(self.class::STATE,'claude-failure-grace.rb')).hexdigest
        valid &&= entry.fetch('implementation_sha256',{}).all? { |file,hash| path=File.join(self.class::STATE,File.basename(file)); File.file?(path) && Digest::SHA256.file(path).hexdigest==hash }
        historical[name]=entry.reject{|k,_|k=='sources'}.merge('scope'=>'历史专项测试，本次未重跑','sources'=>entry['sources'].keys,'state'=>valid ? entry['state'] : '未验证')
        historical[name]['detail']='历史证据缺失、被修改或当前策略已变化，需重新核对。' unless valid
      end
    rescue StandardError
      historical['历史专项测试证据']={'state'=>'未验证','scope'=>'历史证据','detail'=>'未能完整读取已归档证据。'}
    end
    current=@results.transform_values{|v|v.merge('scope'=>'本次菜单自检')}
    summary={'current_counts'=>current.values.group_by{|v|v['state']}.transform_values(&:size),
      'historical_counts'=>historical.values.group_by{|v|v['state']}.transform_values(&:size),
      'all_network_paths_verified'=>false,
      'note'=>'通过仅适用于项目所述范围；历史测试不是本次复测，DNS代查例外未修复。'}
    puts "\n历史专项测试（本次未重跑）："
    historical.each{|name,v| puts "[#{v['state']}] #{name}：#{v['detail']}"}
    puts "\n本次结果统计：#{JSON.generate(summary['current_counts'])}；存在未验证项目，不代表全部验收。"
    {'time'=>Time.now.utc.iso8601,'results'=>current,'historical_tests'=>historical,'summary'=>summary}
  end
end
ClaudeSelfcheck.prepend(ClaudeSelfcheckEvidence)
