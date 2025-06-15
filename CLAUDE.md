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

### X-Ray Integration Details

The Command Server implements AWS X-Ray tracing using OpenTelemetry:

- **Custom X-Ray OTel Exporter** (`Sources/Command/Server/OTel/XRayOTelSpanExporter.swift`): Exports traces to X-Ray's OTLP endpoint (available since November 2024)
- **X-Ray Propagator** (`Sources/Command/Server/OTel/XRayOTelPropagator.swift`): Handles AWS X-Ray trace header format (`x-amzn-trace-id`)
- **Serverless Support**: Uses `OTelFlushMiddleware` to ensure traces are exported before Lambda container freezes
- **Required Environment Variables for X-Ray**:
  - `AWS_ACCESS_KEY_ID`: AWS access key for authentication
  - `AWS_SECRET_ACCESS_KEY`: AWS secret key
  - `AWS_SESSION_TOKEN` (optional): For temporary credentials
  - `AWS_REGION` (optional): Defaults to `ap-northeast-1`
  - `AWS_XRAY_URL` (optional): Custom X-Ray endpoint URL

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
sudo docker build --file ./Sources/Command/Dockerfile --tag command-server:latest .

# Query Server  
sudo docker build --file ./Sources/Query/Dockerfile --tag query-server:latest .
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

## Troubleshooting

### X-Ray Trace Export Issues

If traces are not being exported to X-Ray:

1. **Check logs for export status**:
   ```bash
   tail -f CommandServer.log | grep "\[X-Ray\]"
   ```
   Look for:
   - `[X-Ray] Export started` - Confirms export process initiated
   - `[X-Ray] Successfully exported N spans` - Confirms successful export
   - `[X-Ray] Failed to export spans` - Indicates errors

2. **Common issues**:
   - **Missing AWS credentials**: Ensure environment variables are set
   - **CRTError code 34**: Usually indicates authentication issues
   - **No export logs**: Check that `OTelTracer.run()` and `OTelSpanProcessor.run()` are being called in `configure.swift`

3. **Serverless considerations**:
   - The `OTelFlushMiddleware` ensures traces are exported before Lambda freezes
   - Each request should trigger immediate export due to `OTelSimpleSpanProcessor` usage

## Development Prerequisites

This project requires the following capabilities to work effectively:
- **Swift Package Manager**: `swift build` and `swift test` must work properly
- **Docker**: Individual server Docker builds must succeed for deployment verification
- Commands `swift build`, `swift test`, and the Docker build commands above should all execute successfully

## Important Implementation Notes

- **OpenTelemetry Service Lifecycle**: The `OTelTracer` and `OTelSpanProcessor` implement the `Service` protocol and must be started with their `run()` methods for proper span processing
- **Batch vs Simple Processor**: Currently uses `OTelSimpleSpanProcessor` for immediate export, suitable for serverless environments
- **X-Ray OTLP Endpoint**: Uses the new X-Ray OTLP endpoint format: `https://xray.{region}.amazonaws.com/v1/traces`

## SAM (Serverless Application Model) Tips

### Environment Variables
- **Reserved Variables**: Lambda has reserved environment variables that cannot be set manually. Examples include:
  - `_X_AMZN_TRACE_ID`: Set automatically by Lambda runtime for X-Ray tracing
  - Other AWS-specific variables like `AWS_REGION`, `AWS_LAMBDA_FUNCTION_NAME`, etc.
- Use `sam validate --lint` to check for such issues before deployment

### X-Ray Configuration
- **Tracing**: Set `Tracing: Active` in the `Globals` section for all functions
- **Permissions**: Use `AWSXRayDaemonWriteAccess` managed policy or add specific permissions:
  ```yaml
  Policies:
    - AWSXRayDaemonWriteAccess
    - Statement:
      - Effect: Allow
        Action:
          - xray:PutTraceSegments
          - xray:PutTelemetryRecords
        Resource: '*'
  ```
- **Environment Variables**: Set `AWS_XRAY_CONTEXT_MISSING: LOG_ERROR` to log errors when trace context is missing

## Swift Specific Notes

### ByteStream Type (AWS SDK)
- The `ByteStream` enum in AWS SDK Swift has cases: `.data(Data?)`, `.stream(Stream)`, `.noStream`
- When pattern matching, ensure all cases are handled
- The `.data` case contains an optional `Data?`, so unwrap before use

### Logging with Vapor
- Use `Logger.Message` type for log messages: `logger.notice("\(message)")`
- For deprecated APIs, check encoding requirements (e.g., `String(contentsOfFile:encoding:)`)
```