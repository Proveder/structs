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

.PHONY: test audit audit-fix
