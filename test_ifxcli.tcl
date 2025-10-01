#!/usr/bin/env tclsh
#
# Test script for Informix CLI Tcl extension
#

# Setup environment
#set env(INFORMIXDIR) "/home/hugo/ifx"
#set env(INFORMIXSQLHOSTS) "/home/hugo/ifx/etc/sqlhosts"
#set env(INFORMIXSERVER) "eppix310"

# Add library path
lappend auto_path [file dirname [info script]]

# Load the extension
if {[catch {load ./libifxcli.so Ifxcli} err]} {
    puts stderr "Failed to load extension: $err"
    exit 1
}

puts "Extension loaded successfully"

# Test connection
puts "\nTesting connection..."
if {[catch {
    # Connect using DSN from odbc.ini (credentials read automatically)
    set conn [::ifx::connect "eppixprod"]
    puts "Connected: $conn"
} err]} {
    puts stderr "Connection failed: $err"
    exit 1
}

# Test query execution
puts "\nTesting query execution..."
if {[catch {
    set result [::ifx::execute $conn "SELECT FIRST 5 tabname FROM systables"]
    puts "Query executed: $result"
} err]} {
    puts stderr "Query failed: $err"
    ::ifx::disconnect $conn
    exit 1
}

# Fetch and display results
puts "\nFetching results..."
set row_count 0
while {1} {
    if {[catch {
        set row [::ifx::fetch $result]
    } err]} {
        puts stderr "Fetch failed: $err"
        break
    }
    
    if {$row eq ""} {
        break
    }
    
    incr row_count
    puts "Row $row_count: $row"
    
    # Extract table name from dict
    dict with row {
        if {[info exists tabname]} {
            puts "  Table name: $tabname"
        }
    }
}

puts "\nTotal rows fetched: $row_count"

# Cleanup
::ifx::close_result $result
::ifx::disconnect $conn

puts "\nTest completed successfully!"

