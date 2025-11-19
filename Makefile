# Makefile for Web3-Trade-Pmm Project

# Default target
.DEFAULT_GOAL := help

# Variables
FOUNDRY_PROFILE ?= default
RPC_URL ?= http://localhost:8545
PRIVATE_KEY ?= 
ETHERSCAN_API_KEY ?= 

# Colors for output
GREEN := \033[0;32m
YELLOW := \033[0;33m
RED := \033[0;31m
NC := \033[0m # No Color

.PHONY: help install update build test test-verbose test-gas clean fmt lint deploy-local deploy-testnet deploy-mainnet verify

help: ## Display this help message
	@echo "$(GREEN)Web3-Trade-Pmm Makefile Commands:$(NC)"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "$(YELLOW)%-20s$(NC) %s\n", $$1, $$2}'

install: ## Install dependencies
	@echo "$(GREEN)Installing dependencies...$(NC)"
	forge install OpenZeppelin/openzeppelin-contracts-upgradeable@v4.8.1 --no-git
	forge install OpenZeppelin/openzeppelin-contracts@v4.8.1 --no-git
	forge install foundry-rs/forge-std --no-git
	@echo "$(GREEN)Dependencies installed successfully!$(NC)"

update: ## Update dependencies
	@echo "$(GREEN)Updating dependencies...$(NC)"
	forge update
	@echo "$(GREEN)Dependencies updated successfully!$(NC)"

build: ## Build the project
	@echo "$(GREEN)Building project...$(NC)"
	forge build
	@echo "$(GREEN)Build completed successfully!$(NC)"

test: ## Run tests
	@echo "$(GREEN)Running tests...$(NC)"
	forge test

test-verbose: ## Run tests with verbose output
	@echo "$(GREEN)Running tests with verbose output...$(NC)"
	forge test -vvv

test-gas: ## Run tests with gas reporting
	@echo "$(GREEN)Running tests with gas reporting...$(NC)"
	forge test --gas-report

test-coverage: ## Run tests with coverage
	@echo "$(GREEN)Running tests with coverage...$(NC)"
	forge coverage

test-specific: ## Run specific test (usage: make test-specific TEST=testFunctionName)
	@echo "$(GREEN)Running specific test: $(TEST)...$(NC)"
	forge test --match-test $(TEST) -vvv

clean: ## Clean build artifacts
	@echo "$(GREEN)Cleaning build artifacts...$(NC)"
	forge clean
	@echo "$(GREEN)Clean completed!$(NC)"

fmt: ## Format code
	@echo "$(GREEN)Formatting code...$(NC)"
	forge fmt
	@echo "$(GREEN)Code formatted successfully!$(NC)"

fmt-check: ## Check code formatting
	@echo "$(GREEN)Checking code formatting...$(NC)"
	forge fmt --check

lint: ## Run linter
	@echo "$(GREEN)Running linter...$(NC)"
	forge fmt --check
	@echo "$(GREEN)Linting completed!$(NC)"

snapshot: ## Create gas snapshot
	@echo "$(GREEN)Creating gas snapshot...$(NC)"
	forge snapshot

anvil: ## Start local Anvil node
	@echo "$(GREEN)Starting Anvil local node...$(NC)"
	anvil

deploy-local: ## Deploy to local network
	@echo "$(GREEN)Deploying to local network...$(NC)"
	forge script script/Deploy.s.sol:DeployScript --rpc-url $(RPC_URL) --private-key $(PRIVATE_KEY) --broadcast

deploy-testnet: ## Deploy to testnet (requires RPC_URL and PRIVATE_KEY)
	@echo "$(GREEN)Deploying to testnet...$(NC)"
	@if [ -z "$(RPC_URL)" ] || [ -z "$(PRIVATE_KEY)" ]; then \
		echo "$(RED)Error: RPC_URL and PRIVATE_KEY must be set$(NC)"; \
		echo "Usage: make deploy-testnet RPC_URL=your_rpc_url PRIVATE_KEY=your_private_key"; \
		exit 1; \
	fi
	forge script script/Deploy.s.sol:DeployScript --rpc-url $(RPC_URL) --private-key $(PRIVATE_KEY) --broadcast --verify

deploy-mainnet: ## Deploy to mainnet (requires RPC_URL and PRIVATE_KEY)
	@echo "$(YELLOW)WARNING: Deploying to MAINNET!$(NC)"
	@echo "$(RED)Make sure you have reviewed the deployment script carefully!$(NC)"
	@read -p "Are you sure you want to continue? (y/N): " confirm && [ "$$confirm" = "y" ]
	@if [ -z "$(RPC_URL)" ] || [ -z "$(PRIVATE_KEY)" ]; then \
		echo "$(RED)Error: RPC_URL and PRIVATE_KEY must be set$(NC)"; \
		echo "Usage: make deploy-mainnet RPC_URL=your_rpc_url PRIVATE_KEY=your_private_key"; \
		exit 1; \
	fi
	forge script script/Deploy.s.sol:DeployScript --rpc-url $(RPC_URL) --private-key $(PRIVATE_KEY) --broadcast --verify

deploy-arbitrum: ## Deploy to Arbitrum One (requires PRIVATE_KEY and ARBISCAN_API_KEY)
	@echo "$(GREEN)Deploying to Arbitrum One...$(NC)"
	@if [ -z "$(PRIVATE_KEY)" ]; then \
		echo "$(RED)Error: PRIVATE_KEY must be set$(NC)"; \
		echo "Usage: make deploy-arbitrum PRIVATE_KEY=your_private_key"; \
		exit 1; \
	fi
	forge script script/DeployArbitrum.s.sol:DeployArbitrum --rpc-url https://arb1.arbitrum.io/rpc --private-key $(PRIVATE_KEY) --broadcast --verify --etherscan-api-key $(ARBISCAN_API_KEY)

deploy-arbitrum-dry: ## Dry run deployment to Arbitrum One
	@echo "$(GREEN)Dry run deployment to Arbitrum One...$(NC)"
	@if [ -z "$(PRIVATE_KEY)" ]; then \
		echo "$(RED)Error: PRIVATE_KEY must be set$(NC)"; \
		echo "Usage: make deploy-arbitrum-dry PRIVATE_KEY=your_private_key"; \
		exit 1; \
	fi
	forge script script/DeployArbitrum.s.sol:DeployArbitrum --rpc-url https://arb1.arbitrum.io/rpc --private-key $(PRIVATE_KEY)

verify: ## Verify contract on Etherscan (requires CONTRACT_ADDRESS and ETHERSCAN_API_KEY)
	@echo "$(GREEN)Verifying contract...$(NC)"
	@if [ -z "$(CONTRACT_ADDRESS)" ] || [ -z "$(ETHERSCAN_API_KEY)" ]; then \
		echo "$(RED)Error: CONTRACT_ADDRESS and ETHERSCAN_API_KEY must be set$(NC)"; \
		echo "Usage: make verify CONTRACT_ADDRESS=0x... ETHERSCAN_API_KEY=your_api_key"; \
		exit 1; \
	fi
	forge verify-contract $(CONTRACT_ADDRESS) src/PmmProtocol.sol:PmmProtocol --etherscan-api-key $(ETHERSCAN_API_KEY)

verify-arbitrum: ## Verify contract on Arbitrum (requires CONTRACT_ADDRESS and ARBISCAN_API_KEY)
	@echo "$(GREEN)Verifying contract on Arbitrum...$(NC)"
	@if [ -z "$(CONTRACT_ADDRESS)" ] || [ -z "$(ARBISCAN_API_KEY)" ]; then \
		echo "$(RED)Error: CONTRACT_ADDRESS and ARBISCAN_API_KEY must be set$(NC)"; \
		echo "Usage: make verify-arbitrum CONTRACT_ADDRESS=0x... ARBISCAN_API_KEY=your_api_key"; \
		exit 1; \
	fi
	forge verify-contract $(CONTRACT_ADDRESS) src/PmmProtocol.sol:PmmProtocol --chain-id 42161 --constructor-args $$(cast abi-encode "constructor(address)" 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1) --etherscan-api-key $(ARBISCAN_API_KEY)

verify-arbitrum-script: ## Run verification script for Arbitrum (requires CONTRACT_ADDRESS)
	@echo "$(GREEN)Running Arbitrum verification script...$(NC)"
	@if [ -z "$(CONTRACT_ADDRESS)" ]; then \
		echo "$(RED)Error: CONTRACT_ADDRESS must be set$(NC)"; \
		echo "Usage: make verify-arbitrum-script CONTRACT_ADDRESS=0x..."; \
		exit 1; \
	fi
	CONTRACT_ADDRESS=$(CONTRACT_ADDRESS) forge script script/VerifyArbitrum.s.sol:VerifyArbitrum --rpc-url https://arb1.arbitrum.io/rpc

size: ## Check contract sizes
	@echo "$(GREEN)Checking contract sizes...$(NC)"
	forge build --sizes

remappings: ## Generate remappings
	@echo "$(GREEN)Generating remappings...$(NC)"
	forge remappings > remappings.txt
	@echo "$(GREEN)Remappings generated in remappings.txt$(NC)"

tree: ## Display dependency tree
	@echo "$(GREEN)Displaying dependency tree...$(NC)"
	forge tree

# Development workflow targets
dev-setup: install build ## Complete development setup
	@echo "$(GREEN)Development environment setup complete!$(NC)"

pre-commit: fmt lint test ## Run pre-commit checks
	@echo "$(GREEN)Pre-commit checks completed successfully!$(NC)"

ci: install build test test-coverage ## Run CI pipeline
	@echo "$(GREEN)CI pipeline completed successfully!$(NC)"

# Utility targets
show-config: ## Show Foundry configuration
	@echo "$(GREEN)Foundry configuration:$(NC)"
	forge config

show-version: ## Show Foundry version
	@echo "$(GREEN)Foundry version:$(NC)"
	forge --version 