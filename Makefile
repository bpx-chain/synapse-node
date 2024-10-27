# Copyright (c) 2022 Status Research & Development GmbH. Licensed under
# either of:
# - Apache License, version 2.0
# - MIT license
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.
BUILD_SYSTEM_DIR := vendor/nimbus-build-system
EXCLUDED_NIM_PACKAGES := vendor/nim-dnsdisc/vendor
LINK_PCRE := 0
LOG_LEVEL := TRACE

# we don't want an error here, so we can handle things later, in the ".DEFAULT" target
-include $(BUILD_SYSTEM_DIR)/makefiles/variables.mk


ifeq ($(NIM_PARAMS),)
# "variables.mk" was not included, so we update the submodules.
GIT_SUBMODULE_UPDATE := git submodule update --init --recursive
.DEFAULT:
	+@ echo -e "Git submodules not found. Running '$(GIT_SUBMODULE_UPDATE)'.\n"; \
		$(GIT_SUBMODULE_UPDATE); \
		echo
# Now that the included *.mk files appeared, and are newer than this file, Make will restart itself:
# https://www.gnu.org/software/make/manual/make.html#Remaking-Makefiles
#
# After restarting, it will execute its original goal, so we don't have to start a child Make here
# with "$(MAKE) $(MAKECMDGOALS)". Isn't hidden control flow great?

else # "variables.mk" was included. Business as usual until the end of this file.


##########
## Main ##
##########
.PHONY: all update clean

# default target, because it's the first one that doesn't start with '.'
all: | synapse libwaku

synapse.nims:
	ln -s synapse.nimble $@

update: | update-common
	rm -rf synapse.nims && \
		$(MAKE) synapse.nims $(HANDLE_OUTPUT)

clean:
	rm -rf build

# must be included after the default target
-include $(BUILD_SYSTEM_DIR)/makefiles/targets.mk

## Possible values: prod; debug
TARGET ?= prod

## Git version
GIT_VERSION ?= $(shell git describe --abbrev=6 --always --tags)
## Compilation parameters. If defined in the CLI the assignments won't be executed
NIM_PARAMS := $(NIM_PARAMS) -d:git_version=\"$(GIT_VERSION)\"

## Heaptracker options
HEAPTRACKER ?= 0
HEAPTRACKER_INJECT ?= 0
ifeq ($(HEAPTRACKER), 1)
# Needed to make nimbus-build-system use the Nim's 'heaptrack_support' branch
DOCKER_NIM_COMMIT := NIM_COMMIT=heaptrack_support
TARGET := debug

ifeq ($(HEAPTRACKER_INJECT), 1)
# the Nim compiler will load 'libheaptrack_inject.so'
HEAPTRACK_PARAMS := -d:heaptracker -d:heaptracker_inject
else
# the Nim compiler will load 'libheaptrack_preload.so'
HEAPTRACK_PARAMS := -d:heaptracker
endif

endif
## end of Heaptracker options

##################
## Dependencies ##
##################
.PHONY: deps libbacktrace

rustup:
ifeq (, $(shell which cargo))
# Install Rustup if it's not installed
# -y: Assume "yes" for all prompts
# --default-toolchain stable: Install the stable toolchain
	curl https://sh.rustup.rs -sSf | sh -s -- -y --default-toolchain stable
endif

anvil: rustup
ifeq (, $(shell which anvil))
# Install Anvil if it's not installed
	./scripts/install_anvil.sh
endif

deps: | deps-common nat-libs synapse.nims


### nim-libbacktrace

# "-d:release" implies "--stacktrace:off" and it cannot be added to config.nims
ifeq ($(USE_LIBBACKTRACE), 0)
NIM_PARAMS := $(NIM_PARAMS) -d:debug -d:disable_libbacktrace
else
NIM_PARAMS := $(NIM_PARAMS) -d:release
endif

libbacktrace:
	+ $(MAKE) -C vendor/nim-libbacktrace --no-print-directory BUILD_CXX_LIB=0

clean-libbacktrace:
	+ $(MAKE) -C vendor/nim-libbacktrace clean $(HANDLE_OUTPUT)

# Extend deps and clean targets
ifneq ($(USE_LIBBACKTRACE), 0)
deps: | libbacktrace
endif

ifeq ($(POSTGRES), 1)
NIM_PARAMS := $(NIM_PARAMS) -d:postgres -d:nimDebugDlOpen
endif

clean: | clean-libbacktrace


##################
##     RLN      ##
##################
.PHONY: librln

LIBRLN_BUILDDIR := $(CURDIR)/vendor/zerokit
ifeq ($(RLN_V2),true)
LIBRLN_VERSION := v0.4.1
else
LIBRLN_VERSION := v0.3.4
endif

ifeq ($(OS),Windows_NT)
LIBRLN_FILE := rln.lib
else
LIBRLN_FILE := librln_$(LIBRLN_VERSION).a
endif

$(LIBRLN_FILE):
	echo -e $(BUILD_MSG) "$@" && \
		./scripts/build_rln.sh $(LIBRLN_BUILDDIR) $(LIBRLN_VERSION) $(LIBRLN_FILE)


librln: | $(LIBRLN_FILE)
	$(eval NIM_PARAMS += --passL:$(LIBRLN_FILE) --passL:-lm)
ifeq ($(RLN_V2),true)
	$(eval NIM_PARAMS += -d:rln_v2)
endif


clean-librln:
	cargo clean --manifest-path vendor/zerokit/rln/Cargo.toml
	rm -f $(LIBRLN_FILE)

# Extend clean target
clean: | clean-librln


##########
## Synapse ##
##########
.PHONY: synapse

synapse: | build deps librln
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim synapse $(NIM_PARAMS) synapse.nims

rln-db-inspector: | build deps librln
	echo -e $(BUILD_MSG) "build/$@" && \
	$(ENV_SCRIPT) nim rln_db_inspector $(NIM_PARAMS) synapse.nims


################
## Synapse tools ##
################
.PHONY: tools synapsecanary networkmonitor

tools: networkmonitor synapsecanary

synapsecanary: | build deps librln
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim synapsecanary $(NIM_PARAMS) synapse.nims

networkmonitor: | build deps librln
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim networkmonitor $(NIM_PARAMS) synapse.nims



################
## C Bindings ##
################
.PHONY: cbindings cwaku_example libwaku

STATIC ?= false

libwaku: | build deps librln
		rm -f build/libwaku*
ifeq ($(STATIC), true)
		echo -e $(BUILD_MSG) "build/$@.a" && \
		$(ENV_SCRIPT) nim libwakuStatic $(NIM_PARAMS) synapse.nims
else
		echo -e $(BUILD_MSG) "build/$@.so" && \
		$(ENV_SCRIPT) nim libwakuDynamic $(NIM_PARAMS) synapse.nims
endif

endif # "variables.mk" was not included
