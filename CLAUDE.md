# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a CQRS (Command Query Responsibility Segregation) and Event Sourcing example application built with Swift and Vapor. The project demonstrates microservices architecture with separate Command and Query servers, designed to be deployed on AWS Lambda using SAM (Serverless Application Model).

## Architecture

The project follows CQRS/ES principles with:

- **Command Server** (`Sources/Command/Server/`): Handles write operations, uses OpenAPI specification for REST API, includes AWS X-Ray tracing
- **Query Server** (`Sources/Query/Server/`): Handles read operations, includes PostgreSQL database integration via Fluent
- **Separate deployments**: Each server runs as independent Lambda functions behind API Gateway
- **OpenTelemetry**: Command server includes X-Ray tracing integration for observability

## Key Components

- **Package.swift**: Defines two executable targets (`CommandServer`, `QueryServer`) with their respective dependencies
- **OpenAPI Integration**: Command server uses Swift OpenAPI Generator for API generation from `openapi.yaml`  
- **Testing**: Uses Swift Testing framework (not XCTest) with VaporTesting for integration tests
- **Docker**: Both servers containerized for Lambda deployment
- **Infrastructure**: AWS SAM template (`template.yaml`) and Terraform configuration in `Server/AWS/`

## Common Commands

### Development
```bash
# Change to Server directory first
cd Server

# Build the project
swift build

# Run tests
swift test

# Run specific target tests
swift test --filter CommandServerTests
swift test --filter QueryServerTests

# Run Command server locally
swift run CommandServer

# Run Query server locally  
swift run QueryServer
```

### Docker Development
```bash
cd Server

# Build and run with Docker Compose
docker compose build
docker compose up app
docker compose up db
docker compose run migrate

# Build individual server Docker images locally
# Command Server
docker build --file ./Sources/Command/Dockerfile --tag command-server:latest .

# Query Server  
docker build --file ./Sources/Query/Dockerfile --tag query-server:latest .
```

### AWS Deployment
```bash
# Build Lambda containers
sam build

# Deploy to AWS
sam deploy

# Delete deployment
sam delete --stack-name cqrs-es-example-swift-dev
```

## Server Configuration

- **Command Server**: Runs on port 3001 in development, uses OpenAPI spec at `Sources/Command/Server/openapi.yaml`
- **Query Server**: Basic Vapor server with health check endpoints
- **Database**: PostgreSQL via Fluent (Query server only)
- **Environment Variables**: Supports development/staging/production configurations

## Testing Strategy

Tests are organized by server type:
- `Tests/Command/ServerTests/` - Command server tests including OTel components
- `Tests/Query/ServerTests/` - Query server tests  
- Uses Swift Testing framework with `@Test` and `@Suite` annotations
- VaporTesting for HTTP endpoint testing

## Server Management

### Starting CommandServer in Background
```bash
# Change to Server directory
cd Server

# Start CommandServer in background with logging
swift run CommandServer > CommandServer.log 2>&1 &

# Wait for server to start (look for this message in logs)
# [ NOTICE ] Server started on http://127.0.0.1:3001

# Check server logs
tail -f CommandServer.log

# Test server healthcheck
xh GET http://127.0.0.1:3001/command/v1/healthcheck
```

### Restarting Server After Code Changes
```bash
# Find and kill existing server process
lsof -i:3001
kill <PID>

# Start server again
swift run CommandServer > CommandServer.log 2>&1 &
```

### Server Endpoints
- **Health Check**: `GET http://127.0.0.1:3001/command/v1/healthcheck`
- **API Documentation**: See `./Server/Sources/Command/Server/openapi.yaml` for complete API specification

## Development Prerequisites

This project requires the following capabilities to work effectively:
- **Swift Package Manager**: `swift build` and `swift test` must work properly
- **Docker**: Individual server Docker builds must succeed for deployment verification
- Commands `swift build`, `swift test`, and the Docker build commands above should all execute successfully