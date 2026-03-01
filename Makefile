.PHONY: deps deps-plenary fmt lint stylua stylua-check selene rustfmt rustfmt-check rust-lint license-check test rust-build rust-test lua-test bench bench-index bench-search bench-html bench-compare bench-quick

CC ?= cc
NVIM ?= nvim
GIT ?= git
PLENARY_PATH ?= deps/plenary.nvim

deps: deps-plenary

deps-plenary:
	@if [ ! -d "$(PLENARY_PATH)" ]; then \
		mkdir -p "$$(dirname "$(PLENARY_PATH)")"; \
		$(GIT) clone --depth 1 https://github.com/nvim-lua/plenary.nvim "$(PLENARY_PATH)"; \
	fi

fmt: stylua rustfmt

lint: stylua-check selene rustfmt-check rust-lint

stylua:
	stylua .

stylua-check:
	stylua --check .

selene:
	selene ./lua ./plugin ./tests

rustfmt:
	cd rust && cargo fmt

rustfmt-check:
	cd rust && cargo fmt -- --check

rust-lint:
	cd rust && cargo clippy --all-targets -- -D warnings

license-check:
	cd rust && cargo deny check licenses

rust-build:
	cd rust && cargo build --release

rust-test:
	cd rust && cargo test

test: lua-test rust-test

lua-test: deps rust-build
	PLENARY_PATH="$(PLENARY_PATH)" \
		$(NVIM) --headless -u tests/minimal_init.lua \
		-c "lua require('plenary.test_harness').test_directory('tests', {minimal_init = 'tests/minimal_init.lua'})"

bench: bench-index bench-search

bench-index:
	cd rust && cargo bench --bench index_bench -- --save-baseline main

bench-search:
	cd rust && cargo bench --bench search_bench -- --save-baseline main

bench-html:
	cd rust && cargo bench -- --save-baseline main

bench-compare:
	cd rust && cargo bench -- --baseline main

bench-quick:
	cd rust && cargo bench -- --sample-size 10
