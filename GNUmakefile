# GNUmakefile for poDB, built with the installed poc.
#
#   make                 build the poDB libraries under each size model
#   make check           the tests that need no server, under each size model
#   make check-postgres  the tests that need the PostgreSQL test cluster
#   make check-all       check and check-postgres
#   make clean           remove build/
#
# Modules compiled under -O2 cannot be mixed with modules compiled under -OC,
# so each size model builds separately: the libraries in
# build/lib/<triple>/<model>/ (where poc puts them), the test programs in
# build/<model>/test/.  Test programs take Db and the drivers from the
# libraries, never from src/, so the checks test what is installed.

POC ?= poc
MODELS ?= O2 OC
BUILD := build
POCFLAGS ?= -trap-location

TOP := $(abspath .)

LIBDIR := $(BUILD)/lib
DB_SOURCES := src/Db.Mod src/DbCStrings.Mod
SQLITE_SOURCES := src/DbSqlite.Mod
LIBRARIES := db db-sqlite

.PHONY: all check check-postgres check-all clean \
        $(addprefix check-,$(MODELS))

all: $(foreach m,$(MODELS),$(foreach l,$(LIBRARIES),$(LIBDIR)/$(l)-$(m).stamp))

check: $(addprefix check-,$(MODELS))

check-all: check check-postgres

check-postgres:
	@echo "check-postgres: no PostgreSQL tests yet"

clean:
	rm -rf $(BUILD)

# $(call build-library,<model>,<name>,<sources>,<extra poc arguments>)
define build-library
mkdir -p $(LIBDIR) && cd $(LIBDIR) && $(POC) -$(1) $(POCFLAGS) -library-path . $(4) \
  -library $(2) $(addprefix $(TOP)/,$(3))
touch $@
endef

# db-%.stamp also matches db-sqlite-O2.stamp, but GNU make takes the rule
# with the shorter stem, db-sqlite-%.stamp.
$(LIBDIR)/db-sqlite-%.stamp: $(SQLITE_SOURCES) $(LIBDIR)/db-%.stamp
	$(call build-library,$*,db-sqlite,$(SQLITE_SOURCES),-link -lsqlite3)

$(LIBDIR)/db-%.stamp: $(DB_SOURCES)
	$(call build-library,$*,db,$(DB_SOURCES))

# $(call build-program,<model>,<source>,<extra poc arguments>) builds the
# program whose module is in <source> into build/<model>/test/, named after
# the module.  It finds modules beside <source> and in the libraries.
define build-program
cd $(dir $(2)) && $(POC) -$(1) $(POCFLAGS) -library-path $(TOP)/$(LIBDIR) \
  -output-dir $(TOP)/$(BUILD)/$(1)/test \
  -o $(TOP)/$(BUILD)/$(1)/test/$(basename $(notdir $(2))) \
  $(3) $(notdir $(2))
endef

# check-<model> runs every test that needs no server under <model>.
$(addprefix check-,$(MODELS)): check-%: $(LIBDIR)/db-%.stamp $(LIBDIR)/db-sqlite-%.stamp
	@echo "== smoke test (-$*)"
	$(call build-program,$*,test/SmokeSqlite.Mod,-link -lsqlite3)
	$(BUILD)/$*/test/SmokeSqlite > $(BUILD)/$*/test/SmokeSqlite.out
	pkg-config --modversion sqlite3 | diff -u - $(BUILD)/$*/test/SmokeSqlite.out
	@echo "== Db unit tests (-$*)"
	$(call build-program,$*,test/TestDb.Mod)
	$(BUILD)/$*/test/TestDb > $(BUILD)/$*/test/TestDb.out
	diff -u test/TestDb.expected $(BUILD)/$*/test/TestDb.out
	@echo "== DbDemo against the libraries (-$*)"
	$(call build-program,$*,examples/DbDemo.Mod)
	$(BUILD)/$*/test/DbDemo sqlite::memory: > $(BUILD)/$*/test/DbDemo.out
	diff -u test/DbDemo.expected $(BUILD)/$*/test/DbDemo.out
	rm -f $(BUILD)/$*/test/demo.db
	$(BUILD)/$*/test/DbDemo sqlite:$(BUILD)/$*/test/demo.db > $(BUILD)/$*/test/DbDemo.out
	$(BUILD)/$*/test/DbDemo sqlite:$(BUILD)/$*/test/demo.db >> $(BUILD)/$*/test/DbDemo.out
	cat test/DbDemo.expected test/DbDemo.expected | diff -u - $(BUILD)/$*/test/DbDemo.out
	@echo "== DbDemo from source (-$*)"
	cd examples && $(POC) -$* $(POCFLAGS) -import-path $(TOP)/src \
	  -output-dir $(TOP)/$(BUILD)/$*/source -o $(TOP)/$(BUILD)/$*/source/DbDemo \
	  -link -lsqlite3 DbDemo.Mod
	$(BUILD)/$*/source/DbDemo sqlite::memory: | diff -u test/DbDemo.expected -
