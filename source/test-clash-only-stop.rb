require File.join(Dir.home, '.claude-unified', 'selfcheck')
require_relative 'claude-health-confirmation'
class ClashPolicyFixture < EmbeddedClaudeGuard
  attr_accessor :gui,:core,:mode,:node
  def clash_process_status(name,_); name=='clash-verge' ? gui : core; end
  def controller(_,resource)
    return {'mode'=>mode} if resource=='/configs'
    {'proxies'=>{'GLOBAL'=>{'all'=>['group'],'now'=>'group'},'group'=>{'all'=>['exit'],'now'=>'exit'},'exit'=>{'type'=>node}}}
  end
end
g=ClashPolicyFixture.new
[[0,0,'global','Trojan',nil],[0,0,'rule','Direct',nil],[2,0,nil,nil,nil],[0,0,nil,nil,nil],[1,0,nil,nil,'clash_gui_absent'],[0,1,nil,nil,'clash_core_absent'],[0,0,'direct',nil,'clash_direct_mode'],[0,0,'global','Direct','clash_global_direct']].each do |gui,core,mode,node,expected|
  g.gui,g.core,g.mode,g.node=gui,core,mode,node
  raise 'classification' unless g.clash_stop_reason==expected
  pid=spawn('/bin/sleep','20')
  begin
    g.terminate({pid=>g.identity(pid)},tree:false)
    gone=Process.waitpid(pid,Process::WNOHANG)
    raise 'process policy' unless !!gone==!!expected
  ensure
    unless gone
      Process.kill('TERM',pid); Process.waitpid(pid)
    end
  end
end
puts 'PASS 8 Clash states and isolated child signal decisions'
