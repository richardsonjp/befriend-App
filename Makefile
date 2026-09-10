# Variables
SERVICE_NAME := go-skeleton
BINARY_NAME := bin/$(SERVICE_NAME)
MAIN_PACKAGE := ./cmd/apiserver

# Shell
SHELL := /bin/bash

# Default target
.PHONY: help
help: ## Show this help message
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

.PHONY: build
build: ## Build the application binary
	@echo "Building $(SERVICE_NAME)..."
	go build -o $(BINARY_NAME) $(MAIN_PACKAGE)

.PHONY: run
run: ## Run the application
	go run $(MAIN_PACKAGE) server

.PHONY: config
config: ## Show configuration
	go run $(MAIN_PACKAGE) config

.PHONY: test
test: ## Run tests
	go test -v -race ./...

.PHONY: lint
lint: ## Run go vet
	go vet ./...

.PHONY: tidy
tidy: ## Run go mod tidy
	go mod tidy

.PHONY: deps
deps: ## Download dependencies
	go mod download

.PHONY: clean
clean: ## Clean build artifacts
	@echo "Cleaning..."
	@rm -rf bin/
	@go clean

.PHONY: migration-up
migration-up: ## Run database migrations up
	go run $(MAIN_PACKAGE) migrate up

.PHONY: migration-down
migration-down: ## Run database migrations down
	go run $(MAIN_PACKAGE) migrate down

.PHONY: migration-force
migration-force: ## Force database migration version (usage: make migration-force V=1)
	go run $(MAIN_PACKAGE) migrate force $(V)

.PHONY: migration-version
migration-version: ## Check database migration version
	go run $(MAIN_PACKAGE) migrate version

.PHONY: migration-create
migration-create: ## Create a new migration file (usage: make migration-create NAME=migration_name)
	@if [ -z "$(NAME)" ]; then echo "Error: NAME is required"; exit 1; fi
	migrate create -ext sql -dir cmd/apiserver/app/migrations -seq $(NAME)