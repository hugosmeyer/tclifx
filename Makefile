# Makefile for Informix CLI Tcl extension

#INFORMIXDIR = /home/hugo/ifx
TCL_VERSION = 8.6

# Find Tcl headers and libraries
TCL_INCLUDE = /opt/sup/tcl/include
TCL_LIB = /opt/sup/tcl/lib

# Compiler and flags
CC = gcc
CFLAGS = -fPIC -Wall -O2 -std=c99 -Wimplicit-function-declaration
INCLUDES = -I$(TCL_INCLUDE) -I$(INFORMIXDIR)/incl/cli
LDFLAGS = -shared
LIBS = -L$(INFORMIXDIR)/lib/cli -lifcli -ltcl$(TCL_VERSION)

# Target
TARGET = libifxcli.so
SOURCE = ifxcli.c

all: $(TARGET)

$(TARGET): $(SOURCE)
	$(CC) $(CFLAGS) $(INCLUDES) $(LDFLAGS) -o $(TARGET) $(SOURCE) $(LIBS)

clean:
	rm -f $(TARGET) *.o

install: $(TARGET)
	#mkdir -p $(HOME)/.local/lib/tcl
	#cp $(TARGET) $(HOME)/.local/lib/tcl/
	#@echo "Installed to $(HOME)/.local/lib/tcl/"
	#@echo "Add to your Tcl script: lappend auto_path $(HOME)/.local/lib/tcl"

	cp $(TARGET) $(TCL_LIB)/
	@echo "Installed to $(TCL_LIB)/"
	@echo "Add to your Tcl script: lappend auto_path $(TCL_LIB)/"

test: $(TARGET)
	LD_LIBRARY_PATH=$(INFORMIXDIR)/lib:$(INFORMIXDIR)/lib/cli:$$LD_LIBRARY_PATH \
	tclsh test_ifxcli.tcl

.PHONY: all clean install test

