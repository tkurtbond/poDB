# GNUmakefile for poDB, built with the installed poc.
#
#   make                 build the poDB libraries under each size model, with
#                        and without debug information (-g)
#   make install         install them in $(POCLIBDIR), ~/.local/lib/poc by default
#   make uninstall       remove them from $(POCLIBDIR)
#   make check           the tests that need no server, under each size model
#   make check-postgres  the tests that need the PostgreSQL test cluster
#   make check-all       check and check-postgres
#   make check-valgrind  Conformance under valgrind, for leaks and memory errors
#   make clean           remove build/
#
# Modules compiled under -O2 cannot be mixed with modules compiled under -OC,
# so each size model builds separately: the libraries in
# build/lib/<triple>/<variant>/ (where poc puts them; a variant is O2, OC,
# O2-g or OC-g), the test programs in build/<model>/test/.  Test programs
# take Db and the drivers from the libraries, never from src/, so the
# checks test what is installed.

POC ?= poc
MODELS ?= O2 OC
BUILD := build
POCFLAGS ?= -trap-location
PREFIX ?= $(HOME)/.local
POCLIBDIR ?= $(PREFIX)/lib/poc

# An installed library on POC_LIBRARY_PATH would be taken in place of this
# checkout's source, or would stop the build if another poc wrote it.
unexport POC_LIBRARY_PATH

# A library records the poc that built it, and another poc refuses it, so
# each library depends on poc itself.
POCBIN := $(shell command -v $(POC))

TOP := $(abspath .)

LIBDIR := $(BUILD)/lib
DB_SOURCES := src/Db.Mod src/DbCStrings.Mod
SQLITE_SOURCES := src/DbSqlite.Mod
POSTGRES_SOURCES := src/DbPostgres.Mod src/DbPostgres.c
LIBRARIES := db db-sqlite db-postgres
VARIANTS := $(MODELS) $(addsuffix -g,$(MODELS))

# $(call variant-flags,<variant>) gives poc's flags for a variant: O2-g gives
# -O2 -g.
variant-flags = -$(firstword $(subst -, ,$(1))) $(if $(filter %-g,$(1)),-g)

.PHONY: all install uninstall check check-postgres check-all check-valgrind clean \
        $(addprefix check-,$(MODELS)) $(addprefix check-postgres-,$(MODELS))

all: $(foreach v,$(VARIANTS),$(foreach l,$(LIBRARIES),$(LIBDIR)/$(l)-$(v).stamp))

# install copies each library, in each variant, into $(POCLIBDIR).  A
# program then finds them with -library-path $(POCLIBDIR); installed in
# poc's own directory (POCLIBDIR=/usr/lib/poc, as root) it finds them with
# none.
define newline


endef

install: all
	$(foreach v,$(VARIANTS),$(foreach l,$(LIBRARIES),$(POC) $(call variant-flags,$(v)) \
	  -library-path $(LIBDIR) -install-library $(l) -output-dir $(POCLIBDIR)$(newline)))

# uninstall removes from $(POCLIBDIR)/<triple>/<variant> what install put
# there: each library's .library, .a and .so (.so.0.0 on OpenBSD), and each
# module's .sym and .owner.  It leaves other libraries' files alone, and
# removes a directory only when nothing is left in it.  The triple is poc's
# target.
MODULES := $(basename $(notdir $(filter %.Mod,$(DB_SOURCES) $(SQLITE_SOURCES) $(POSTGRES_SOURCES))))
INSTALLED_FILES := $(foreach l,$(LIBRARIES),$(l).library lib$(l).a lib$(l).so lib$(l).so.0.0) \
  $(foreach m,$(MODULES),$(m).sym $(m).owner)

uninstall:
	@triple=$$($(POC) -version | sed -n 's/^target \([^ ]*\).*/\1/p'); \
	if [ -z "$$triple" ]; then echo "uninstall: cannot get the target from $(POC) -version" >&2; exit 1; fi; \
	for v in $(VARIANTS); do \
	  dir=$(POCLIBDIR)/$$triple/$$v; \
	  if [ -d "$$dir" ]; then \
	    echo "cd $$dir && rm -f $(INSTALLED_FILES)"; \
	    (cd "$$dir" && rm -f $(INSTALLED_FILES)) || exit 1; \
	    rmdir "$$dir" 2>/dev/null || :; \
	  fi; \
	done; \
	rmdir $(POCLIBDIR)/$$triple 2>/dev/null || :; \
	rmdir $(POCLIBDIR) 2>/dev/null || :

check: $(addprefix check-,$(MODELS))

check-all: check check-postgres

# check-postgres runs against $$PODB_PG_URL if it is set.  Otherwise it starts
# the test cluster in build/pgdata, runs the tests and stops the cluster,
# whether or not they pass.
check-postgres: all
	@if [ -n "$$PODB_PG_URL" ]; then \
	  $(MAKE) --no-print-directory $(addprefix check-postgres-,$(MODELS)); \
	else \
	  test/pg-start.sh || exit 1; \
	  $(MAKE) --no-print-directory $(addprefix check-postgres-,$(MODELS)); status=$$?; \
	  test/pg-stop.sh; exit $$status; \
	fi

