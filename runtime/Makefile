# MaluDB Release 1.0 local model runtime build
#
# Drives the vendored llama.cpp build at third_party/llama.cpp through its
# CMake build system. Intentionally separate from the PGXS extension build
# (the top-level Makefile) so that the PostgreSQL extension never depends on
# llama.cpp being built.
#
# Targets:
#   make           build CPU release (default)
#   make cuda      shortcut for GGML_CUDA=1 build
#   make configure run cmake configure only
#   make clean     remove build artifacts but keep CMake cache
#   make distclean remove the entire build directory
#   make print     print the resolved binary/library paths
#
# Variables:
#   GGML_CUDA      set to 1 to enable CUDA backend (default 0, CPU-only)
#   BUILD_TYPE     CMake build type (default Release)
#   JOBS           parallel build jobs (default $(nproc))

ROOT      := $(abspath $(CURDIR)/..)
LLAMA_SRC := $(ROOT)/third_party/llama.cpp
BUILD_DIR := $(LLAMA_SRC)/build

GGML_CUDA  ?= 0
BUILD_TYPE ?= Release
JOBS       ?= $(shell nproc 2>/dev/null || echo 2)

CMAKE_FLAGS := \
	-DCMAKE_BUILD_TYPE=$(BUILD_TYPE) \
	-DLLAMA_BUILD_TESTS=OFF \
	-DLLAMA_BUILD_EXAMPLES=OFF \
	-DLLAMA_BUILD_TOOLS=ON \
	-DLLAMA_BUILD_SERVER=ON \
	-DLLAMA_CURL=OFF \
	-DGGML_CUDA=$(if $(filter 1 ON on true,$(GGML_CUDA)),ON,OFF)
# NOTE: at the pinned llama.cpp commit (b9019) the `llama-cli` target lives
# in tools/cli/ and is gated by LLAMA_BUILD_SERVER, not LLAMA_BUILD_EXAMPLES.
# Upstream bundled cli + server under one flag at this version. Enabling
# SERVER also builds the optional server binary, which we don't run.

LLAMA_CLI := $(BUILD_DIR)/bin/llama-cli
LIBLLAMA  := $(BUILD_DIR)/bin/libllama.so

.PHONY: all build configure cuda clean distclean print check-submodule

all: build

check-submodule:
	@if [ ! -f "$(LLAMA_SRC)/CMakeLists.txt" ]; then \
		echo "ERROR: $(LLAMA_SRC) is empty. Run:"; \
		echo "  git submodule update --init --recursive third_party/llama.cpp"; \
		exit 1; \
	fi

configure: check-submodule
	cmake -S $(LLAMA_SRC) -B $(BUILD_DIR) $(CMAKE_FLAGS)

build: configure
	cmake --build $(BUILD_DIR) --target llama llama-cli -j $(JOBS)
	@echo
	@echo "runtime build OK"
	@echo "  llama-cli: $(LLAMA_CLI)"
	@echo "  libllama:  $(LIBLLAMA)"

cuda:
	$(MAKE) GGML_CUDA=1 build

clean:
	@if [ -d "$(BUILD_DIR)" ]; then cmake --build $(BUILD_DIR) --target clean; fi

distclean:
	rm -rf $(BUILD_DIR)

print:
	@echo "LLAMA_SRC  = $(LLAMA_SRC)"
	@echo "BUILD_DIR  = $(BUILD_DIR)"
	@echo "LLAMA_CLI  = $(LLAMA_CLI)"
	@echo "LIBLLAMA   = $(LIBLLAMA)"
	@echo "GGML_CUDA  = $(GGML_CUDA)"
	@echo "BUILD_TYPE = $(BUILD_TYPE)"
	@echo "JOBS       = $(JOBS)"
