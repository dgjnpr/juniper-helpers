#!/usr/bin/env tclsh8.5

package require tcltest
namespace import tcltest::*

if {$argc != 0} {
  foreach {action arg} $::argv {
    if {[string match "-*" $action]} {
      configure $action $arg
    } else {
      #not safe
      #$action $arg
    }
  }
}

configure -verbose p
runAllTests
exit
