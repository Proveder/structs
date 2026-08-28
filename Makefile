# Go files tracked by git, expanded lazily by the shell (gopls check needs explicit
# paths - it does not accept ./...). Falls back to find outside a git checkout.
GO_FILES = $$(git ls-files '*.go' 2>/dev/null | xargs -I{} sh -c '[ -f "{}" ] && echo "{}"' || find . -name '*.go' -not -path './vendor/*')

# This package is a struct-tag reflection library, so several of its test
# fixtures are *deliberately* malformed structs - they are the input under test,
# not defects. vet has no per-site suppression comment (staticcheck's
# //lint:ignore is used where it works), so the one structtag finding is filtered
# here instead of disabling the whole analyzer:
#
#   field_test.go  Foo.x  - unexported field carrying `xml:"x"`. TestField_Tag
#                           asserts s.Field("x").Tag("xml") == "x", so removing
#                           the field or the tag breaks the test.
VET_EXCLUDE = 'struct field x has xml tag but is not exported'

# Go <= 1.25 prefixes vet findings with package header lines ("# pkg" and
# "# [pkg]"); Go >= 1.26 prints the bare finding. Those headers survive
# VET_EXCLUDE and would fail the target on their own, so they are dropped
# separately. The full unfiltered output is echoed when a real finding remains,
# so the headers are still there when they carry information.
# (the \# escape is required - a bare # would start a Make comment.)
VET_HEADER = '^\#'

# gopls exclusions, each with a reason:
#
#  1. new(expr) modernizer (Go 1.26): needs a go >= 1.26 module and this one
#     declares go 1.24.4, so it cannot fire. Kept only so the lint target reads
#     identically across the proveder Go repos.
#  2. reflect.TypeOf -> reflect.TypeFor: every site is an assertion of the form
#     `reflect.TypeOf(m).Kind() != reflect.Map`, checking what Map()/Values()
#     actually returned. TypeFor[...] hardcodes the expected type, which makes
#     the assertion tautological and blind to a signature regression - the
#     "modernization" would silently delete the test's purpose.
#  3. structtag / JSON string option: same deliberate fixtures as VET_EXCLUDE
#     above, plus the `json:",string"` fixtures behind TestTagWithStringOption
#     and TestNonStringerTagWithStringOption.
GOPLS_EXCLUDE = 'can be simplified to new\(x\)|inlinable wrapper around new\(expr\)|call can be simplified using TypeFor|struct field x has xml tag but is not exported|the JSON string option only applies to fields'

.PHONY: lint
lint: ## Static analysis: correctness (vet), simplifications (staticcheck), modernizations (gopls)
	@# Every stage runs even if an earlier one reports, so a single invocation shows
	@# the full picture; rc accumulates and the target fails at the end.
	@# Preflight: gopls pins GOTOOLCHAIN=local, so the *installed* go must satisfy
	@# go.work/go.mod on its own — GOTOOLCHAIN=auto silently rescues vet/staticcheck
	@# by downloading a newer toolchain, but gopls then fails with a buried version
	@# error. Surface it up front, with the remedy.
	@if ! chk="$$(GOTOOLCHAIN=local go list -m 2>&1 >/dev/null)"; then \
		echo "==> toolchain preflight failed:"; \
		printf '%s\n' "$$chk" | sed 's/^/  /'; \
		echo "  fix: update the installed Go (macOS: brew upgrade go), then re-run"; \
		exit 1; \
	fi
	@rc=0; \
	echo "==> go vet (correctness)"; \
	vetraw="$$(go vet ./... 2>&1)"; \
	vetout="$$(printf '%s\n' "$$vetraw" | grep -Ev $(VET_EXCLUDE) | grep -Ev $(VET_HEADER) || true)"; \
	if [ -n "$$vetout" ]; then printf '%s\n' "$$vetraw"; rc=1; fi; \
	echo "==> staticcheck (simplifications)"; \
	if command -v staticcheck >/dev/null 2>&1; then \
		staticcheck ./... || rc=1; \
	else \
		echo "  skipped: go install honnef.co/go/tools/cmd/staticcheck@latest"; rc=1; \
	fi; \
	echo "==> gopls (modernizations, unused params)"; \
	if command -v gopls >/dev/null 2>&1; then \
		if ! raw="$$(gopls check -severity=hint $(GO_FILES) 2>&1)"; then \
			echo "  gopls failed to run:"; echo "$$raw"; rc=1; \
		fi; \
		out="$$(printf '%s\n' "$$raw" | grep -Ev $(GOPLS_EXCLUDE) || true)"; \
		if [ -n "$$out" ]; then echo "$$out"; rc=1; fi; \
	else \
		echo "  skipped: go install golang.org/x/tools/gopls@latest"; rc=1; \
	fi; \
	$(MAKE) --no-print-directory crap || rc=1; \
	if [ $$rc -eq 0 ]; then echo "lint: clean"; fi; \
	exit $$rc

