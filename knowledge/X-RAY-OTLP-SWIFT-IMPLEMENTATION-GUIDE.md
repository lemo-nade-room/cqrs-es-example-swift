# X-Ray OTLP Swift Implementation Guide

## Overview

This guide documents the implementation challenges and solutions for integrating AWS X-Ray OTLP endpoint with Swift/OpenTelemetry, based on our investigation and implementation attempts.

## Implementation Status

### Current State (June 2025)
- **Status**: 400 Bad Request errors from X-Ray OTLP endpoint
- **Root Cause**: Request being rejected at ELB level before reaching X-Ray service
- **Implementation**: Custom XRayOTelSpanExporter with SigV4 authentication

## Architecture

```
Swift App → OpenTelemetry SDK → XRayOTelSpanExporter → AWS X-Ray OTLP Endpoint
                                         ↓
                                   AWS SigV4 Signing
```

## Key Components Implemented

### 1. XRayOTelSpanExporter
Located at: `Sources/Command/Server/OTel/XRayOTelSpanExporter.swift`

Features:
- AWS SigV4 authentication using AWS SDK for Swift
- OTLP protobuf serialization
- Batch processing (max 25 spans)
- Detailed debug logging
- Error handling and retry logic

### 2. XRayIDGenerator
Located at: `Sources/Command/Server/OTel/XRayIDGenerator.swift`

Note: Currently generates standard W3C trace IDs due to Swift library limitations

### 3. XRayOTelPropagator
Located at: `Sources/Command/Server/OTel/XRayOTelPropagator.swift`

Handles X-Ray trace header format:
```
X-Amzn-Trace-Id: Root=1-5e1be3d3-1234567890123456;Parent=1234567890123456;Sampled=1
```

### 4. OTelFlushMiddleware
Ensures spans are exported before Lambda container freezes

## Configuration

### Lambda Configuration (template.yaml)
```yaml
Globals:
  Function:
    Tracing: Active

CommandServerFunction:
  Properties:
    Environment:
      Variables:
        AWS_XRAY_CONTEXT_MISSING: LOG_ERROR
    Policies:
      - AWSXRayDaemonWriteAccess
      - Statement:
        - Effect: Allow
          Action:
            - xray:PutTraceSegments
            - xray:PutTelemetryRecords
          Resource: '*'
```

### OpenTelemetry Setup (configure.swift)
```swift
let exporter = XRayOTelSpanExporter(
    awsAccessKey: Environment.get("AWS_ACCESS_KEY_ID") ?? "",
    awsSecretAccessKey: Environment.get("AWS_SECRET_ACCESS_KEY") ?? "",
    awsSessionToken: Environment.get("AWS_SESSION_TOKEN"),
    region: Environment.get("AWS_REGION") ?? "ap-northeast-1",
    client: ClientConfigurationDefaults.makeClient(),
    logger: app.logger
)

let processor = OTelSimpleSpanProcessor(exporter: exporter)
let tracer = OTelTracer(
    idGenerator: XRayIDGenerator(),
    sampler: OTelConstantSampler(isOn: true),
    propagator: XRayOTelPropagator(logger: app.logger),
    processor: processor,
    resource: resource
)
```

## Current Issues and Debugging

### 1. 400 Bad Request Error
**Symptoms**:
- Response from `awselb/2.0` (not X-Ray service)
- HTML error page returned
- Request rejected at load balancer level

**Debug Information Added**:
- Request payload hex dump
- Response headers logging
- Environment variable inspection
- Trace ID format validation

### 2. Potential Root Causes

#### A. Missing Headers
Current implementation might be missing X-Ray-specific headers:
- `X-Amzn-Xray-Format: otlp` (already added)
- Additional headers may be required

#### B. Trace ID Format
X-Ray expects specific format, but OTLP uses W3C format:
- Need to investigate if X-Ray OTLP endpoint accepts W3C format
- Current XRayIDGenerator doesn't generate X-Ray format due to library limitations

#### C. Network Configuration
Lambda may require special configuration:
- VPC endpoints for X-Ray
- Security group rules
- NAT gateway configuration

## Alternative Approaches

### 1. Use OpenTelemetry Collector
Deploy collector as sidecar or separate service:
```yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: localhost:4317

exporters:
  awsxray:
    region: ap-northeast-1

service:
  pipelines:
    traces:
      receivers: [otlp]
      exporters: [awsxray]
```

### 2. AWS Distro for OpenTelemetry (ADOT) Lambda Layer
Not directly available for Swift, but could be used with custom runtime

### 3. Traditional X-Ray SDK Approach
Abandon OTLP and use X-Ray segments directly (not recommended)

## Debug Commands

### Test Endpoint Connectivity
```bash
curl -I -X POST https://xray.ap-northeast-1.amazonaws.com/v1/traces \
  -H "Content-Type: application/x-protobuf" \
  -H "Accept: application/x-protobuf"
```

### Verify IAM Permissions
```bash
aws xray put-trace-segments --trace-segment-documents '{"trace_id": "1-581cf771-a006649127e371903a2de979", "id": "70de5b6f19ff9a0a", "start_time": 1.478293361271E9, "end_time": 1.478293361449E9, "name": "test"}' --region ap-northeast-1
```

### Check Lambda Logs
```bash
sam logs -n CommandServerFunction --tail
```

## Lessons Learned

### 1. Swift/OpenTelemetry Challenges
- Limited ecosystem compared to other languages
- No official AWS support for Swift OpenTelemetry
- Manual SigV4 implementation required

### 2. X-Ray OTLP Specifics
- Endpoint expects specific format/headers beyond standard OTLP
- Documentation is limited for direct SDK integration
- Most examples assume collector usage

### 3. Lambda Considerations
- Must use SimpleSpanProcessor for immediate export
- Flush middleware critical for span delivery
- Environment variables can conflict with reserved names

## Next Steps for Resolution

1. **Contact AWS Support**
   - Clarify exact OTLP endpoint requirements
   - Confirm if W3C trace IDs are accepted
   - Get example of working request

2. **Implement Request Capture**
   - Use proxy to capture successful ADOT requests
   - Compare with our implementation

3. **Test with Collector**
   - Deploy OpenTelemetry Collector
   - Verify if issue is with direct integration

4. **Consider Alternative Monitoring**
   - Evaluate other APM solutions with better Swift support
   - Consider custom metrics/logging approach

## References

- [Our Implementation](../Sources/Command/Server/OTel/)
- [Work Progress](../Server/WORK_PROGRESS.md)
- [X-Ray OTLP Documentation](AWS_XRAY_OTLP_ENDPOINT_DOCUMENTATION.md)
- [Lambda Configuration](../Server/template.yaml)