#!/usr/bin/env tclsh
#
# libIfxTdbc.tcl - TDBC-compatible Informix database interface for Tcl
# 
# This provides a drop-in replacement interface for tdbc::odbc
# using the ifx::odbc namespace instead.
#
# Usage mirrors tdbc::odbc:
#   package require ifx::odbc
#   ifx::odbc::connection create db "DSN=mydsn"
#   ifx::odbc::connection new "DSN=mydsn"
#

package require TclOO

# Load the native extension if not already loaded
# (pkgIndex.tcl may have already loaded it)
if {[info commands ::ifx::connect] eq "" && [info commands ::ifx::_native_connect] eq ""} {
    set _ifx_script_dir [file dirname [info script]]
    if {[file exists [file join $_ifx_script_dir libifxcli.so]]} {
        load [file join $_ifx_script_dir libifxcli.so] Ifxcli
    } elseif {[file exists ./libifxcli.so]} {
        load ./libifxcli.so Ifxcli
    } else {
        load libifxcli.so Ifxcli
    }
    unset _ifx_script_dir
}

# Rename native commands to avoid collision with OO wrapper
# (only if not already renamed)
if {[info commands ::ifx::connect] ne ""} {
    rename ::ifx::connect ::ifx::_native_connect
    rename ::ifx::execute ::ifx::_native_execute
    rename ::ifx::fetch ::ifx::_native_fetch
    rename ::ifx::close_result ::ifx::_native_close_result
    rename ::ifx::disconnect ::ifx::_native_disconnect
}

namespace eval ::ifx::odbc {
    variable version "1.0"
    
    # Export public commands
    namespace export connection datasources drivers
}

#
# ifx::odbc::datasources ?-system|-user?
# Returns list of available data sources
#
proc ::ifx::odbc::datasources {args} {
    set mode ""
    if {[llength $args] > 0} {
        set mode [lindex $args 0]
    }
    
    # Parse odbc.ini files to find DSN names
    set datasources {}
    set ini_files {}
    
    if {$mode eq "" || $mode eq "-user"} {
        set home [file normalize ~]
        if {[file exists "$home/.odbc.ini"]} {
            lappend ini_files "$home/.odbc.ini"
        }
    }
    
    if {$mode eq "" || $mode eq "-system"} {
        if {[file exists "/etc/odbc.ini"]} {
            lappend ini_files "/etc/odbc.ini"
        }
    }
    
    foreach ini_file $ini_files {
        if {[catch {open $ini_file r} fh]} {
            continue
        }
        
        while {[gets $fh line] >= 0} {
            set line [string trim $line]
            if {[string match {\[*\]} $line]} {
                set dsn [string range $line 1 end-1]
                if {$dsn ne "ODBC Data Sources" && $dsn ne "ODBC"} {
                    lappend datasources $dsn
                }
            }
        }
        close $fh
    }
    
    return [lsort -unique $datasources]
}

#
# ifx::odbc::drivers
# Returns dictionary of available drivers
#
proc ::ifx::odbc::drivers {} {
    # For Informix CLI, we typically have one driver
    set drivers {}
    
    # Check common Informix driver locations
    set informixdir $::env(INFORMIXDIR)
    if {$informixdir ne "" && [file exists "$informixdir/lib/cli/libifcli.so"]} {
        dict set drivers "Informix CLI" "Informix ODBC Driver via CLI"
    }
    
    return $drivers
}

# Static/class-level data for connection class
namespace eval ::ifx::odbc::connection {
    # Default connection options
    variable defaultOptions [dict create \
        -encoding "" \
        -isolation "" \
        -readonly 0 \
        -timeout 0 \
    ]
}

