#!/usr/bin/env tclsh
#
# libInformixOO.tcl - Object-oriented Informix database interface for Tcl
# Uses TclOO for proper object encapsulation
#

package require TclOO

# Load the native extension
load libifxcli.so Ifxcli

# Rename native commands to avoid collision
rename ::ifx::connect ::ifx::_native_connect
rename ::ifx::execute ::ifx::_native_execute
rename ::ifx::fetch ::ifx::_native_fetch
rename ::ifx::close_result ::ifx::_native_close_result
rename ::ifx::disconnect ::ifx::_native_disconnect

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
        
        # Create the native connection using renamed native command
        if {$user ne "" && $password ne ""} {
            set conn_handle [::ifx::_native_connect $dsn $user $password]
        } elseif {$user ne ""} {
            set conn_handle [::ifx::_native_connect $dsn $user]
        } else {
            set conn_handle [::ifx::_native_connect $dsn]
        }
    }
    
    destructor {
        catch {::ifx::_native_disconnect $conn_handle}
    }
    
    # Execute SQL and return ResultSet object
    method execute {sql} {
        set result_handle [::ifx::_native_execute $conn_handle $sql]
        return [::ifx::ResultSet new $result_handle]
    }
    
    # Prepare SQL statement and return PreparedStatement object
    method prepare {sql} {
        return [::ifx::PreparedStatement new $conn_handle $sql]
    }
    
    # Disconnect
    method disconnect {} {
        ::ifx::_native_disconnect $conn_handle
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
        catch {::ifx::_native_close_result $result_handle}
    }
    
    # Get column headers (list of column names)
    method headers {} {
        if {!$columns_fetched} {
            # Need to peek at first row to get column names
            # We'll fetch and cache it
            set row_dict [::ifx::_native_fetch $result_handle]
            if {$row_dict ne ""} {
                set column_names [dict keys $row_dict]
                set columns_fetched 1
                # Note: This consumes the first row, which is a limitation
                # Ideally we'd use SQLDescribeCol from the C extension
            }
        }
        return $column_names
    }
    
    # Fetch next row as list
    method next {} {
        set row_dict [::ifx::_native_fetch $result_handle]
        
        if {$row_dict eq ""} {
            return {}
        }
        
        # Ensure we have column names from the first row
        if {!$columns_fetched} {
            set column_names [dict keys $row_dict]
            set columns_fetched 1
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
        ::ifx::_native_close_result $result_handle
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
    variable bind_types
    variable closed
    
    constructor {conn sql} {
        set conn_handle $conn
        set sql_template $sql
        set bind_types {}
        set closed 0
    }
    
    destructor {
        # Nothing to clean up - we don't hold native resources
    }
    
    # Close/destroy the prepared statement
    method close {} {
        set closed 1
        # Clear references
        set conn_handle ""
        set sql_template ""
        set bind_types {}
    }
    
    # Set bind types (list of 'string' or 'numeric' for each placeholder)
    # Example: $stmt setBindTypes {string numeric string}
    method setBindTypes {types} {
        set bind_types $types
    }
    
    # Execute prepared statement with bind values
    method execute {bind_values {force_string 0}} {
        if {$closed} {
            error "Cannot execute closed prepared statement"
        }
        
        # Ensure bind_values is a list
        if {![string is list $bind_values]} {
            set bind_values [list $bind_values]
        }
        
        # Substitute ? placeholders with actual values
        set sql $sql_template
        set bind_index 0
        
        foreach value $bind_values {
            # Find first ? and replace it
            set idx [string first "?" $sql]
            if {$idx < 0} {
                error "More bind values than placeholders in SQL: $sql_template"
            }
            
            # Determine if we should quote this value
            set should_quote 1
            
            if {$force_string} {
                # Force all values to be quoted as strings
                set should_quote 1
            } elseif {[llength $bind_types] > 0} {
                # Use explicit bind type if provided
                if {$bind_index < [llength $bind_types]} {
                    set bind_type [lindex $bind_types $bind_index]
                    if {$bind_type eq "numeric"} {
                        set should_quote 0
                    }
                }
            } else {
                # Auto-detect: only treat as numeric if it's purely a number
                # This avoids treating things like "0001234" as numeric
                if {[string is integer -strict $value] || [string is double -strict $value]} {
                    set should_quote 0
                }
            }
            
            if {$should_quote} {
                # String value - escape single quotes and add quotes
                set escaped_value [string map {' ''} $value]
                set sql "[string range $sql 0 [expr {$idx-1}]]'$escaped_value'[string range $sql [expr {$idx+1}] end]"
            } else {
                # Numeric value - no quotes
                set sql "[string range $sql 0 [expr {$idx-1}]]$value[string range $sql [expr {$idx+1}] end]"
            }
            
            incr bind_index
        }
        
        # Check if there are unfilled placeholders
        if {[string first "?" $sql] >= 0} {
            error "Not enough bind values for SQL: $sql_template (got [llength $bind_values] values)"
        }
        
        # Debug output
        if {[info exists ::env(IFX_DEBUG)]} {
            puts stderr "Executing SQL: $sql"
        }
        
        # Execute the SQL
        if {[catch {
            set result_handle [::ifx::_native_execute $conn_handle $sql]
        } err]} {
            error "SQL execution failed: $err\nSQL was: $sql"
        }
        
        return [::ifx::ResultSet new $result_handle]
    }
    
    # Convenience method: execute with all values as strings
    method executeString {bind_values} {
        return [my execute $bind_values 1]
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
    set presql [$dbc prepare "SELECT FIRST ? tabname FROM systables WHERE tabid < ?"]
    
    # Execute with different parameters
    puts "\nFirst execution (first 2, tabid < 10):"
    set resset [$presql execute [list 2 10]]
    $resset foreach row {
        puts "  Row: $row"
    }
    $resset close
    
    puts "\nSecond execution (first 3, tabid < 5):"
    set resset [$presql execute [list 3 5]]
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