# check-valgrind runs Conformance (-O2) under valgrind with each driver and
# fails on a memory error or on any block still allocated at exit that is
# not the collector's own, so a statement or result the driver forgot to
# free fails it.  test/valgrind.supp hides the reports that poc's
# conservative collector causes.  It starts and stops the test cluster as
# check-postgres does.
VALGRIND := valgrind -q --leak-check=full --show-leak-kinds=all --errors-for-leak-kinds=all \
  --error-exitcode=1 --suppressions=test/valgrind.supp

check-valgrind: check-O2
	@echo "== conformance under valgrind, SQLite (-O2)"
	$(VALGRIND) $(BUILD)/O2/test/Conformance sqlite::memory: > $(BUILD)/O2/test/Conformance-valgrind.out
	diff -u test/Conformance.expected $(BUILD)/O2/test/Conformance-valgrind.out
	@echo "== conformance under valgrind, PostgreSQL (-O2)"
	@if [ -n "$$PODB_PG_URL" ]; then started=; else test/pg-start.sh || exit 1; started=yes; fi; \
	$(VALGRIND) $(BUILD)/O2/test/Conformance "$$(test/pg-url.sh)" > $(BUILD)/O2/test/Conformance-valgrind.out; \
	status=$$?; \
	if [ -n "$$started" ]; then test/pg-stop.sh; fi; \
	[ $$status -eq 0 ] && diff -u test/Conformance.expected $(BUILD)/O2/test/Conformance-valgrind.out

clean:
	rm -rf $(BUILD)

# $(call build-library,<variant>,<name>,<sources>,<extra poc arguments>)
define build-library
mkdir -p $(LIBDIR) && cd $(LIBDIR) && $(POC) $(call variant-flags,$(1)) $(POCFLAGS) -library-path . $(4) \
  -library $(2) $(addprefix $(TOP)/,$(3))
touch $@
endef

# The stem is the variant.  db-%.stamp also matches db-sqlite-O2.stamp, but
# GNU make takes the rule with the shorter stem, db-sqlite-%.stamp.
$(LIBDIR)/db-sqlite-%.stamp: $(SQLITE_SOURCES) $(LIBDIR)/db-%.stamp $(POCBIN)
	$(call build-library,$*,db-sqlite,$(SQLITE_SOURCES),-link -lsqlite3)

# poc finds DbPostgres.c beside DbPostgres.Mod and compiles it as the
# module's C part, so only the module is named.
$(LIBDIR)/db-postgres-%.stamp: $(POSTGRES_SOURCES) $(LIBDIR)/db-%.stamp $(POCBIN)
	$(call build-library,$*,db-postgres,src/DbPostgres.Mod,-link -lpq)

$(LIBDIR)/db-%.stamp: $(DB_SOURCES) $(POCBIN)
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
$(addprefix check-,$(MODELS)): check-%: $(addprefix $(LIBDIR)/,$(addsuffix -%.stamp,$(LIBRARIES)))
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
	  -link -lsqlite3 -link -lpq DbDemo.Mod
	$(BUILD)/$*/source/DbDemo sqlite::memory: | diff -u test/DbDemo.expected -
	@echo "== conformance, SQLite (-$*)"
	$(call build-program,$*,test/Conformance.Mod)
	$(BUILD)/$*/test/Conformance sqlite::memory: > $(BUILD)/$*/test/Conformance-sqlite.out
	diff -u test/Conformance.expected $(BUILD)/$*/test/Conformance-sqlite.out

# check-postgres-<model> runs the PostgreSQL tests under <model>, against
# the URL that test/pg-url.sh prints.
$(addprefix check-postgres-,$(MODELS)): check-postgres-%: $(addprefix $(LIBDIR)/,$(addsuffix -%.stamp,$(LIBRARIES)))
	@echo "== DbDemo, PostgreSQL (-$*)"
	$(call build-program,$*,examples/DbDemo.Mod)
	$(BUILD)/$*/test/DbDemo "$$(test/pg-url.sh)" > $(BUILD)/$*/test/DbDemo-postgres.out
	$(BUILD)/$*/test/DbDemo "$$(test/pg-url.sh)" >> $(BUILD)/$*/test/DbDemo-postgres.out
	cat test/DbDemo.expected test/DbDemo.expected | diff -u - $(BUILD)/$*/test/DbDemo-postgres.out
	@echo "== conformance, PostgreSQL (-$*)"
	$(call build-program,$*,test/Conformance.Mod)
	$(BUILD)/$*/test/Conformance "$$(test/pg-url.sh)" > $(BUILD)/$*/test/Conformance-postgres.out
	diff -u test/Conformance.expected $(BUILD)/$*/test/Conformance-postgres.out
	@echo "== PostgreSQL only (-$*)"
	$(call build-program,$*,test/TestPostgres.Mod)
	$(BUILD)/$*/test/TestPostgres "$$(test/pg-url.sh)" > $(BUILD)/$*/test/TestPostgres.out
	diff -u test/TestPostgres.expected $(BUILD)/$*/test/TestPostgres.out
