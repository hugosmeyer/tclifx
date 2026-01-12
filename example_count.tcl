#!/usr/bin/env tclsh
#
# Simple example: Count rows in systables
#
# Usage:
#   source env.sh  # or env-server.sh on server
#   export LD_LIBRARY_PATH=$INFORMIXDIR/lib:$INFORMIXDIR/lib/cli:$LD_LIBRARY_PATH
#   tclsh example_count.tcl
#

# Load the package
set script_dir [file dirname [info script]]
source [file join $script_dir libIfxTdbc.tcl]

# Connect
puts "Connecting to eppixprod..."
::ifx::odbc::connection create db "DSN=eppixprod"
puts "Connected."

# Query
set rows [db allrows "SELECT COUNT(*) AS cnt FROM systables"]
set count [dict get [lindex $rows 0] cnt]

puts "Number of tables in systables: $count"

# Cleanup
db close
puts "Done."

