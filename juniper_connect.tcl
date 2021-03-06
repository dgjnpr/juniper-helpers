package provide JuniperConnect 1.0
package require textproc 1.0
package require Expect  5.43
package require Tcl     8.5
package require tdom  0.8.3
package require base64
package require yaml
package require homeless

namespace eval ::juniperconnect {
  namespace export connectssh disconnectssh send_textblock send_config build_rpc send_rpc grep_output import_userpass

  variable version 1.0
  variable session_array
  array unset session_array
  array set session_array {}

  variable basic_rp_prompt_regexp
  set basic_rp_prompt_regexp {[>#%]}

  variable rp_prompt_array
  set rp_prompt_array(Juniper) {([a-z]+@[a-zA-Z0-9\.\-\_]+[>#%])}

  variable expect_timeout_default 10
  variable expect_timeout $expect_timeout_default

  #options variable
  # - "outputlevel": 
  #     * normal (default) will allow expect sessions to be echoed to stdout
  #     * quiet will suppress expect session output 
  variable options 
  array unset options
  set options(initialized) 0

  #cli output
  variable output {}

  #netconf output
  variable nc_output {}

  #netconf hello message storage
  variable netconf_hello 
  array unset netconf_hello
  array set netconf_hello {}

  #netconf msgid storage
  variable netconf_msgid 1000

  #client capabilities
  variable ncclient_hello_out {
    <hello>
      <capabilities>
        <capability>urn:ietf:params:xml:ns:netconf:base:1.0</capability>
        <capability>urn:ietf:params:xml:ns:netconf:capability:candidate:1.0</capability>
        <capability>urn:ietf:params:xml:ns:netconf:capability:confirmed-commit:1.0</capability>
        <capability>urn:ietf:params:xml:ns:netconf:capability:validate:1.0</capability>
        <capability>urn:ietf:params:xml:ns:netconf:capability:url:1.0?protocol=http,ftp,file</capability>
        <capability>http://xml.juniper.net/netconf/junos/1.0</capability>
      </capabilities>
    </hello>
    ]]>]]>
  }

  #netconf end of message marker
  variable end_of_message {]]>]]>}

  #XSLT to strip namespaces
  # copied from https://github.com/Juniper/ncclient/blob/master/ncclient/xml_.py
  set xslt_remove_namespace [dom parse {
    <xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
      <xsl:output method="xml" indent="no"/>

      <!-- Stylesheet to remove all namespaces from a document -->
      <!-- NOTE: this will lead to attribute name clash, if an element contains
          two attributes with same local name but different namespace prefix -->
      <!-- Nodes that cannot have a namespace are copied as such -->

      <!-- template to copy elements -->
      <xsl:template match="*">
          <xsl:element name="{local-name()}">
              <xsl:apply-templates select="@*|node()"/>
          </xsl:element>
      </xsl:template>

      <!-- template to copy attributes -->
      <xsl:template match="@*">
          <xsl:attribute name="{local-name()}">
              <xsl:value-of select="."/>
          </xsl:attribute>
      </xsl:template>

      <!-- template to the rest of the nodes -->
      <xsl:template match="/|comment()|processing-instruction()|text()">
          <xsl:copy>
              <xsl:apply-templates/>
          </xsl:copy>
      </xsl:template>

    </xsl:stylesheet>
  }]

  #password database
  variable r_db
  array unset r_db
  array set r_db {}
  variable r_username {}
  variable r_password {}

  proc import_userpass {filepath} {
    #open a file containing username and password (each on one line) 
    #assign all of these to the array r_db with index = username, value = password
    #also, set the first two lines as r_username and r_password
    if {[file readable $filepath]} {
      catch {file attributes $filepath -permissions "00600"}
      set file_handle [open $filepath r]
      set file_contents [read $file_handle]
      close $file_handle
      set nlist_user_pass [split [string trim $file_contents] "\n"]
      foreach {user pass} $nlist_user_pass {
        set user [string trim $user]
        set pass [string trim $pass]
        set juniperconnect::r_db($user) [base64::encode $pass]
      }
      set juniperconnect::r_username [string trim [lindex $nlist_user_pass 0]]
      set juniperconnect::r_password [base64::encode [string trim [lindex $nlist_user_pass 1]]]
      set r_db(__lastuser) $juniperconnect::r_username
    } else {
      puts stderr "juniperconnect: ERROR: Userpass file '$filepath' cannot be opened for reading"
      exit 1
    }
  }

  proc change_rdb_user {username} {
    #change r_username and r_password based in the input variable 'username'
    #this will throw an exception if 'username' is not in r_db
    variable r_db
    variable r_username
    variable r_password
    set r_db(__lastuser) $r_username
    set r_username $username
    set r_password $rdb($username)
  }

  proc restore_lastuser {} {
    #revert r_username and r_password
    # convenience proc for temporary login changes
    variable r_db
    return [change_rdb_user $r_db(__lastuser)]
  }

  proc session_exists {address} {
    #convenience proc to see if a session has already been opened for an address
    set result 0
    if {[info exists juniperconnect::session_array($address)]} {
      set result 1
    }
    return $result
  }

  proc connectssh {address {style "cli"} {username "-1"} {password "-1"}} {
    #a connect needs to be performed before you can send any commands to the router
    # style will be used to handle cli or netconf
    variable session_array
    variable rp_prompt_array
    variable end_of_message
    variable options
    if {!$options(initialized)} {
      #read in config.yml from same folder as juniperconnect
      set jcpath [lindex [package ifneeded JuniperConnect $juniperconnect::version] end]
      set jcpath [file dir $jcpath]
      set config_dict [yaml::yaml2dict [read_file "${jcpath}/config.yml"]]
      dict for {key value} $config_dict {
        if {![info exists options($key)]} {
          set options($key) $value
        }
      }
      set options(initialized) 1
    }
    if {$options(outputlevel) eq "quiet"} {
      log_user 0
    }
    #parray options
    set prompt $rp_prompt_array(Juniper)
    set success 0
    set send_slow {1 .1}
    set retries 10
    set ssh_mismatch_msg "ERROR: FATAL: Mismatched SSH host key for $address"
    if {$username == "-1"} {
      set username $juniperconnect::r_username
    }
    if {$password == "-1"} {
      set password $juniperconnect::r_password
    } else {
      set password [base64::encode $password]
    }
    while {$success==0 && $retries>0} {
      switch -- $style {
        "cli" {
          set catch_result [ catch {spawn ssh $username@$address} reason ]
        }
        "netconf" {
          log_user 0
          set catch_result [ catch {spawn ssh $username@$address -p 830 -s "netconf"} reason ]
        }
        default {
          return -code error "[info proc]: ERROR: unexpected value for style: '$style'"
        }
      }
      set netconf_tags {}
      if {$catch_result>0} {
        return -code error "juniperconnect::connectssh $username@$address: failed to connect: $reason\n"
      }
      set timeout $juniperconnect::options(connect_timeout_sec)
      send "\n"
      expect {
        $end_of_message {
          if {$style eq "netconf"} {
            append netconf_tags $expect_out(buffer)
            set success 1
          } else {
            exp_continue
          }
        }
        -re "<.*>" {
          if {$style eq "netconf"} {
            append netconf_tags $expect_out(buffer)
          }
          exp_continue
        }
        -re $prompt {
          if {$style eq "cli"} {
            set success 1
          } else {
            exp_continue
          }
        }
        "no hostkey alg" {
          return -code error "ERROR: juniperconnect::connectssh: no hostkey alg"
        }
        "Host key verification failed." {
          return -code error $ssh_mismatch_msg
        }
        "REMOTE HOST IDENTIFICATION HAS CHANGED" {
          return -code error $ssh_mismatch_msg
        }
        "Could not resolve hostname"              {
           puts "juniperconnect::connectssh: $expect_out(0,string)"
           exp_close; exp_wait
           set retries -2
           break
        }
        "Permission denied, please try again" {
           puts "juniperconnect::connectssh: $expect_out(0,string)"
           exp_close; exp_wait
           set retries -1
           break
        }
        "% Bad passwords" {
           puts "juniperconnect::connectssh: $expect_out(0,string)"
           exp_close; exp_wait
           set retries -1
           break
        }
        "can't be established." {
          expect {(yes/no)?} {
            send "yes\r"
          }
          exp_continue
        }
        -re "Connection (refused|closed)" {
          puts "juniperconnect::connectssh: $expect_out(0,string)"
          exp_close; exp_wait
          after 2000
        }
        -re "(% Login invalid|Login incorrect|% Authentication failed.|ermission denied|Password Incorrect)" { 
          exp_continue
        }
        -re "( JUNOS )" {
          exp_continue
        }
        -re "(Username: |login: )" {
          send -s "$username\r"
          exp_continue
        }
        -re "($address's password:|Password:|Telnet password:)" {
          send -s "[base64::decode $password]\r"
          exp_continue
        }
        timeout {
          return -code error "juniperconnect::connectssh: TIMEOUT: timed out during login into $address"
        }
      }
      after 1000
      incr retries -1
    }
    if {$retries<1} {
      switch -- $retries {
        "0"       {set err_string "'Connection refused'" }
        "-1"      {set err_string "'Bad passwords'" }
        "-2"      {set err_string "'Bad Hostname'" }
      }
      return -code error "juniperconnect::connectssh: Error count exceeded for error $err_string error"
    }
    set timeout [timeout]
    switch -- $style {
      "cli" {
        if {$options(outputlevel) ne "quiet" } {
          puts "\njuniperconnect::connectssh $address success"
        }
        set session_array($address) $spawn_id
        send "set cli screen-length 0\n"
        expect -re $prompt {send "set cli screen-width 0\n"}
        expect -re $prompt {send "\n"}
        expect -re $prompt {}
        #absorb final prompt
      }
      "netconf" {
        #parse or store netconf_tags
        set netconf_tags [string trim [lindex [split $netconf_tags "\]"] 0]]
        set juniperconnect::netconf_hello($address) $netconf_tags
        #send our hello
        variable ncclient_hello_out
        send $ncclient_hello_out
        expect $end_of_message {}
        #session array storage for netconf... separate one?
        set session_array(nc:$address) $spawn_id
      }
      default {
        return -code error "[info proc]: ERROR: unexpected value for style: '$style'"
      }
    }
    log_user 1
    return $spawn_id
  }

  proc disconnectssh {address {style "cli"}} {
    variable session_array
    variable rp_prompt_array
    set prompt $rp_prompt_array(Juniper)
    switch -- $style {
      "netconf" {
        set address "nc:$address"
      }
    }
    set spawn_id $session_array($address)
    if {$spawn_id ne ""} {
      if {[string match "nc:*" $address]} {
        #close NETCONF session
        set address [lindex [split $address ":"] end]
        send_rpc $address [build_rpc "close-session"]
      } else {
        #CLI: send exit
        set timeout 1
        send "exit\n"
        expect -re $prompt {}
      }
      puts "\njuniperconnect::disconnect"
      #close/wait for expect session
      catch {exp_close}
      catch {exp_wait}
      #clear the value stored in the session array
      set session_array($address) ""
    }
  }

  proc set_timeout {timeout_value_sec} {
    #set the expect_timeout value
    variable expect_timeout
    set expect_timeout $timeout_value_sec
  }

  proc restore_timeout {} {
    #revert the expect_timeout value to default
    variable expect_timeout
    variable expect_timeout_default
    #we get the timeout from config.yml:timeout_sec
    set expect_timeout $juniperconnect::options(timeout_sec)
  }

  proc timeout {} {
    #get the expect_timeout value
    variable expect_timeout
    return $expect_timeout
  }

  #======================
  #CLI EXTERNAL
  #======================

  proc send_textblock {address commands_textblock} {
    set textblock [string trim $commands_textblock]
    set commands_list [textproc::nsplit $textblock]
    return [send_commands $address $commands_list]
  }

  proc send_commands {address commands_list} {
    #send a list of commands to the router expecting prompt between each
    variable rp_prompt_array
    set prompt $rp_prompt_array(Juniper)
    set procname "send_commands"

    #initialize return output
    variable output
    set output {}

    set timeout [timeout]
    set spawn_id $juniperconnect::session_array($address)

    #suppress output if outputlevel is set to quiet
    variable options
    if {$options(outputlevel) eq "quiet"} {
      log_user 0
    }

    #send initial carriage-return then expect first prompt
    _verify_initial_send_prompt $address
    #loop through commands list
    _send_commands_loop $address $commands_list
    set output [string trimright [textproc::nrange $output 0 end-1]]
    set output [join [split $output "\r"] ""]
    log_user 1
    return $output
  }

  proc send_config {address config_textblock {merge_set_override "cli"} {confirmed "0"}} {
    #send a list of commands to the router expecting prompt between each
    set prompt $juniperconnect::rp_prompt_array(Juniper)
    set procname "send_config"

    #initialize return output
    variable output
    set output {}

    set timeout [timeout]
    set spawn_id $juniperconnect::session_array($address)

    #suppress output if outputlevel is set to quiet
    variable options
    if {$options(outputlevel) eq "quiet"} {
      log_user 0
    }

    #send initial carriage-return then expect first prompt
    _verify_initial_send_prompt $address
    #enter configuration mode
    _enter_configuration_mode $address
    #initiate load
    set config_textblock [string trim $config_textblock]
    switch -- $merge_set_override {
      "patch" -
      "override" -
      "set" -
      "merge" {
        #load set/merge/patch/override terminal
        send "load $merge_set_override terminal\r"
        set timeout $juniperconnect::options(load_timeout_sec)
        expect {
          -re "\[a-zA-Z ]+" {}
          timeout {
            return -code error "$procname: TIMEOUT($timeout) waiting for 'load start'"
          }
        }
        #loop through config textblock
        foreach line [nsplit $config_textblock] {
          set line [string trimleft $line]
          #insert delay
          after 10
          expect -re ".*(\r|\n)" {
            append output $expect_out(buffer)
          }
          send "$line\r"
        }
        #send CTRL-d
        send "\004"
        expect {
          "load complete" {
            append output [string trimleft $expect_out(buffer)]
            exp_continue
          }
          -re $prompt {
            append output [string trimleft $expect_out(buffer)]
            #absorb final prompt
          }
          timeout {
            return -code error "$procname: TIMEOUT($timeout) waiting for 'load complete'"
          }
        }
        set timeout [timeout]
      }
      "cli" {
        #default mode... act like send_commands
        set commands_list [nsplit $config_textblock]
        _send_commands_loop $address $commands_list
      }
      default {
        return -code error "ERROR: unexpected value for merge_set_override: $merge_set_override"
      }
    }
    _commit_and_quit_config $address $confirmed
    set output [string trimright [textproc::nrange $output 0 end-1]]
    set output [join [split $output "\r"] ""]
    log_user 1
  }

  #======================
  #CLI Internal
  #======================

  proc _verify_initial_send_prompt {address} {
    variable output
    set spawn_id $juniperconnect::session_array($address)
    set timeout [timeout]
    set prompt $juniperconnect::rp_prompt_array(Juniper)
    send "\n"
    expect {
      -re $prompt {
        #absorb final prompt
      }
      timeout {
        return -code error "ERROR: $procname: TIMEOUT waiting for initial prompt"
      }
    }
  }

  proc _enter_configuration_mode {address {loose "0"}} {
    variable output
    set spawn_id $juniperconnect::session_array($address)
    set timeout [timeout]
    set prompt $juniperconnect::rp_prompt_array(Juniper)
    send "configure exclusive\r"
    expect {
      "commit confirmed will be rolled back in" {
        if {$loose == 0} {
          return -code error "ERROR: Juniper router $router has pending rollback"
        } else {
          exp_continue
        }
      }
      "The configuration has been changed but not committed" {
        if {$loose == 0} {
          return -code error "ERROR: Juniper router $router has uncommited changes - exitting"
        } else {
          exp_continue
        }
      }
      "Entering configuration mode" {
        append output [string trimleft $expect_out(buffer)]
      }
    }
    expect {
      -re $prompt {
        append output [string trimleft $expect_out(buffer)]
        #absorb final prompt
      }
      timeout {
        return -code error "ERROR: $procname: TIMEOUT waiting for initial prompt"
      }
    }
  }

  proc _prep_for_next_send {address} {
    #absorb final prompt... new send directives start with sending a newline
    set spawn_id $juniperconnect::session_array($address)
    set timeout 1
    set prompt $juniperconnect::rp_prompt_array(Juniper)
    log_user 0
    expect {
      -re $prompt {
      }
    }
    log_user 1
  }

  proc _send_commands_loop {address commands_list} {
    variable output
    set procname "_send_commands_loop"
    set spawn_id $juniperconnect::session_array($address)
    set timeout [timeout]
    set mode "cli"
    set prompt $juniperconnect::rp_prompt_array(Juniper)
    foreach this_command $commands_list {
      #determine if we need to adjust the prompt based on mode switches
      # need a simpler prompt for shell
      switch -- $mode {
        "cli" {
          #if we are in cli mode and we see 'start shell', switch mode/prompt
          switch -- $this_command {
            "start shell" {
              set mode "shell"
              set prompt $juniperconnect::basic_rp_prompt_regexp
            }
          }
        }
        "shell" {
          #if we are in shell mode and we see 'exit', switch back to cli
          switch -- $this_command {
            "exit" {
              set mode "cli"
              set prompt $juniperconnect::rp_prompt_array(Juniper)
            }
          }
        }
      }
      #send command
      send "$this_command\n"
      set output_received 0
      #loop and look for for prompt regexp
      expect {
        -re $prompt {
          #got prompt - exit condition for expect-loop
          append output $expect_out(buffer)
          if {!$output_received} {
            exp_continue
          }
        }
        -re ".*(\r|\n)" {
          #this resets the timeout timer using newline-continues
          set output_received 1
          append output $expect_out(buffer)
          exp_continue
        }
        timeout {
          puts "$procname: TIMEOUT($timeout) waiting for prompt"
          #no crash because of the for-loop this sucker may just keep going, but it's possible the cli has siezed up
        }
      }
    }
    #final prompt is absorbed
  }

  proc _commit_and_quit_config {address {confirmed "0"}} {
    variable output
    set procname "_commit_and_quit_config"
    set prompt $juniperconnect::rp_prompt_array(Juniper)
    set spawn_id $juniperconnect::session_array($address)
    set timeout $juniperconnect::options(commit_timeout_sec)
    send "show | compare\r"
    expect {
      -re $prompt {}
      timeout {
        return -code error "ERROR: $procname: timeout waiting for initial prompt"
      }
    }
    #send commit
    if {![string match -nocase "*confirm*" $confirmed]} {
      send "commit and-quit\r"
    } else {
      set minutes $juniperconnect::options(commit_confirmed_timeout_min)
      send "commit confirmed $minutes and-quit\r"
    }
    #process commit - if we do not get commit complete, rollback and throw an exception
    set commit_complete 0
    expect {
      "commit complete" {
        append output $expect_out(buffer)
        set commit_complete 1
        exp_continue
      }
      "error: configuration check-out failed" {
        return -code error "ERROR: Juniper configuration commit failed" 
      }
      {re0:} {
        append output $expect_out(buffer)
        exp_continue
      }
      {re1:} {
        append output $expect_out(buffer)
        exp_continue
      }
      "configuration check succeeds" {
        append output $expect_out(buffer)
        exp_continue
      }
      -re $prompt {
        append output $expect_out(buffer)
        if {!$commit_complete} {
          #send rollback and quit-configuration
          set commands_list [list "rollback" "quit config"]
          _send_commands_loop $address $commands_list
          #throw exception
          return -code error "ERROR: $procname: got prompt before seeing 'commit complete'"
        }
        #absorb final prompt
      }
      timeout {
        return -code error "EXPECT TIMEOUT($timeout): $procname: waiting for final prompt"
      }
    }
    #if commit confirmed, send second commit
    if {[string match -nocase "*confirm*" $confirmed]} {
      #disconnect
      disconnectssh $address
      #reconnect
      set spawn_id [connectssh $address]
      #enter configuration mode
      _enter_configuration_mode $address "loose"
      _commit_and_quit_config $address
    }
    set timeout [timeout]
  }

  #======================
  #NETCONF SPECIFIC
  #======================

  proc build_rpc {path_statement_textblock {indent "none"}} {
    variable netconf_msgid
    set this_msgid $netconf_msgid
    incr netconf_msgid
    set rpc [dom createDocument "rpc"]
    set root [$rpc documentElement]
    $root setAttribute "message-id" "$this_msgid [clock format [clock seconds]]"
    foreach path_statement [nsplit $path_statement_textblock] {
      set path_statement [string trim $path_statement]
      set current_node $root
      foreach element_list [split $path_statement "/"] {
        foreach element [split $element_list ","] {
          #probably will need to add logic to handle attributes and text
          if {[string match "*=*" $element]} {
            lassign [split $element "="] tag value
            set value [string trim $value {'\"}]
            #need to also create a text node and attach it
            set new_node [$rpc createElement $tag]
            $current_node appendChild $new_node
            set text_node [$rpc createTextNode $value]
            $new_node appendChild $text_node
          } else {
            set new_node [$rpc createElement $element]
            $current_node appendChild $new_node
          }
        }
        set current_node $new_node
      }
    }
    variable end_of_message
    #set result "[$root asXML -indent none]$end_of_message"
    set result [$root asXML -indent $indent]
    return $result
  }

  proc add_ascii_format_to_rpc {rpc_request {indent "none"}} {
    set doc [dom parse $rpc_request]
    set rpc [$doc firstChild]
    set node [$rpc firstChild]
    $node setAttribute format "ascii"
    set result [$doc asXML -indent $indent]
  }

  proc send_rpc {address rpc {style "strip"}} {
    #send netconf rpc to the router and return the nc_output
    set procname "send_rpc"

    #initialize return nc_output
    variable nc_output
    set nc_output {}

    set timeout [timeout]
    set mode "netconf"

    variable session_array
    set spawn_id $session_array(nc:$address)

    #suppress output if outputlevel is set to quiet
    variable options
    if {$options(outputlevel) eq "quiet"} {
      log_user 0
    }

    variable end_of_message

    #send rpc and end sequence
    set send_slow {1 .1}
    send [string trim $rpc]
    send $end_of_message
    send "\n"
    #clear echo for outgoing rpc
    expect $end_of_message {}

    #loop through return nc_output until end_of_message received
    expect {
      $end_of_message {
        #got end_of_message - exit condition for expect-loop
        append nc_output $expect_out(buffer)
      }
      -re "<.*>" {
        #this resets the timeout timer when we find any tag/element
        append nc_output $expect_out(buffer)
        exp_continue
      }
      timeout {
        puts "$procname: TIMEOUT waiting for end-of-message marker"
        #because of the for-loop this sucker may just keep going, but it's possible the cli has siezed up
      }
    }
    #set nc_output [string trim [lindex [split $nc_output "\]"] 0]]
    set nc_output [nrange $nc_output 1 end-1]
    set doc [dom parse $nc_output]
    $doc xslt $juniperconnect::xslt_remove_namespace cleandoc
    log_user 1
    switch -- $style {
      default -
      "strip" {
        return [$cleandoc asXML]
      }
      "raw" {
        return $nc_output
      }
      "ascii" {
        set rpc_ascii [add_ascii_format_to_rpc $rpc]
        set ascii_output [send_rpc $address $rpc_ascii]
        set ascii_doc [dom parse $ascii_output]
        set output [$ascii_doc selectNodes "//output"]
        set rpc_reply [$cleandoc firstChild]
        $rpc_reply appendChild $output 
        return [$cleandoc asXML]
      }
    }
  }

  proc grep_output {expression} {
    return [textproc::linematch $expression $juniperconnect::output]
  }

  proc get_hello {address} {
    set result {}
    variable netconf_hello
    set index [lsearch [array names netconf_hello] $address] 
    if {$index != -1} {
      set result $netconf_hello($address)
    }
    return $result
  }

  proc quiet {} {
    variable options
    set options(outputlevel) "quiet"
  }

}

namespace import juniperconnect::*

