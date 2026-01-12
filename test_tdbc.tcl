#!/usr/bin/env tclsh
#
# Test script for TDBC-compatible Informix interface (ifx::odbc)
#

# Add library path
lappend auto_path [file dirname [info script]]

# Load the TDBC-compatible interface
if {[catch {source [file join [file dirname [info script]] libIfxTdbc.tcl]} err]} {
    puts stderr "Failed to load extension: $err"
    exit 1
}

puts "ifx::odbc extension loaded successfully"
puts "Package version: [package present ifx::odbc]"

# Test datasources
puts "\n=== Available Data Sources ==="
puts [::ifx::odbc::datasources]

# Test connection creation (TDBC style)
puts "\n=== Testing connection create (TDBC style) ==="
if {[catch {
    ::ifx::odbc::connection create db "DSN=eppixprod"
    puts "Connected: db"
} err]} {
    puts stderr "Connection failed: $err"
    exit 1
}

# Test prepare and execute
puts "\n=== Test 1: Prepare and Execute ==="
if {[catch {
    set stmt [db prepare "SELECT FIRST 5 tabname, tabid FROM systables"]
    set rs [$stmt execute]
    puts "Statement prepared and executed"
    
    puts "Columns: [$rs columns]"
    
    set count 0
    while {[$rs nextrow row]} {
        incr count
        puts "Row $count: $row"
    }
    puts "Total rows: [$rs rowcount]"
    
    $rs close
    $stmt close
} err]} {
    puts stderr "Test 1 failed: $err"
}

# Test allrows
puts "\n=== Test 2: allrows (dicts) ==="
if {[catch {
    set rows [db allrows "SELECT FIRST 3 tabname FROM systables"]
    foreach row $rows {
        puts "  $row"
    }
} err]} {
    puts stderr "Test 2 failed: $err"
}

# Test allrows -as lists
puts "\n=== Test 3: allrows -as lists ==="
if {[catch {
    set rows [db allrows -as lists "SELECT FIRST 3 tabname, tabid FROM systables"]
    foreach row $rows {
        puts "  $row"
    }
} err]} {
    puts stderr "Test 3 failed: $err"
}

# Test foreach
puts "\n=== Test 4: foreach ==="
if {[catch {
    db foreach row "SELECT FIRST 3 tabname FROM systables" {
        puts "  Table: [dict get $row tabname]"
    }
} err]} {
    puts stderr "Test 4 failed: $err"
}

# Test foreach -as lists
puts "\n=== Test 5: foreach -as lists ==="
if {[catch {
    db foreach -as lists row "SELECT FIRST 3 tabname, tabid FROM systables" {
        lassign $row tabname tabid
        puts "  Table: $tabname (ID: $tabid)"
    }
} err]} {
    puts stderr "Test 5 failed: $err"
}

# Test foreach -columnsvariable
puts "\n=== Test 6: foreach with -columnsvariable ==="
if {[catch {
    db foreach -as lists -columnsvariable cols row "SELECT FIRST 2 tabname, tabid FROM systables" {
        puts "  Columns: $cols"
        puts "  Row: $row"
    }
} err]} {
    puts stderr "Test 6 failed: $err"
}

# Test nextlist and nextdict
puts "\n=== Test 7: nextlist and nextdict ==="
if {[catch {
    set stmt [db prepare "SELECT FIRST 2 tabname, tabid FROM systables"]
    set rs [$stmt execute]
    
    puts "Using nextlist:"
    set row [$rs nextlist]
    puts "  $row"
    
    puts "Using nextdict:"
    set row [$rs nextdict]
    if {$row ne ""} {
        puts "  $row"
    }
    
    $rs close
    $stmt close
} err]} {
    puts stderr "Test 7 failed: $err"
}

# Test tables method
puts "\n=== Test 8: tables method ==="
if {[catch {
    set tables [db tables "sys%"]
    puts "Tables matching 'sys%': [lrange $tables 0 4] ..."
} err]} {
    puts stderr "Test 8 failed: $err"
}

# Test columns method
puts "\n=== Test 9: columns method ==="
if {[catch {
    set cols [db columns "systables"]
    puts "Columns in systables:"
    dict for {colname info} $cols {
        puts "  $colname: $info"
    }
} err]} {
    puts stderr "Test 9 failed: $err"
}

# Test statement params
puts "\n=== Test 10: statement params ==="
if {[catch {
    set stmt [db prepare "SELECT * FROM systables WHERE tabid = ? AND tabname = ?"]
    set params [$stmt params]
    puts "Parameters: $params"
    $stmt close
} err]} {
    puts stderr "Test 10 failed: $err"
}

# Test connection new (auto-named)
puts "\n=== Test 11: connection new (auto-named) ==="
if {[catch {
    set db2 [::ifx::odbc::connection new "DSN=eppixprod"]
    puts "Created auto-named connection: $db2"
    
    set rows [$db2 allrows "SELECT FIRST 1 tabname FROM systables"]
    puts "Query result: $rows"
    
    $db2 close
    puts "Closed connection"
} err]} {
    puts stderr "Test 11 failed: $err"
}

# Test configuration
puts "\n=== Test 12: configure ==="
if {[catch {
    puts "Current config: [db configure]"
    puts "Readonly: [db configure -readonly]"
} err]} {
    puts stderr "Test 12 failed: $err"
}

# Cleanup
puts "\n=== Cleanup ==="
db close
puts "Connection closed"

puts "\n=== All tests completed! ==="