.PHONY: test
test:
	@echo "executing unit-tests"
	go test -cover -race ./...

.PHONY: audit
audit:
	@echo "go dependencies audit"
	go list -m all | nancy sleuth

.PHONY: audit-fix
audit-fix: ## Attempt to fix vulnerable dependencies automatically
	@echo "updating Go dependencies to latest patch versions"
	go get -u=patch ./...
	go mod tidy
	@echo "re-running dependency audit"
	go list -m all | nancy sleuth

.PHONY: test audit audit-fix lint

# CRAP (Change Risk Anti-Patterns) = cyclomatic complexity² penalized by
# missing test coverage — ranks the functions most dangerous to change.
# The gate fails when any function scores ABOVE CRAP_THRESHOLD. Mocks
# packages are filtered out of the report entirely: test scaffolding
# carries zero coverage by design and would otherwise own its whole top.
# The threshold was set just above the repo's worst score when the gate
# was introduced — treat it as a RATCHET: lower it as the worst functions
# gain tests or shed complexity; never raise it.
CRAP_THRESHOLD ?= 20
# Rows shown in the report table (worst first). Display-only: the
# threshold gate below still scans EVERY row.
CRAP_MAX_ROWS ?= 25

.PHONY: crap
crap:
	@echo "==> crap4go (CRAP: complexity vs coverage, worst first; threshold $(CRAP_THRESHOLD))"; \
	out="$$(go run github.com/unclebob/crap4go/cmd/crap4go@latest)" || { printf '%s\n' "$$out"; exit 1; }; \
	report="$$(printf '%s\n' "$$out" | sed -n '/^CRAP Report/,$$p' | awk 'NR <= 4 || $$2 != "mocks"')"; \
	display="$$(printf '%s\n' "$$report" | awk -v rows=$(CRAP_MAX_ROWS) ' \
		NR <= 4 { print; next } \
		++n <= rows { print; next } \
		END { if (n > rows) printf "... (%d more rows below the top %d)\n", n - rows, rows }')"; \
	printf '%s\n' "$$display"; \
	if [ -n "$$GITHUB_STEP_SUMMARY" ]; then \
		{ echo '### CRAP report (threshold $(CRAP_THRESHOLD), top $(CRAP_MAX_ROWS))'; echo '```'; printf '%s\n' "$$display"; echo '```'; } >> "$$GITHUB_STEP_SUMMARY"; \
	fi; \
	printf '%s\n' "$$report" | awk -v max=$(CRAP_THRESHOLD) ' \
		/^-+$$/ { in_r = 1; next } \
		in_r && NF >= 5 && ($$NF) + 0 > max { bad = 1; print "  over threshold: " $$0 } \
		END { exit bad }' \
	|| { echo "crap: FAILED (score above $(CRAP_THRESHOLD))"; exit 1; }; \
	echo "crap: clean"
