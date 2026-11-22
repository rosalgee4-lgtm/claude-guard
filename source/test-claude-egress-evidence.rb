require_relative 'claude-local-intercept'
identity={path:'/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper',stamp:'birth'}
resolver=->(pid){pid==91 ? identity : nil}
targets={'1.1.1.1:443'=>'IPv4','[2606:4700:4700::1111]:443'=>'IPv6','2606:4700:4700::1111.443'=>'IPv6'}
def feed_chain(parser,endpoint)
  messages=["remote endpoint: #{endpoint} / url: (null)",'found matching rule for 91/Claude Helper: RULE: pid: all, action: 0, disabled: 0,','setting verdict to: BLOCK','verdict: block']
  messages.each_with_index do |m,i|
    parser.feed({'subsystem'=>'com.objective-see.lulu','processImagePath'=>'/com.objective-see.lulu.extension','processID'=>5,'threadID'=>6,'eventMessage'=>m},i*0.1)
  end
end
targets.each do |endpoint,family|
  p=ClaudeLuLuEvidence.new(443,resolver,endpoints:targets)
  feed_chain(p,endpoint)
  raise 'valid public endpoint missed' unless p.blocked[[identity[:path],family]]
  record=p.verdicts.last
  raise 'endpoint/PID identity attribution lost' unless record && record[:pid]==91 && record[:endpoint]==endpoint && record[:identity]==identity && record[:verdict]=='block'
end
['11.1.1.1:443','1.1.1.1:4430','1.1.1.1:80','2606:4700:4700::1112.443','127.0.0.1:443'].each do |endpoint|
  p=ClaudeLuLuEvidence.new(443,resolver,endpoints:targets)
  feed_chain(p,endpoint)
  raise 'unconfigured endpoint accepted' unless p.blocked.empty?
  raise 'unconfigured endpoint recorded' unless p.verdicts.empty?
end
puts 'PASS exact configured public IPv4/IPv6 targets and near-match rejection'
p=ClaudeLuLuEvidence.new(53,resolver,endpoints:{'114.114.114.114:53'=>'IPv4'})
messages=['remote endpoint: 114.114.114.114:53 / url: (null)',
  'found matching rule for 91/Claude Helper: RULE: pid: all, action: 0, disabled: 0,',
  'setting verdict to: BLOCK',
  "...but 'allow DNS traffic' is set and this is resolver DNS on the app's behalf, so allowing",
  'verdict: allow']
messages.each_with_index do |m,i|
  p.feed({'subsystem'=>'com.objective-see.lulu','processImagePath'=>'/com.objective-see.lulu.extension','processID'=>5,'threadID'=>6,'eventMessage'=>m},i*0.1)
end
raise 'DNS exception incorrectly counted as block' unless p.blocked.empty? && p.allowed.size==1
raise 'DNS exception attribution missing' unless p.verdicts.last[:reason]=='system_resolver_dns_exception'
puts 'PASS final allow overrides block stage; system resolver DNS exception retained'
