require_relative 'claude-lulu-gate'
leaf=ClaudeLuLuGate::LEAF
path=ClaudeLuLuGate::APP
id='com.anthropic.claudefordesktop'
prefs={'disabled'=>false,'allowLocalHost'=>false,'useAllowList'=>0}
rules=[[0,'*','*'],[1,'127.0.0.1','17893']].map do |action,host,port|
  {'path'=>path,'key'=>"#{id}:#{leaf}",'action'=>action,'endpointAddr'=>host,'endpointPort'=>port,
   'csInfo'=>{'signatureIdentifier'=>id,'signatureAuthorities'=>[leaf],'signatureSigner'=>3,'signatureStatus'=>0}}
end
raise unless ClaudeLuLuGate.validate_policy!(prefs,rules,{path=>id})
changes=[
  ->(p,r){p['disabled']=true}, ->(p,r){p['allowLocalHost']=true}, ->(p,r){p['useAllowList']=1},
  ->(p,r){p['currentProfile']='other'}, ->(p,r){r[1]['endpointPort']='*'},
  ->(p,r){r[1]['endpointAddr']='*'}, ->(p,r){r[0]['isDisabled']=true},
  ->(p,r){r[0]['pid']=123}, ->(p,r){r[0]['expiration']={}},
  ->(p,r){r[0]['csInfo']['signatureAuthorities']=['wrong leaf']},
  ->(p,r){r[0]['csInfo']['signatureStatus']=1}, ->(p,r){r.pop},
  ->(p,r){r << r.first.dup.merge('path'=>'*')},
  ->(p,r){r << r.first.dup.merge('path'=>'/Applications/*')}
]
changes.each_with_index do |change,index|
  p,r=Marshal.load(Marshal.dump([prefs,rules])); change.call(p,r)
  rejected=false
  begin; ClaudeLuLuGate.validate_policy!(p,r,{path=>id}); rescue RuntimeError; rejected=true; end
  raise "unsafe policy accepted #{index}" unless rejected
end
puts 'PASS exact allow/block policy and 14 unsafe policy rejection cases'
