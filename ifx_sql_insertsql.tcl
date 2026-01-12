#!/opt/sup/tcl/bin/tclsh

set auto_path [linsert $auto_path 1 /usr/local/lib/tcl8/8.6]
set auto_path [linsert $auto_path 1 /usr/local/lib]
package require sha1
#package require tdbc::odbc
package require ifx::odbc
source $env(SCRINC)/db.tcl
source $env(SCRINC)/input.tcl
source $env(SCRINC)/sorb.tcl

if {[llength $argv] < 1 || [lindex $argv 0] eq ""} {
    puts stderr "Usage: $argv0 <tstamp>"
    puts stderr "Example: $argv0 2024-01-01"
    exit 1
}
set tstamp [lindex $argv 0]

set vallist [list tstamp userid sessid currstmt sqltype currdb isolvl lockmode sqlerr isamerr fevers explain currsql values parsesql tmptabs read write]

array set knownhash {}

ifx::odbc::connection create db DSN=eppixprod

set cleanup      [db prepare  {delete from mon_ssd_session_sql_data where tstamp = :tstamp} ]
set sql_insert   [db prepare  {insert    into mon_sec_sql_explain_cost(sql, sqlhash)  values (:sql, :hash) }  ]
set sql_qry_hash [db prepare  {select id from mon_sec_sql_explain_cost where sqlhash = :hash } ]
set ses_insert   [db prepare  {insert    into mon_ssd_session_sql_data values (:tstamp, :sesscnt, :userid, :sessid, :currstmt, :sqltype, :currdb, :isolvl, :lockmode, :sqlerr, :isamerr, :fevers, :explain, :currsql, :values, :parsesql, :tmptabs, :read, :write)}]

proc hashme {string} { 
    sha1::sha1 -hex $string
}

proc insert_sql {sql} { 
    global knownhash
    global sql_insert
    global sql_qry_hash

    set hash [hashme $sql]

    if {[info exists knownhash($hash)]} { 
            return $knownhash($hash)
    }

    set sid {}
    set resset [$sql_qry_hash execute]
    # Get first row's first column value
    while {[$resset nextrow -as lists row]} {
        set sid [lindex $row 0]
        break
    }
    $resset close
    if {$sid ne ""} { 
        set knownhash($hash) $sid
        return $sid
    } 

    set catched {}
    if {[catch {
        set resset [$sql_insert execute]
    } catched]} {
        puts $catched
        puts $sql
    }
    catch {$resset close}
    
    set sid {}
    set resset [$sql_qry_hash execute]
    while {[$resset nextrow -as lists row]} {
        set sid [lindex $row 0]
        break
    }
    $resset close
    if {$sid == ""} { 
        set sid 999999999
    }
    set knownhash($hash) $sid
    return $sid
}

proc insert_session {data} { 
    global ses_insert
    global vallist

    lassign $data {*}$vallist
    set sesscnt 1

    set currsql  [string range $currsql  0 31950]
    set parsesql [string range $parsesql 0 31950]

    set currsql  [insert_sql $currsql]
    set parsesql [insert_sql $parsesql]

    set catched {}
    if {[catch { 
        set resset [$ses_insert execute]
        $resset close
    } catched]} { 
        puts "ERROR ERROR ERROR $catched"
        puts "ERROR ERROR ERROR $data"
    }
}


set resset [$cleanup execute]
$resset close

while {[gets stdin input] >= 0} {
    set inputs [split $input "~"] 
    insert_session $inputs 
}

