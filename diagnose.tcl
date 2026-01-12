#!/usr/bin/env tclsh
#
# Diagnostic script for ifx::odbc connection issues
#

puts "=== Environment Check ==="
puts ""

# Check required environment variables
set required_vars {INFORMIXDIR INFORMIXSERVER INFORMIXSQLHOSTS}
set missing {}

foreach var $required_vars {
    if {[info exists ::env($var)] && $::env($var) ne ""} {
        puts "✓ $var = $::env($var)"
    } else {
        puts "✗ $var = (NOT SET)"
        lappend missing $var
    }
}

# Check optional ODBC variables
puts ""
puts "=== ODBC Environment ==="
foreach var {ODBCINI ODBCSYSINI} {
    if {[info exists ::env($var)] && $::env($var) ne ""} {
        puts "  $var = $::env($var)"
    } else {
        puts "  $var = (not set, using defaults)"
    }
}

# Check LD_LIBRARY_PATH
puts ""
puts "=== Library Path ==="
if {[info exists ::env(LD_LIBRARY_PATH)]} {
    puts "LD_LIBRARY_PATH includes:"
    foreach path [split $::env(LD_LIBRARY_PATH) :] {
        if {$path ne ""} {
            puts "  $path"
        }
    }
} else {
    puts "✗ LD_LIBRARY_PATH is NOT SET"
    lappend missing "LD_LIBRARY_PATH"
}

# Check if Informix CLI library exists
puts ""
puts "=== Informix CLI Library ==="
if {[info exists ::env(INFORMIXDIR)]} {
    set cli_path "$::env(INFORMIXDIR)/lib/cli/libifcli.so"
    if {[file exists $cli_path]} {
        puts "✓ $cli_path exists"
    } else {
        puts "✗ $cli_path NOT FOUND"
    }
}

# Check if sqlhosts exists
puts ""
puts "=== SQLHosts File ==="
if {[info exists ::env(INFORMIXSQLHOSTS)]} {
    if {[file exists $::env(INFORMIXSQLHOSTS)]} {
        puts "✓ $::env(INFORMIXSQLHOSTS) exists"
    } else {
        puts "✗ $::env(INFORMIXSQLHOSTS) NOT FOUND"
    }
}

# Check odbc.ini
puts ""
puts "=== ODBC Configuration ==="
set odbc_files {}
if {[info exists ::env(ODBCINI)] && $::env(ODBCINI) ne ""} {
    lappend odbc_files $::env(ODBCINI)
}
lappend odbc_files [file join [file normalize ~] .odbc.ini]
lappend odbc_files "/etc/odbc.ini"

foreach f $odbc_files {
    if {[file exists $f]} {
        puts "✓ $f exists"
    } else {
        puts "  $f (not found)"
    }
}

if {[llength $missing] > 0} {
    puts ""
    puts "=== ERRORS ==="
    puts "Missing required environment variables: $missing"
    puts ""
    puts "Run this before your script:"
    puts "  source /home/hugo/code/tclifx/env.sh"
    puts "  export LD_LIBRARY_PATH=/opt/ifx/lib:/opt/ifx/lib/cli:\$LD_LIBRARY_PATH"
    exit 1
}

# Try to load the extension
puts ""
puts "=== Loading Extension ==="
set script_dir [file dirname [info script]]
if {[catch {load [file join $script_dir libifxcli.so] Ifxcli} err]} {
    puts "✗ Failed to load libifxcli.so: $err"
    puts ""
    puts "Make sure LD_LIBRARY_PATH includes:"
    puts "  /opt/ifx/lib"
    puts "  /opt/ifx/lib/cli"
    exit 1
}
puts "✓ libifxcli.so loaded"

# Try connection
puts ""
puts "=== Testing Connection ==="
puts "Connecting to DSN=eppixprod..."
flush stdout

if {[catch {
    set conn [::ifx::connect "eppixprod"]
    puts "✓ Connected: $conn"
    ::ifx::disconnect $conn
    puts "✓ Disconnected"
} err]} {
    puts "✗ Connection failed: $err"
    exit 1
}

puts ""
puts "=== All checks passed! ==="

