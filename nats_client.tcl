# Copyright 2020 Petro Kazmirchuk https://github.com/Kazmirchuk

# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

package require struct::list
package require cmdline
package require uri
package require json
package require json::write
package require oo::util
package require tcl::chan::random
package require tcl::randomseed

# TODO: how to restore subscriptions when reconnected to another server?

namespace eval ::nats {
    # improvised enum
    variable status_closed 0
    variable status_connecting 1
    variable status_connected 2

    # TODO: SkipServerVerification
    set option_syntax {
        { servers.list ""                   "URLs of NATS servers"}
        { error_cb.arg ""                   "Invoked when the connection is closed after all reconnect attempts failed"}
        { disconnected_cb.arg ""            "Invoked when the connection is lost"}
        { reconnected_cb.arg ""             "Invoked when the connection is restored"}
        { token_cb.arg ""                   "Invoked to generate a token whenever the client needs one"}
        { name.arg ""                       "Client name sent to NATS server when connecting"}
        { pedantic.boolean false            "Pedantic protocol mode. If true some extra checks will be performed by the server"}
        { verbose.boolean false             "If true, every protocol message is echoed by the server with +OK" }
        { allow_reconnect.boolean true      "Whether the client library should try to reconnect" }
        { connect_timeout.integer 2000      "Connection timeout (ms)"}
        { reconnect_time_wait.integer 2000  "How long to wait between two reconnect attempts from the same server (ms)"}
        { max_reconnect_attempts.integer 60 "Maximum number of reconnect attempts"}
        { ping_interval.integer 120000      "Interval (ms) to send PING messages to NATS server"}
        { max_outstanding_pings.integer 2   "Max number of PINGs without a reply from NATS before closing the connection"}
        { flush_interval.integer 500        "Interval (ms) to flush sent messages"}
        { randomize.boolean true            "Shuffle the list of NATS servers before connecting"}
        { echo.boolean true                 "If true, messages from this connection will be sent by the server back if the connection has matching subscriptions"}
        { tls.arg ""}
        { user.arg ""}
        { password.arg ""}
        { token.arg ""}
        { signature_cb.arg ""}
        { user_jwt_cb.arg ""}
        { user_credentials.arg ""}
        { nkeys_seed.arg ""}
        { debug.boolean false}
    }
    
