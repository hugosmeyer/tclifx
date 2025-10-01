#!/usr/bin/env tclsh
#
# libInformixOO.tcl - Object-oriented Informix database interface for Tcl
# Uses TclOO for proper object encapsulation
#

package require TclOO

# Load the native extension
load ./libifxcli.so Ifxcli

namespace eval ::ifx {
    # Export the connect command
    namespace export connect
}

#
# Connection Class
#
oo::class create ::ifx::Connection {
    variable conn_handle
    variable dsn_name

    constructor {dsn {user ""} {password ""}} {
        set dsn_name $dsn
        
        # Create the native connection
        if {$user ne "" && $password ne ""} {
            set conn_handle [::ifx::connect $dsn $user $password]
        } elseif {$user ne ""} {
            set conn_handle [::ifx::connect $dsn $user]
        } else {
            set conn_handle [::ifx::connect $dsn]
        }
    }

    destructor {
        catch {::ifx::disconnect $conn_handle}
    }

    # Execute SQL and return ResultSet object
    method execute {sql} {
        set result_handle [::ifx::execute $conn_handle $sql]
        return [::ifx::ResultSet new $result_handle]
    }

    # Prepare SQL statement and return PreparedStatement object
    method prepare {sql} {
        return [::ifx::PreparedStatement new $conn_handle $sql]
    }

    # Disconnect
    method disconnect {} {
        ::ifx::disconnect $conn_handle
    }

    # Get connection info
    method info {} {
        return [dict create dsn $dsn_name handle $conn_handle]
    }
}

#
# ResultSet Class
#
oo::class create ::ifx::ResultSet {
    variable result_handle
    variable column_names
    variable columns_fetched

    constructor {handle} {
        set result_handle $handle
        set columns_fetched 0
        set column_names {}
    }

    destructor {
        catch {::ifx::close_result $result_handle}
    }

    # Get column headers (list of column names)
    method headers {} {
        if {!$columns_fetched} {
            my FetchColumnNames
        }
        return $column_names
    }

    # Fetch next row as list
    method next {} {
        set row_dict [::ifx::fetch $result_handle]
        
        if {$row_dict eq ""} {
            return {}
        }
        
        # Ensure we have column names
        if {!$columns_fetched} {
            my FetchColumnNames $row_dict
        }
        
        # Convert dict to list in column order
        set row_list {}
        foreach col $column_names {
            if {[dict exists $row_dict $col]} {
                lappend row_list [dict get $row_dict $col]
            } else {
                lappend row_list ""
            }
        }
        
        return $row_list
    }

    # Fetch all rows as list of lists
    method fetchall {} {
        set result {}
        
        # Add headers as first row
        lappend result [my headers]
        
        # Fetch all data rows
        while {1} {
            set row [my next]
            if {[llength $row] == 0} {
                break
            }
            lappend result $row
        }
        
        return $result
    }

    # Foreach iterator
    method foreach {varName body} {
        upvar 1 $varName row
        
        while {1} {
            set row [my next]
            if {[llength $row] == 0} {
                break
            }
            uplevel 1 $body
        }
    }

    # Close result set
    method close {} {
        ::ifx::close_result $result_handle
    }

    # Private method to fetch column names from first row
    method FetchColumnNames {{first_row_dict ""}} {
        if {$first_row_dict ne ""} {
            # Extract from first row dict
            set column_names [dict keys $first_row_dict]
        } else {
            # Fetch a row to get column names, then we need to re-execute
            # For now, just mark as fetched
            set column_names {}
        }
        set columns_fetched 1
    }
}

#
# PreparedStatement Class
#
oo::class create ::ifx::PreparedStatement {
    variable conn_handle
    variable sql_template

    constructor {conn sql} {
        set conn_handle $conn
        set sql_template $sql
    }

    # Execute prepared statement with bind values
    method execute {bind_values} {
        # Substitute ? placeholders with actual values
        set sql $sql_template
        
        foreach value $bind_values {
            # Escape single quotes
            set escaped_value [string map {' ''} $value]
            
            # Replace first ? with value
            set idx [string first "?" $sql]
            if {$idx >= 0} {
                set sql "[string range $sql 0 [expr {$idx-1}]]'$escaped_value'[string range $sql [expr {$idx+1}] end]"
            }
        }
        
        # Execute the SQL
        set result_handle [::ifx::execute $conn_handle $sql]
        return [::ifx::ResultSet new $result_handle]
    }
}

#
# Main connect function - returns Connection object
#
proc ::ifx::connect {dsn args} {
    return [::ifx::Connection new $dsn {*}$args]
}

# Example usage when run as script
if {[info script] eq $argv0} {
    puts "Testing Object-Oriented Informix Interface...\n"

    # Create connection
    set dbc [::ifx::connect "eppixprod"]
    puts "Created connection: $dbc"

    puts "\n=== Test 1: Simple execute with next ==="
    set resset [$dbc execute "SELECT FIRST 3 tabname FROM systables"]
    puts "Headers: [$resset headers]"

    set count 0
    while {1} {
        set row [$resset next]
        if {[llength $row] == 0} {
            puts "No more rows (indicated by empty list)"
            break
        }
        incr count
        puts "Row $count: $row"
    }
    $resset close

    puts "\n=== Test 2: fetchall (returns list of lists) ==="
    set resset [$dbc execute "SELECT FIRST 3 tabname FROM systables"]
    set all_data [$resset fetchall]

    puts "Complete result (list of lists):"
    foreach row $all_data {
        puts "  $row"
    }
    puts "\nFirst row (headers): [lindex $all_data 0]"
    puts "Second row (data):   [lindex $all_data 1]"
    $resset close

    puts "\n=== Test 3: foreach with lassign ==="
    set resset [$dbc execute "SELECT FIRST 3 tabname FROM systables"]
    set headers [$resset headers]
    puts "Headers: $headers"

    $resset foreach row {
        lassign $row {*}$headers
        puts "Table name: $tabname"
    }
    $resset close

    puts "\n=== Test 4: Prepared statement ==="
    set presql [$dbc prepare "SELECT tabname FROM systables WHERE tabid < ? LIMIT ?"]

    # Execute with different parameters
    puts "\nFirst execution (tabid < 10, limit 2):"
    set resset [$presql execute [list 10 2]]
    $resset foreach row {
        puts "  Row: $row"
    }
    $resset close

    puts "\nSecond execution (tabid < 5, limit 3):"
    set resset [$presql execute [list 5 3]]
    $resset foreach row {
        puts "  Row: $row"
    }
    $resset close

    puts "\n=== Test 5: Headers extraction ==="
    set resset [$dbc execute "SELECT FIRST 1 tabname, tabid FROM systables"]
    set headers [$resset headers]
    puts "Column headers: $headers"

    $resset foreach row {
        lassign $row {*}$headers
        puts "  tabname=$tabname, tabid=$tabid"
    }
    $resset close

    # Cleanup
    $dbc disconnect

    puts "\nAll tests completed successfully!"
}
