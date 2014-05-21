#################### 
GROUP_NUMBER := 11
####################

ERLC := erlc #This is the standard Erlang compiler.
ERLC_FLAGS := -W -I include

ERL_FILES := $(wildcard src/*.erl) #Creates a list of .erl files from source.
BEAM_FILES := $(patsubst src/%.erl,ebin/%.beam,${ERL_FILES}) #Creates a list of .beam files by replacing the .erl by .beam in src.

comma:= ,
empty:=
space:= $(empty) $(empty)

EDOC_SRC := $(filter-out %_test.erl, $(ERL_FILES)) #Filters out all test-functions from the ERL_FILES.
EDOC_SRC_LIST := [$(subst $(space),$(comma),$(patsubst src/%.erl,'src/%.erl', $(EDOC_SRC)))] #Creates a punctuated list from EDOC_SRC.

REQUIRED_DIR_NAME := pop_2014_project_group_$(GROUP_NUMBER) #Creates pop_2014_project_group_11

PROJECT_DIR := $(notdir $(shell pwd)) #Creates a path to the project.

USER=$(shell whoami) #The username of the current user.
ARCHIVE_NAME :=  $(REQUIRED_DIR_NAME)_archive_$(USER)_$(shell date "+%Y-%m-%d__%H:%M:%S")__.tar.gz #Generate an Archive name.
ARCHIVE_DIR := .. 

all: $(BEAM_FILES) #Just creating the .beam files? Shouldent this be ERL_FILES

ebin/%.beam: src/%.erl #Some sort of a compilation?
	$(ERLC) $(ERLC_FLAGS) -o ebin $<

start: all 
	(cd ebin && erl -eval 'foo:start(), init:stop()')

test: all
	(cd ebin && erl -noinput -eval 'eunit:test({dir, "."}, [verbose]), init:stop()')

doc: $(BEAM_FILES) 
	erl -noshell -eval "edoc:files($(EDOC_SRC_LIST), [{dir, 'doc/html'},{private,true}])" -s init stop

clean:
	rm -fr .#* *.dump
	rm -fr ebin/*.beam
	(cd doc/html && find . -name "*" -a ! -name overview.edoc -exec rm -rf {} \;)

remove_finderinfo:
	-xattr -d "com.apple.FinderInfo" src/*.erl include/*.hrl doc/* doc/html/*

archive: clean
ifeq ($(REQUIRED_DIR_NAME), $(PROJECT_DIR))
	(cd $(ARCHIVE_DIR) && tar cvfz $(ARCHIVE_NAME) $(PROJECT_DIR) )
	@echo 
	@echo NOTE: Archive created in $(ARCHIVE_DIR)/$(ARCHIVE_NAME)
	@echo 
else
	@echo Error: Wrong directory name >$(PROJECT_DIR)<, change to >$(REQUIRED_DIR_NAME)<
endif