    oo::class create connection {
        variable config sock subscriptionCounter subscriptions serverInfo serverPool currentServerIdx subjectRegex writing_coro reading_coro
        variable connect_timer
        # all outgoing messages are put in this list before being flushed to the socket, so that even when we are reconnecting, messages can still be sent
        variable outBuffer
        variable randomChan
        variable syncResponse
        variable requestsInboxPrefix
        variable requestCounter
        variable asyncRequests
        
        constructor {} {
            set config(status) $nats::status_closed
            set sock ""
            set subscriptionCounter 0
            array set subscriptions {}
            array set serverInfo {} ;# INFO from a current NATS server
            set serverPool "" ;# list of dicts with parsed nats:// URLs, possibly augmented with extra ones received from a NATS server
            set currentServerIdx ""
            #consider replacing with string is alnum? does this allow Unicode?
            set subjectRegex {^[[:alnum:]_-]+$}
            set writing_coro ""
            set reading_coro ""
            set outBuffer [list]
            set randomChan [tcl::chan::random [tcl::randomseed]]
            set requestsInboxPrefix ""
            set requestCounter 1
            array set asyncRequests {} ; # reqID -> {timer callback}
            # initialise default configuration
            # we need it because untyped options with default value "" are not returned by cmdline::typedGetoptions at all
            foreach option $nats::option_syntax {
                lassign $option name defValue comment
                #drop everything after dot
                set name [lindex [split $name .] 0]
                set config($name) $defValue
            }
        }
        
        destructor {
            close $randomChan
        }
        
        method cget {option} {
            set opt [string trimleft $option -]
            if {[info exists config($opt)]} {
                return $config($opt)
            }
            throw {NATS INVALID_ARG} "Invalid option $option"
        }
        
        method configure {args} {
            if {[llength $args] == 0} {
                return [array get config]
            } 
            if {[llength $args] == 1} {
                return [my cget $args]
            } 
                
            set usage ": configure ?-option value?...\nValid options:"
            try {
                array set options [::cmdline::typedGetoptions args $nats::option_syntax $usage]
                array set config [array get options]
                if {[info exists options(servers)]} {
                    # typedGetoptions wraps lists in extra braces
                    my ParseServers [lindex $options(servers) 0]
                }
                if { $config(debug) } {
                    #unset bgerror 
                   interp bgerror "" [mymethod BackgroundError]
                }
            } trap {CMDLINE USAGE} {msg o} {
                throw {NATS INVALID_ARG} $msg
            }
        }

        method ParseServers {servers} {
            set serverPool ""
            
            foreach url $servers {
                # replace nats/tls scheme with http and delegate parsing to the uri package
                if {[string equal -length 7 $url "nats://"]} {
                    set url [string range $url 7 end]
                    set scheme nats
                } elseif {[string equal -length 6 $url "tls://"]} {
                    set url [string range $url 6 end]
                    set scheme tls
                }
                
                #uri::split will return a dict with these keys: host, port, user, pwd
                array set srv [uri::split "http://$url"]
                set srv(scheme) $scheme
                if {[info exists srv(user)] && ![info exists srv(pwd)]} {
                    set srv(token) $srv(user)
                    unset srv(user)
                }
                lappend serverPool [array get srv]
            }
            if {$config(randomize)} {
                set serverPool [::struct::list shuffle $serverPool]
            }
        }
        
        method connect { args } {
            switch -- $args {
                -async {
                    set async 1
                }
                "" {
                    set async 0
                }
                default {
                    throw {NATS INVALID_ARG} "Unknown option $args"
                }
            }
            set config(status) $nats::status_connecting
            # now try connecting to the first server
            my ConnectNextServer
            if {!$async} {
                vwait [self object]::config(status)
            }
        }
        
        method disconnect {} {
            if {$config(status) == $nats::status_closed} {
                return
            }
            #::nats::private::cleanup
        }
        
        method publish {subject msg {replySubj ""}} {
            my CheckConnection
            set msgLen [string length $msg]
            if {$msgLen > $serverInfo(max_payload)} {
                throw {NATS INVALID_ARG} "Maximum size of NATS message is $serverInfo(max_payload)"
            }
            
            if {![my CheckSubject $subject]} {
                throw {NATS INVALID_ARG} "Invalid subject $subject"
            }
            
            set data "PUB $subject $replySubj $msgLen"
            lappend outBuffer $data
            lappend outBuffer $msg
        }
        
        method subscribe {subject commandPrefix {queueGroup ""} } {            
            my CheckConnection
            if {![my CheckWildcard $subject]} {
                throw {NATS INVALID_ARG} "Invalid subject $subject"
            }
            
            if {[string length $commandPrefix] == 0} {
                throw {NATS INVALID_ARG} "Invalid command prefix $commandPrefix"
            }
            if {$queueGroup ne "" && ![string is graph $queueGroup]} {
                throw {NATS INVALID_ARG} "Invalid queue group $queueGroup"
            }
                                       
            incr subscriptionCounter
            #remMsg -1 means "unlimited"
            set subscriptions($subscriptionCounter) [dict create cmd $commandPrefix remMsg -1]
            
            #the format is SUB <subject> [queue group] <sid>
            set data "SUB $subject $queueGroup $subscriptionCounter"
            lappend outBuffer $data
            return $subscriptionCounter
        }
        
        method unsubscribe {subID {maxMessages 0}} {
            my CheckConnection
            
            if {![info exists subscriptions($subID)]} {
                throw {NATS INVALID_ARG} "Invalid subscription ID $subID"
            }
            
            if {! ([string is integer -strict $maxMessages] && $maxMessages >= 0)} {
                throw {NATS INVALID_ARG} "Invalid maxMessages $maxMessages"
            }
            
            #the format is UNSUB <sid> [max_msgs]
            if {$maxMessages == 0} {
                unset subscriptions($subID)
                set data "UNSUB $subID"
            } else {
                dict update subscriptions($subID) remMsg v {set v $maxMessages}
                set data "UNSUB $subID $maxMessages"
            }
            lappend outBuffer $data
        }
        
        method request {subject message args} {
            set timeout -1 ;# ms
            set callback ""
            
            foreach {opt val} $args {
                switch -- $opt {
                    -timeout {
                        set timeout $val
                    }
                    -callback {
                        set callback $val
                    }
                }
            }
            if {$timeout != -1} {
                if {! ([string is integer -strict $timeout] && $timeout > 0)} {
                    throw {NATS INVALID_ARG} "Invalid timeout $timeout"
                }
            }
            
            my InitReqSubscription
            if {$callback eq ""} {
                # sync request
                my publish $subject $message "$requestsInboxPrefix.0"
                set asyncRequests(0) ""
                if {$timeout != -1} {
                     set asyncRequests(0) [after $timeout [list set [self object]::syncResponse [list 1 ""]]]
                }
                vwait [self object]::syncResponse
                lassign $syncResponse timedOut response
                if {$timedOut} {
                    throw {NATS TIMEOUT} "Request timeout"
                }
                after cancel $asyncRequests(0)
                return $response
            }
            # async request
            my publish $subject $message "$requestsInboxPrefix.$requestCounter"
            set timerID ""
            if {$timeout != -1} {  
                set timerID [after $timeout [list [mymethod RequestCallback "..$requestCounter" "" "" -1]]]
            }
            set asyncRequests($requestCounter) [list $timerID $callback]
            incr requestCounter
        }
        
        method ping {timeout} {
        }
        
        method inbox {} {
            # very quick and dirty!
            return "_INBOX.[binary encode hex [read $randomChan 10]]"
        }
        
        method RequestCallback {subj msg reply sid} {
            set reqID [lindex [split $subj .] 2]
            if {$reqID == 0} {
                # resume from vwait in "method request"
                set syncResponse [list 0 $msg]
                return
            }
            if {![info exists asyncRequests($reqID)]} {
                # ignore all further responses, if >1 arrives
                return
            }
            lassign $asyncRequests($reqID) timerID callback
            if {$sid == -1} {
                #timeout
                after 0 [list {*}$callback 1 ""]
            } else {
                after cancel $timerID
                after 0 [list {*}$callback 0 $msg]
            }
            unset asyncRequests($reqID)
        }
        
        # --------- these procs execute in the coroutine writing_coro ---------------
        # connect to Nth server in the pool
        method ConnectNextServer {} {
            if {$currentServerIdx eq ""} {
                set currentServerIdx 0
            } else {
                incr currentServerIdx
            }
            if {$currentServerIdx > [llength $serverPool]} {
                set currentServerIdx 0
                after $config(reconnect_time_wait) $writing_coro
                yield
            }
            set serverDict [lindex $serverPool $currentServerIdx]
            #my DebugLog "Connecting to server $currentServerIdx: $serverDict"
            set sock [socket -async [dict get $serverDict host] [dict get $serverDict port]]
            if {[info coroutine] eq ""} {
                coroutine writing_coro {*}[mymethod WritingCoro]
            }
            chan event $sock writable [list $writing_coro writable]
            set connect_timer [after $config(connect_timeout) [list $writing_coro timeout]]
        }
        
        method WritingCoro {} {
            # it's important to NOT terminate this coro until the connection is fully closed, see ConnectNextServer
            set writing_coro [info coroutine]
            while {1} {
                set reason [yield]
                #my DebugLog "WritingCoro woke up due to $reason"
                # this event will arrive again and again if we don't disable it
                chan event $sock writable ""
                
                if { $reason eq "writable"} {
                    after cancel $connect_timer
                    # the socket either connected or failed to connect
                    set errorMsg [chan configure $sock -error]
                    if { $errorMsg != "" } {
                        my DebugLog "Failed to connect $currentServerIdx socket error: $errorMsg data: [chan configure $sock]"
                        chan close $sock
                        my ConnectNextServer
                        continue
                    }
                    # connection succeeded
                    # we want to call "flush" ourselves, so use -buffering full
                    # NATS protocol uses crlf as a delimiter
                    chan configure $sock -translation crlf -blocking 0 -buffering full
                    # wake up the reading coroutine with 1 when there is incoming data, and with 0 if the server closed the socket
                    coroutine reading_coro {*}[mymethod ReadingCoro]
                    chan event $sock readable [list $reading_coro 1]
                }
                if { $reason eq "timeout"} {
                    chan close $sock
                    #my DebugLog "Server $currentServerIdx timed out"
                    my ConnectNextServer
                }
                if { $reason eq "exit"} {
                    break
                }
            }
            my DebugLog "finished writing_coro"
        }
        
        method Pinger {} {
            if {$config(status) != $nats::status_connected} {
                return
            }
            after $config(ping_interval) [mymethod Pinger]
            lappend outBuffer "PING"
        }
        
        method Flusher {} {
            if {$config(status) != $nats::status_connected} {
                return
            }
            after $config(flush_interval) [mymethod Flusher]
            foreach msg $outBuffer {
                puts $sock $msg
            }
            set outBuffer [list]
            chan flush $sock
        }
        # --------- these procs execute in the coroutine reading_coro ---------------
        
        method SendConnect {} {
            set ind [json::write::indented]
            json::write::indented false
            set jsonMsg [json::write::object \
                         verbose $config(verbose) \
                         pedantic $config(pedantic) \
                         tls_required false \
                         name [json::write::string $config(name)] \
                         lang [json::write::string Tcl] \
                         version [json::write::string 0.9] \
                         protocol 1 \
                         echo $config(echo) \
                        ]
            json::write::indented $ind
            set data "CONNECT $jsonMsg"
            #my DebugLog "Sending $data"
            puts $sock $data
            flush $sock
            # exit from vwait in "connect"
            set config(status) $nats::status_connected
            after $config(flush_interval) [mymethod Flusher]
            after $config(ping_interval) [mymethod Pinger]
        }
        
        method INFO {cmd} {
            # example info
            #{"server_id":"kfNjUNirYU3tRVC7akGOcS","version":"1.4.1","proto":1,"go":"go1.11.5","host":"0.0.0.0","port":4222,"max_payload":1048576,"client_id":3}
            array set serverInfo [json::json2dict $cmd]
            my SendConnect
        }
        
        method MSG {cmd} {
            # the format is <subject> <sid> [reply-to] <#bytes>
            set replyTo ""
            if {[llength $cmd] == 4} {
                lassign $cmd subject subID replyTo expMsgLength
            } else {
                lassign $cmd subject subID expMsgLength
            }
            # turn off crlf translation while we read the message body
            chan configure $sock -translation binary
            # account for these crlf bytes that follow the message
            incr expMsgLength 2
            set messageBody [chan read $sock $expMsgLength]
            while {[string length $messageBody] != $expMsgLength} {
                # wait for the message; we may need multiple reads to receive all of it
                # it's cleaner to have a second "yield" here than putting this logic in readSocket
                yield
                append messageBody [chan read $sock $expMsgLength]
            }
            chan configure $sock -translation crlf
            # remove the trailing crlf
            set messageBody [string range $messageBody 0 end-2]
            if {[info exists subscriptions($subID)]} {
                # post the event
                set cmdPrefix [dict get $subscriptions($subID) cmd]
                after 0 [list {*}$cmdPrefix $subject $messageBody $replyTo $subID]
                set remainingMsg [dict get $subscriptions($subID) remMsg]
                if {$remainingMsg == 1} {
                    unset subscriptions($subID)
                } elseif {$remainingMsg > 1} {
                    dict update subscriptions($subID) remMsg v {incr v -1}
                }
            } else {
                # TODO: remove after release; nats.py ignores messages with unknown subID
                my DebugLog "unexpected message with subID $subID"
            }
            
            # now we return back to readSocket and enter "yield" there
        }
        
        method PING {cmd} {
            lappend outBuffer "PONG"
        }
        
        method PONG {cmd} {
            my DebugLog "received PONG"
        }
        
        method OK {cmd} {
            
        }
        
        method ERR {cmd} {
            
        }
        
        method ReadingCoro {} {
            set reading_coro [info coroutine]
            while {[yield]} {
                # the coroutine will be resumed at this point each time we receive data on the socket
                # we break the loop only when the socket is closed
                set readCount [chan gets $sock line]
                if {$readCount < 0} {
                    if {[eof $sock]} {
                        # server closed the socket
                        break
                    } else {
                        # we don't have a full line yet - wait for next fileevent
                        continue
                    }
                }
                my DebugLog "Received $readCount bytes:\n$line"
                # extract the first word from the line (INFO, MSG etc)
                # protocol_arg will be empty in case of PING/PONG
                set protocol_arg [lassign $line protocol_op]
                # in case of -ERR or +OK
                set protocol_op [string trimleft $protocol_op -+]
                my $protocol_op $protocol_arg
            }
            
            set config(status) $nats::status_closed
            close $sock
            set sock ""
            my DebugLog "finished reading_coro"
        }
        
        # ------------ coroutine end -----------------------------------------
        
        # all sync requests are using req ID = 0 (there is only one at a time)
        # async requests use incrementing req ID > 0
        method InitReqSubscription {} {
            if {$requestsInboxPrefix ne {}} {
                # we already subscribed
                return
            }
            set requestsInboxPrefix [my inbox]
            my subscribe "$requestsInboxPrefix.*" [mymethod RequestCallback]
        }
        
        method CheckSubject {subj} {            
            if {[string length $subj] == 0} {
                return false
            }
            foreach token [split $subj .] {
                if {![regexp -- $subjectRegex $token]} {
                    return false
                }
            }
            return true
        }
        method CheckWildcard {subj} {            
            if {[string length $subj] == 0} {
                return false
            }
            foreach token [split $subj .] {
                if {[regexp -- $subjectRegex $token] || $token == "*" || $token == ">" } {
                    continue
                }
                return false
            }
            return true
        }
        method CheckConnection {} {
            if {$config(status) != $nats::status_connected} {
                throw {NATS NO_CONNECTION} "No connection to NATS server"
            }
        }
        method BackgroundError {args} {
            my DebugLog "Background error: $args"
        }
        method DebugLog {msg} {
            if { !$config(debug) } {
                return
            }
            # workaround for not being able to format current time with millisecond precision
            # should not be needed in Tcl 8.7, see https://core.tcl-lang.org/tips/doc/trunk/tip/423.md
            set t [clock milliseconds]
            set timestamp [format "%s.%03d" \
                              [clock format [expr {$t / 1000}] -format %T] \
                              [expr {$t % 1000}] \
                          ]
            puts stderr "$timestamp: $msg"
        }
    }
}

package provide nats 0.9