# Static helper: Parse ODBC-style connection string
# Returns dict with keys: DSN, UID, PWD, DRIVER, etc.
proc ::ifx::odbc::connection::ParseConnectionString {connString} {
    set result {}
    
    # Handle semicolon-separated format
    set parts [split $connString ";"]
    
    foreach part $parts {
        set part [string trim $part]
        if {$part eq ""} continue
        
        # Parse KEY=VALUE or KEY={VALUE}
        # Note: Use double quotes for regex with literal braces to avoid Tcl parsing issues
        if {[regexp "^(\[^=\]+)=\\{(\[^\}\]*)\\}\$" $part -> key value]} {
            dict set result [string toupper $key] $value
        } elseif {[regexp {^([^=]+)=(.*)$} $part -> key value]} {
            dict set result [string toupper $key] $value
        }
    }
    
    return $result
}

# Static helper: Escape SQL string value for safe inclusion in queries
proc ::ifx::odbc::connection::EscapeString {value} {
    return [string map {' ''} $value]
}

#
# Connection class - TDBC compatible
#
oo::class create ::ifx::odbc::connection {
    variable conn_handle
    variable conn_string
    variable options
    variable statements
    
    # Class method: create named connection (static)
    self method create {name connString args} {
        set obj [my new $connString {*}$args]
        # Use :: prefix to ensure global namespace if name doesn't have one
        if {![string match "::*" $name]} {
            set target "::$name"
        } else {
            set target $name
        }
        rename $obj $target
        # Return the name without :: prefix for user convenience
        return $name
    }
    
    constructor {connString args} {
        set conn_string $connString
        set statements {}
        
        # Copy default options from class-level variable
        set options $::ifx::odbc::connection::defaultOptions
        
        foreach {opt val} $args {
            if {[dict exists $options $opt]} {
                dict set options $opt $val
            } else {
                error "unknown option \"$opt\": must be -encoding, -isolation, -readonly, or -timeout"
            }
        }
        
        # Parse connection string using static helper
        set parsed [::ifx::odbc::connection::ParseConnectionString $connString]
        
        # Extract DSN, user, password
        set dsn ""
        set user ""
        set password ""
        
        if {[dict exists $parsed DSN]} {
            set dsn [dict get $parsed DSN]
        }
        if {[dict exists $parsed UID]} {
            set user [dict get $parsed UID]
        }
        if {[dict exists $parsed PWD]} {
            set password [dict get $parsed PWD]
        }
        
        if {$dsn eq ""} {
            error "Connection string must contain DSN"
        }
        
        # Create the native connection
        if {$user ne "" && $password ne ""} {
            set conn_handle [::ifx::_native_connect $dsn $user $password]
        } elseif {$user ne ""} {
            set conn_handle [::ifx::_native_connect $dsn $user]
        } else {
            set conn_handle [::ifx::_native_connect $dsn]
        }
    }
    
    destructor {
        # Close all statements
        foreach stmt $statements {
            catch {$stmt close}
        }
        
        # Disconnect
        catch {::ifx::_native_disconnect $conn_handle}
    }
    
    # Close the connection (TDBC compatible)
    method close {} {
        my destroy
    }
    
    # Prepare a SQL statement (TDBC compatible)
    # Returns a statement object
    method prepare {sql} {
        set stmt [::ifx::odbc::statement new [self] $conn_handle $sql]
        lappend statements $stmt
        return $stmt
    }
    
    # Execute SQL directly and return resultset (convenience method)
    method allrows {args} {
        # Parse -as option
        set as "dicts"
        set sql ""
        
        set i 0
        while {$i < [llength $args]} {
            set arg [lindex $args $i]
            switch -glob -- $arg {
                -as* {
                    if {$arg eq "-as"} {
                        incr i
                        set as [lindex $args $i]
                    } else {
                        set as [string range $arg 4 end]
                    }
                }
                -- {
                    incr i
                    set sql [lindex $args $i]
                    break
                }
                default {
                    set sql $arg
                }
            }
            incr i
        }
        
        if {$sql eq ""} {
            error "missing SQL statement"
        }
        
        set stmt [my prepare $sql]
        set rs [$stmt execute]
        
        set result {}
        if {$as eq "lists"} {
            while {1} {
                set row [$rs nextlist]
                if {$row eq ""} break
                lappend result $row
            }
        } else {
            while {1} {
                set row [$rs nextdict]
                if {$row eq ""} break
                lappend result $row
            }
        }
        
        $rs close
        $stmt close
        
        return $result
    }
    
    # Execute SQL and iterate with foreach (TDBC compatible)
    method foreach {args} {
        # Parse: ?-as dicts|lists? ?-columnsvariable varName? ?--? varName sql script
        set as "dicts"
        set columnsVar ""
        set varName ""
        set sql ""
        set script ""
        
        set i 0
        while {$i < [llength $args]} {
            set arg [lindex $args $i]
            switch -glob -- $arg {
                -as {
                    incr i
                    set as [lindex $args $i]
                }
                -columnsvariable {
                    incr i
                    set columnsVar [lindex $args $i]
                }
                -- {
                    incr i
                    break
                }
                -* {
                    error "unknown option \"$arg\""
                }
                default {
                    break
                }
            }
            incr i
        }
        
        # Remaining args: varName sql script
        set remaining [lrange $args $i end]
        if {[llength $remaining] != 3} {
            error "wrong # args: should be \"foreach ?options? varName sql script\""
        }
        
        lassign $remaining varName sql script
        
        upvar 1 $varName row
        if {$columnsVar ne ""} {
            upvar 1 $columnsVar columns
        }
        
        set stmt [my prepare $sql]
        set rs [$stmt execute]
        
        if {$columnsVar ne ""} {
            set columns [$rs columns]
        }
        
        set result ""
        while {1} {
            if {$as eq "lists"} {
                set row [$rs nextlist]
            } else {
                set row [$rs nextdict]
            }
            
            if {$row eq ""} break
            
            set code [catch {uplevel 1 $script} result opts]
            switch $code {
                0 { }
                1 { 
                    $rs close
                    $stmt close
                    return -options $opts $result 
                }
                2 { 
                    $rs close
                    $stmt close
                    return -options $opts $result 
                }
                3 { break }
                4 { continue }
            }
        }
        
        $rs close
        $stmt close
        
        return $result
    }
    
    # Get list of tables (TDBC compatible)
    method tables {{pattern "%"}} {
        set result {}
        set rs_handle [::ifx::_native_execute $conn_handle \
            "SELECT tabname FROM systables WHERE tabtype = 'T' AND tabname LIKE '[string map {* % ? _} $pattern]'"]
        
        while {1} {
            set row [::ifx::_native_fetch $rs_handle]
            if {$row eq ""} break
            lappend result [dict get $row tabname]
        }
        
        ::ifx::_native_close_result $rs_handle
        return $result
    }
    
    # Get columns for a table (TDBC compatible)
    method columns {table {pattern "%"}} {
        set result {}
        set sql "SELECT c.colname, c.coltype, c.collength \
                 FROM syscolumns c, systables t \
                 WHERE c.tabid = t.tabid AND t.tabname = '$table' \
                 AND c.colname LIKE '[string map {* % ? _} $pattern]' \
                 ORDER BY c.colno"
        
        set rs_handle [::ifx::_native_execute $conn_handle $sql]
        
        while {1} {
            set row [::ifx::_native_fetch $rs_handle]
            if {$row eq ""} break
            
            set colname [dict get $row colname]
            dict set result $colname [dict create \
                type [dict get $row coltype] \
                precision [dict get $row collength] \
            ]
        }
        
        ::ifx::_native_close_result $rs_handle
        return $result
    }
    
    # Get primary keys for a table (TDBC compatible)
    method primarykeys {table} {
        # Informix stores primary key info in sysconstraints/sysindexes
        set result {}
        set sql "SELECT col.colname \
                 FROM sysconstraints con, systables tab, sysindexes idx, syscolumns col \
                 WHERE con.tabid = tab.tabid \
                 AND con.idxname = idx.idxname \
                 AND tab.tabid = col.tabid \
                 AND con.constrtype = 'P' \
                 AND tab.tabname = '$table' \
                 AND col.colno IN (idx.part1, idx.part2, idx.part3, idx.part4, \
                                   idx.part5, idx.part6, idx.part7, idx.part8)"
        
        catch {
            set rs_handle [::ifx::_native_execute $conn_handle $sql]
            
            while {1} {
                set row [::ifx::_native_fetch $rs_handle]
                if {$row eq ""} break
                lappend result [dict get $row colname]
            }
            
            ::ifx::_native_close_result $rs_handle
        }
        
        return $result
    }
    
    # Get foreign keys for a table (TDBC compatible)
    method foreignkeys {args} {
        # Parse -primary and -foreign options
        set primary ""
        set foreign ""
        
        foreach {opt val} $args {
            switch -- $opt {
                -primary { set primary $val }
                -foreign { set foreign $val }
                default { error "unknown option \"$opt\"" }
            }
        }
        
        # Return empty for now - Informix FK query is complex
        return {}
    }
    
    # Begin transaction (TDBC compatible)
    method begintransaction {} {
        set rs_handle [::ifx::_native_execute $conn_handle "BEGIN WORK"]
        ::ifx::_native_close_result $rs_handle
    }
    
    # Commit transaction (TDBC compatible)
    method commit {} {
        set rs_handle [::ifx::_native_execute $conn_handle "COMMIT WORK"]
        ::ifx::_native_close_result $rs_handle
    }
    
    # Rollback transaction (TDBC compatible)
    method rollback {} {
        set rs_handle [::ifx::_native_execute $conn_handle "ROLLBACK WORK"]
        ::ifx::_native_close_result $rs_handle
    }
    
    # Get/set configuration (TDBC compatible)
    method configure {args} {
        if {[llength $args] == 0} {
            return $options
        } elseif {[llength $args] == 1} {
            set opt [lindex $args 0]
            if {[dict exists $options $opt]} {
                return [dict get $options $opt]
            }
            error "unknown option \"$opt\""
        } else {
            foreach {opt val} $args {
                if {[dict exists $options $opt]} {
                    dict set options $opt $val
                } else {
                    error "unknown option \"$opt\""
                }
            }
        }
    }
    
    # Return native handle (for advanced usage)
    method getDBhandle {} {
        return $conn_handle
    }
}

# Static helpers for statement class
namespace eval ::ifx::odbc::statement {
    # Debug flag check
    variable debugEnabled 0
}

# Static helper: Substitute named parameters (:name) in SQL
proc ::ifx::odbc::statement::SubstituteNamedParams {sql params} {
    # Sort parameter names by length (longest first) to avoid partial matches
    # e.g., :bind should not match before :bind_tabid
    set names [lsort -decreasing -command {apply {{a b} {
        expr {[string length $a] - [string length $b]}
    }}} [dict keys $params]]
    
    foreach name $names {
        set value [dict get $params $name]
        set escaped [::ifx::odbc::connection::EscapeString $value]
        # Use lookahead to match :name followed by non-word char or end of string
        regsub -all ":${name}(?=\[^a-zA-Z0-9_\]|$)" $sql "'$escaped'" sql
    }
    return $sql
}

# Static helper: Substitute positional parameters (?) in SQL
proc ::ifx::odbc::statement::SubstitutePositionalParams {sql params} {
    foreach value $params {
        set idx [string first "?" $sql]
        if {$idx >= 0} {
            set escaped [::ifx::odbc::connection::EscapeString $value]
            set sql "[string range $sql 0 [expr {$idx-1}]]'$escaped'[string range $sql [expr {$idx+1}] end]"
        }
    }
    return $sql
}

# Static helper: Check if debug mode is enabled
proc ::ifx::odbc::statement::IsDebugEnabled {} {
    return [expr {[info exists ::env(IFX_DEBUG)] && $::env(IFX_DEBUG)}]
}

#
# Statement class - TDBC compatible
#
oo::class create ::ifx::odbc::statement {
    variable connection
    variable conn_handle
    variable sql_template
    variable param_types
    variable resultsets
    variable closed
    
    constructor {connObj connHandle sql} {
        set connection $connObj
        set conn_handle $connHandle
        set sql_template $sql
        set param_types {}
        set resultsets {}
        set closed 0
    }
    
    destructor {
        # Close all result sets
        foreach rs $resultsets {
            catch {$rs close}
        }
    }
    
    # Close statement (TDBC compatible)
    method close {} {
        my destroy
    }
    
    # Get connection (TDBC compatible)
    method connection {} {
        return $connection
    }
    
    # Execute with optional parameter dict (TDBC compatible)
    # If params not provided, looks up :varname from caller's scope
    method execute {args} {
        if {$closed} {
            error "statement has been closed"
        }
        
        set sql $sql_template
        
        # Get explicit params if provided
        set params {}
        if {[llength $args] > 0} {
            set params [lindex $args 0]
        }
        
        # Handle named parameters :name
        if {[string first ":" $sql] >= 0} {
            # Find all :name parameters in SQL
            set pattern {:([a-zA-Z_][a-zA-Z0-9_]*)}
            set matches {}
            set tmpSql $sql
            while {[regexp $pattern $tmpSql -> name]} {
                lappend matches $name
                regsub $pattern $tmpSql "" tmpSql
            }
            
            # Build complete params dict - lookup from caller's scope if not provided
            set fullParams {}
            foreach name [lsort -unique $matches] {
                if {[dict exists $params $name]} {
                    dict set fullParams $name [dict get $params $name]
                } else {
                    # Try to get from caller's scope (2 levels up: execute -> foreach/allrows -> user code)
                    # or 1 level up for direct execute calls
                    set found 0
                    for {set level 1} {$level <= 3} {incr level} {
                        if {[catch {uplevel $level [list set $name]} value] == 0} {
                            dict set fullParams $name $value
                            set found 1
                            break
                        }
                    }
                    if {!$found} {
                        error "No value supplied for parameter \"$name\""
                    }
                }
            }
            
            # Substitute all parameters
            if {[dict size $fullParams] > 0} {
                set sql [::ifx::odbc::statement::SubstituteNamedParams $sql $fullParams]
            }
        } elseif {[string first "?" $sql] >= 0 && [llength $params] > 0} {
            # Positional parameters ?
            set sql [::ifx::odbc::statement::SubstitutePositionalParams $sql $params]
        }
        
        # Debug output
        if {[::ifx::odbc::statement::IsDebugEnabled]} {
            puts stderr "Executing SQL: $sql"
        }
        
        # Execute the SQL
        if {[catch {set rs_handle [::ifx::_native_execute $conn_handle $sql]} err]} {
            # Re-throw with more context
            error "SQL execution failed: $err\nSQL: [string range $sql 0 500]"
        }
        
        set rs [::ifx::odbc::resultset new [self] $rs_handle]
        lappend resultsets $rs
        
        return $rs
    }
    
    # Execute and return all rows (TDBC compatible)
    method allrows {args} {
        # Parse -as option and params
        set as "dicts"
        set params {}
        
        set i 0
        while {$i < [llength $args]} {
            set arg [lindex $args $i]
            switch -glob -- $arg {
                -as {
                    incr i
                    set as [lindex $args $i]
                }
                -- {
                    incr i
                    break
                }
                default {
                    break
                }
            }
            incr i
        }
        
        if {$i < [llength $args]} {
            set params [lindex $args $i]
        }
        
        set rs [my execute $params]
        
        set result {}
        if {$as eq "lists"} {
            while {1} {
                set row [$rs nextlist]
                if {$row eq ""} break
                lappend result $row
            }
        } else {
            while {1} {
                set row [$rs nextdict]
                if {$row eq ""} break
                lappend result $row
            }
        }
        
        $rs close
        
        return $result
    }
    
    # Foreach with statement (TDBC compatible)
    method foreach {args} {
        # Parse: ?-as dicts|lists? ?-columnsvariable varName? ?--? varName ?params? script
        set as "dicts"
        set columnsVar ""
        
        set i 0
        while {$i < [llength $args]} {
            set arg [lindex $args $i]
            switch -glob -- $arg {
                -as {
                    incr i
                    set as [lindex $args $i]
                }
                -columnsvariable {
                    incr i
                    set columnsVar [lindex $args $i]
                }
                -- {
                    incr i
                    break
                }
                -* {
                    error "unknown option \"$arg\""
                }
                default {
                    break
                }
            }
            incr i
        }
        
        set remaining [lrange $args $i end]
        
        if {[llength $remaining] == 2} {
            lassign $remaining varName script
            set params {}
        } elseif {[llength $remaining] == 3} {
            lassign $remaining varName params script
        } else {
            error "wrong # args: should be \"foreach ?options? varName ?params? script\""
        }
        
        upvar 1 $varName row
        if {$columnsVar ne ""} {
            upvar 1 $columnsVar columns
        }
        
        set rs [my execute $params]
        
        if {$columnsVar ne ""} {
            set columns [$rs columns]
        }
        
        set result ""
        while {1} {
            if {$as eq "lists"} {
                set row [$rs nextlist]
            } else {
                set row [$rs nextdict]
            }
            
            if {$row eq ""} break
            
            set code [catch {uplevel 1 $script} result opts]
            switch $code {
                0 { }
                1 { 
                    $rs close
                    return -options $opts $result 
                }
                2 { 
                    $rs close
                    return -options $opts $result 
                }
                3 { break }
                4 { continue }
            }
        }
        
        $rs close
        
        return $result
    }
    
    # Get parameter information (TDBC compatible)
    method params {} {
        set result {}
        
        # Find all :name style parameters
        set pattern {:([a-zA-Z_][a-zA-Z0-9_]*)}
        set sql $sql_template
        
        while {[regexp $pattern $sql -> name]} {
            dict set result $name [dict create \
                direction in \
                type varchar \
                precision 0 \
                scale 0 \
                nullable 1 \
            ]
            regsub $pattern $sql "" sql
        }
        
        # Count ? style parameters
        set qcount 0
        set pos 0
        while {[set idx [string first "?" $sql $pos]] >= 0} {
            incr qcount
            dict set result $qcount [dict create \
                direction in \
                type varchar \
                precision 0 \
                scale 0 \
                nullable 1 \
            ]
            set pos [expr {$idx + 1}]
        }
        
        return $result
    }
    
    # Set parameter types (TDBC compatible)
    method paramtype {name args} {
        dict set param_types $name $args
    }
    
    # Get result sets (TDBC compatible)
    method resultsets {} {
        return $resultsets
    }
}

#
# ResultSet class - TDBC compatible
#
oo::class create ::ifx::odbc::resultset {
    variable statement
    variable rs_handle
    variable column_names
    variable columns_fetched
    variable row_count
    
    constructor {stmtObj rsHandle} {
        set statement $stmtObj
        set rs_handle $rsHandle
        set columns_fetched 0
        set column_names {}
        set row_count 0
    }
    
    destructor {
        catch {::ifx::_native_close_result $rs_handle}
    }
    
    # Close result set (TDBC compatible)
    method close {} {
        my destroy
    }
    
    # Get statement (TDBC compatible)
    method statement {} {
        return $statement
    }
    
    # Get column names (TDBC compatible)
    method columns {} {
        if {!$columns_fetched} {
            # Peek at first row to get column names
            set row_dict [::ifx::_native_fetch $rs_handle]
            if {$row_dict ne ""} {
                set column_names [dict keys $row_dict]
                set columns_fetched 1
            }
        }
        return $column_names
    }
    
    # Fetch next row into variable (TDBC compatible)
    # Returns 1 if row fetched, 0 if no more rows
    method nextrow {args} {
        # Parse -as option
        set as "dicts"
        set varName ""
        
        set i 0
        while {$i < [llength $args]} {
            set arg [lindex $args $i]
            switch -glob -- $arg {
                -as {
                    incr i
                    set as [lindex $args $i]
                }
                -- {
                    incr i
                    set varName [lindex $args $i]
                    break
                }
                default {
                    set varName $arg
                }
            }
            incr i
        }
        
        if {$varName eq ""} {
            error "wrong # args: should be \"nextrow ?-as lists|dicts? varName\""
        }
        
        upvar 1 $varName row
        
        set row_dict [::ifx::_native_fetch $rs_handle]
        
        if {$row_dict eq ""} {
            return 0
        }
        
        incr row_count
        
        if {!$columns_fetched} {
            set column_names [dict keys $row_dict]
            set columns_fetched 1
        }
        
        if {$as eq "lists"} {
            set row {}
            foreach col $column_names {
                if {[dict exists $row_dict $col]} {
                    lappend row [dict get $row_dict $col]
                } else {
                    lappend row ""
                }
            }
        } else {
            set row $row_dict
        }
        
        return 1
    }
    
    # Fetch next row as list (TDBC compatible)
    method nextlist {} {
        set row_dict [::ifx::_native_fetch $rs_handle]
        
        if {$row_dict eq ""} {
            return ""
        }
        
        incr row_count
        
        if {!$columns_fetched} {
            set column_names [dict keys $row_dict]
            set columns_fetched 1
        }
        
        set row {}
        foreach col $column_names {
            if {[dict exists $row_dict $col]} {
                lappend row [dict get $row_dict $col]
            } else {
                lappend row ""
            }
        }
        
        return $row
    }
    
    # Fetch next row as dict (TDBC compatible)
    method nextdict {} {
        set row_dict [::ifx::_native_fetch $rs_handle]
        
        if {$row_dict eq ""} {
            return ""
        }
        
        incr row_count
        
        if {!$columns_fetched} {
            set column_names [dict keys $row_dict]
            set columns_fetched 1
        }
        
        return $row_dict
    }
    
    # Get row count (TDBC compatible)
    method rowcount {} {
        return $row_count
    }
}

#
# Package provide
#
package provide ifx::odbc 1.0

#
# Example usage when run as script
#
if {[info script] eq $::argv0} {
    puts "Testing TDBC-compatible Informix Interface (ifx::odbc)...\n"
    
    puts "=== Available datasources ==="
    puts [::ifx::odbc::datasources]
    
    puts "\n=== Test 1: Create named connection (TDBC style) ==="
    ::ifx::odbc::connection create db "DSN=eppixprod"
    puts "Created connection: db"
    
    puts "\n=== Test 2: Prepare and execute ==="
    set stmt [db prepare "SELECT FIRST 3 tabname, tabid FROM systables"]
    set rs [$stmt execute]
    
    puts "Columns: [$rs columns]"
    while {[$rs nextrow row]} {
        puts "Row: $row"
    }
    $rs close
    $stmt close
    
    puts "\n=== Test 3: allrows method ==="
    set rows [db allrows "SELECT FIRST 3 tabname FROM systables"]
    foreach row $rows {
        puts "  $row"
    }
    
    puts "\n=== Test 4: allrows -as lists ==="
    set rows [db allrows -as lists "SELECT FIRST 3 tabname, tabid FROM systables"]
    foreach row $rows {
        puts "  $row"
    }
    
    puts "\n=== Test 5: foreach method ==="
    db foreach -as dicts row "SELECT FIRST 3 tabname FROM systables" {
        puts "  Table: [dict get $row tabname]"
    }
    
    puts "\n=== Test 6: tables method ==="
    set tables [db tables "sys%"]
    puts "Tables matching sys%: [lrange $tables 0 4]..."
    
    puts "\n=== Test 7: Transaction methods ==="
    puts "begintransaction, commit, rollback methods available"
    
    puts "\n=== Test 8: connection new (auto-named) ==="
    set db2 [::ifx::odbc::connection new "DSN=eppixprod"]
    puts "Created auto-named connection: $db2"
    $db2 close
    
    # Cleanup
    db close
    
    puts "\nAll tests completed successfully!"
}

