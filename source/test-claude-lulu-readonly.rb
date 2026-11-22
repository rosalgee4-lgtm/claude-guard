require_relative 'claude-lulu-readonly'
def ref(n); {'CF$UID' => n}; end
archive = {'$archiver' => 'NSKeyedArchiver', '$top' => {'root' => ref(1)}, '$objects' => [
  '$null', {'NS.keys' => [ref(2)], 'NS.objects' => [ref(3)]}, 'app-id',
  {'NS.keys' => [ref(4)], 'NS.objects' => [ref(5)]}, 'rules', {'NS.objects' => [ref(6)]},
  {'$class' => ref(9), 'path' => ref(7), 'action' => 0, 'endpointAddr' => ref(8), 'pid' => ref(0)},
  '/Applications/Claude.app/Contents/MacOS/Claude', '*', {'$classname' => 'Rule'}]}
rules = LuLuReadOnly.rules(archive)
raise unless rules.size == 1 && rules[0]['action'] == 0 && rules[0]['pid'].nil?
raise if rules[0].key?('$class')
xml = REXML::Document.new('<plist><dict><key>allowLocalHost</key><true/><key>number</key><integer>3</integer></dict></plist>')
raise unless LuLuReadOnly.value(xml.root.elements[1]) == {'allowLocalHost'=>true,'number'=>3}
puts 'PASS XML primitives, keyed archive references, rule fields, class metadata excluded'
