#!/usr/bin/env tclsh

set auto_path [linsert $auto_path 0 "/home/fluong/code/juniper-helpers"]
package require test
package require tdom


init_logfile "/var/tmp/results"
#usage
if {$argc < 2} {
  puts "Usage: [info script] <router_address> <path_to_userpass_file>"
  exit
} 
set router [lindex $argv 0]
import_userpass [lindex $argv 1]
puts "r_username: '$juniperconnect::r_username'"

test::start "netconf connect"

  juniperconnect::connectssh $router "netconf"
  set hello [juniperconnect::get_hello $router]
  #parse xml and get session id
  set root [dom parse $hello]
  set node [$root selectNodes "hello/session-id/text()"]

  h2 "parse session id"
  print "root: $root"
  print "node: $node"
  set session_id [$node data]
  test::analyze_textblock "Netconf Hello Contents" $hello
  print " - Acquired Session ID: $session_id"
  test::assert $session_id
  test::end_analyze

  h2 "netconf software-information"
  set rpc [juniperconnect::build_rpc $router "get-software-information"]
  print $rpc
  set output [send_rpc $router $rpc "raw"]
  set doc [dom parse $output]
  print [$doc asXML]
  print "doc: $doc"
  set root [$doc documentElement]
  #deal with silly namespaces
  set space [$root getAttribute xmlns]
  print "root xmlns=$space"
  $doc selectNodesNamespaces [list j $space]
  set node [$root selectNodes "j:software-information/j:host-name/text()"]
  print "node: $node"
  print "Hostname: [$node data]"
  set node [$root selectNodes "j:software-information/j:package-information\[1]/j:comment/text()"]
  print "node: $node"
  print "Version: [$node data]"

  h2 "remove namespaces: software-information"
  set remove_namespaces $juniperconnect::xslt_remove_namespace
  $doc xslt $remove_namespaces cleandoc
  print [$cleandoc asXML]
  set node [$cleandoc selectNodes "rpc-reply/software-information/host-name/text()"]
  print "Hostname: [$node data]"
  set node [$cleandoc selectNodes "rpc-reply/software-information/package-information\[1]/comment/text()"]
  print "Version: [$node data]"

  h2 "craft a request for get-chassis-inventory/detail"
  set rpc [juniperconnect::build_rpc $router "get-chassis-inventory/detail"]
  print $rpc
  #send_rpc will strip xmlns tags when you don't specify raw style output
  set output [send_rpc $router $rpc]
  set doc [dom parse $output]
  print "doc: $doc"
  set root [$doc documentElement]
  print "root: $root"
  print [$root asXML]
  print "current node: [$root nodeName]"
  set child [$root childNodes]
  print "child node(s): [$child nodeName]"
  set node [$root selectNodes "child::*"]
  print "node: $node"
  set node [$doc selectNodes "rpc-reply/chassis-inventory/chassis/serial-number/text()"]
  print "node: $node"
  set chassis_serial [$node data]
  print ">>> chassis_serial: $chassis_serial"

  h2 "build two requests in one rpc"
  set path_statement_list "
    get-chassis-inventory
    get-interface-information
  "
  print [juniperconnect::build_rpc $router $path_statement_list "2"]


test::finish
