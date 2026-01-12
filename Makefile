# Makefile for Informix CLI Tcl extension (ifx::odbc)

TCL_VERSION = 8.6

# Installation directories
PREFIX = /opt/sup/tcl
PKGDIR = $(PREFIX)/lib/tclifx

# Find Tcl headers and libraries
TCL_INCLUDE = /usr/include/tcl8.6
TCL_LIB = /usr/lib/x86_64-linux-gnu

# Compiler and flags
CC = gcc
CFLAGS = -fPIC -Wall -O2 -std=c99 -Wimplicit-function-declaration
INCLUDES = -I$(TCL_INCLUDE) -I$(INFORMIXDIR)/incl/cli
LDFLAGS = -shared
LIBS = -L$(INFORMIXDIR)/lib/cli -lifcli -ltcl$(TCL_VERSION)

# Files
TARGET = libifxcli.so
SOURCE = ifxcli.c
TCL_FILES = libIfxTdbc.tcl libInformix.tcl libInformixOO.tcl pkgIndex.tcl

all: $(TARGET)

$(TARGET): $(SOURCE)
	$(CC) $(CFLAGS) $(INCLUDES) $(LDFLAGS) -o $(TARGET) $(SOURCE) $(LIBS)

clean:
	rm -f $(TARGET) *.o

# Install to $(PKGDIR) - creates proper Tcl package structure
# Usage: sudo make install
# Then: export TCLLIBPATH="/opt/sup/tcl/lib"
install: $(TARGET)
	@echo "Installing ifx::odbc package to $(PKGDIR)..."
	mkdir -p $(PKGDIR)
	cp $(TARGET) $(PKGDIR)/
	cp $(TCL_FILES) $(PKGDIR)/ 2>/dev/null || true
	cp pkgIndex.tcl $(PKGDIR)/
	cp libIfxTdbc.tcl $(PKGDIR)/
	@echo ""
	@echo "=== Installation Complete ==="
	@echo "Package installed to: $(PKGDIR)"
	@echo ""
	@echo "To use, add this to your shell profile (.bashrc):"
	@echo "  export TCLLIBPATH=\"$(PREFIX)/lib\""
	@echo ""
	@echo "Then in Tcl:"
	@echo "  package require ifx::odbc"
	@echo ""

# Install to user's home directory (no sudo needed)
install-user: $(TARGET)
	@echo "Installing ifx::odbc package to ~/.local/lib/tcl/tclifx..."
	mkdir -p $(HOME)/.local/lib/tcl/tclifx
	cp $(TARGET) $(HOME)/.local/lib/tcl/tclifx/
	cp pkgIndex.tcl $(HOME)/.local/lib/tcl/tclifx/
	cp libIfxTdbc.tcl $(HOME)/.local/lib/tcl/tclifx/
	@echo ""
	@echo "=== Installation Complete ==="
	@echo "Package installed to: $(HOME)/.local/lib/tcl/tclifx"
	@echo ""
	@echo "To use, add this to your shell profile (.bashrc):"
	@echo "  export TCLLIBPATH=\"$(HOME)/.local/lib/tcl\""
	@echo ""

test: $(TARGET)
	LD_LIBRARY_PATH=$(INFORMIXDIR)/lib:$(INFORMIXDIR)/lib/cli:$$LD_LIBRARY_PATH \
	tclsh test_ifxcli.tcl

test-tdbc: $(TARGET)
	LD_LIBRARY_PATH=$(INFORMIXDIR)/lib:$(INFORMIXDIR)/lib/cli:$$LD_LIBRARY_PATH \
	tclsh test_tdbc.tcl

.PHONY: all clean install install-user test test-tdbc

