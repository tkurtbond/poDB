# GNUmakefile for poDB, built with the installed poc.
#
#   make                 build the poDB libraries under each size model
#   make check           the tests that need no server, under each size model
#   make check-postgres  the tests that need the PostgreSQL test cluster
#   make check-all       check and check-postgres
#   make clean           remove build/
#
# Each size model builds in its own directory, build/<model>, because modules
# compiled under -O2 cannot be mixed with modules compiled under -OC.

POC ?= poc
MODELS ?= O2 OC
BUILD := build
POCFLAGS ?= -trap-location

TOP := $(abspath .)

.PHONY: all check check-postgres check-all clean \
        $(addprefix check-,$(MODELS))

all:

check: $(addprefix check-,$(MODELS))

check-all: check check-postgres

check-postgres:
	@echo "check-postgres: no PostgreSQL tests yet"

clean:
	rm -rf $(BUILD)

# $(call build-program,<model>,<source>,<extra poc arguments>) builds the
# program whose module is in <source> into build/<model>/test/, named after
# the module.
define build-program
cd $(dir $(2)) && $(POC) -$(1) $(POCFLAGS) -import-path $(TOP)/src \
  -output-dir $(TOP)/$(BUILD)/$(1)/test \
  -o $(TOP)/$(BUILD)/$(1)/test/$(basename $(notdir $(2))) \
  $(3) $(notdir $(2))
endef

# check-<model> runs every test that needs no server under <model>.
$(addprefix check-,$(MODELS)): check-%:
	@echo "== smoke test (-$*)"
	$(call build-program,$*,test/SmokeSqlite.Mod,-link -lsqlite3)
	$(BUILD)/$*/test/SmokeSqlite > $(BUILD)/$*/test/SmokeSqlite.out
	pkg-config --modversion sqlite3 | diff -u - $(BUILD)/$*/test/SmokeSqlite.out
