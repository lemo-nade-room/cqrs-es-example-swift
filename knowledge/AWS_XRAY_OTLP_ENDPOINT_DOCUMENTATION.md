# AWS X-Ray OTLP Endpoint Documentation

## Overview

AWS X-Ray introduced support for the OpenTelemetry Protocol (OTLP) on November 22, 2024. This feature enables direct ingestion of OpenTelemetry traces without requiring format conversion through collectors or agents.

## Release Information

- **Announcement Date**: November 22, 2024
- **Feature**: Native OTLP support for X-Ray trace ingestion
- **Regions**: Available in all regions where AWS Application Signals is available
- **Source**: [AWS Observability Blog](https://aws.amazon.com/blogs/mt/aws-x-ray-w3c-trace-context-support-ga-opentelemetry-otlp-trace-ingest-preview/)

## Endpoint Specifications

### URL Format
```
https://xray.{region}.amazonaws.com/v1/traces
```

### Example Endpoints
- US East (N. Virginia): `https://xray.us-east-1.amazonaws.com/v1/traces`
- Asia Pacific (Tokyo): `https://xray.ap-northeast-1.amazonaws.com/v1/traces`
- Europe (Frankfurt): `https://xray.eu-central-1.amazonaws.com/v1/traces`

### Protocol Details
- **Protocol**: OTLP/HTTP
- **Content-Type**: `application/x-protobuf`
- **Method**: POST
- **Port**: 443 (HTTPS)

## Authentication Requirements

### AWS Signature Version 4 (SigV4)
X-Ray OTLP endpoints require AWS SigV4 authentication:

```
Service Name: xray
Signing Region: {region}
```

### Required IAM Permissions
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "xray:PutTraceSegments",
        "xray:PutTelemetryRecords"
      ],
      "Resource": "*"
    }
  ]
}
```

### Headers Required
- `Authorization`: AWS SigV4 signature
- `Content-Type`: `application/x-protobuf`
- `X-Amz-Date`: Timestamp in ISO 8601 format
- `X-Amz-Security-Token`: (if using temporary credentials)

## Trace ID Format Considerations

### W3C/OTLP vs X-Ray Format

X-Ray and W3C use different trace ID formats:

| Format | Structure | Example |
|--------|-----------|---------|
| W3C/OTLP | 32 hex characters | `4bf92f3577b34da6a3ce929d0e0e4736` |
| X-Ray | 1-{8 hex timestamp}-{24 hex random} | `1-58406520-a006649127e371903a2de979` |

### Conversion Requirements
- When using OTLP directly, trace IDs should follow W3C format
- AWS Distro for OpenTelemetry (ADOT) handles conversion automatically
- Custom implementations may need to handle format differences

## Supported OTLP Versions

- **OTLP Version**: v0.20.0 or later
- **OpenTelemetry Protocol**: OTLP/HTTP Binary Protobuf encoding
- **Trace Format**: OpenTelemetry Trace v1

## Implementation Considerations

### 1. Direct SDK Integration
Most OpenTelemetry SDKs don't natively support SigV4 authentication. Options include:
- Use AWS Distro for OpenTelemetry (ADOT)
- Implement custom exporter with SigV4 signing
- Use OpenTelemetry Collector as proxy

### 2. Supported Languages (via ADOT)
- Go
- Java
- JavaScript/Node.js
- .NET
- Python

### 3. Unsupported Languages
Languages without official ADOT support (like Swift) require:
- Custom SigV4 implementation
- Manual OTLP exporter configuration
- Careful handling of trace ID formats

## Known Limitations and Issues

### 1. Authentication Complexity
- Direct OTLP export requires SigV4 signing
- Many SDKs require collector intermediary

### 2. Error Responses
Common error codes and their meanings:

| Status Code | Meaning | Common Cause |
|------------|---------|--------------|
| 400 | Bad Request | Invalid payload format or missing headers |
| 403 | Forbidden | IAM permission issues |
| 413 | Payload Too Large | Batch size exceeds limits |

### 3. Batch Size Limits
- Maximum batch size: 25 spans
- Maximum payload size: 64KB compressed

## Best Practices

### 1. For Lambda Functions
```yaml
# Use immediate export
Processor: SimpleSpanProcessor

# Add flush middleware
Middleware: OTelFlushMiddleware

# Set environment variables
AWS_XRAY_CONTEXT_MISSING: LOG_ERROR
```

### 2. Error Handling
- Implement retry logic for transient failures
- Log detailed error responses
- Monitor export success rates

### 3. Performance Optimization
- Batch spans efficiently (up to 25)
- Use compression when possible
- Implement proper timeout handling

## Integration with Application Signals

X-Ray OTLP support enables:
- Pre-built service dashboards
- Service Level Objectives (SLOs)
- Service dependency mapping
- Business metric correlation

## Troubleshooting Guide

### Debug Checklist
1. ✓ Verify endpoint URL format
2. ✓ Check IAM permissions
3. ✓ Validate SigV4 signature
4. ✓ Confirm trace ID format
5. ✓ Check payload size limits
6. ✓ Verify OTLP protobuf format

### Common Issues

#### Issue: 400 Bad Request from ELB
**Cause**: Request not reaching X-Ray service
**Solution**: 
- Verify endpoint URL
- Check Content-Type header
- Ensure proper SigV4 signing

#### Issue: TLS Negotiation Failures
**Cause**: Network/SSL configuration
**Solution**:
- Check Lambda VPC settings
- Verify security groups
- Consider VPC endpoints

#### Issue: Missing Traces
**Cause**: Trace ID format mismatch
**Solution**:
- Use W3C format for OTLP
- Implement proper ID generation

## References

1. [AWS X-Ray OTLP Support Announcement](https://aws.amazon.com/blogs/mt/aws-x-ray-w3c-trace-context-support-ga-opentelemetry-otlp-trace-ingest-preview/)
2. [AWS Distro for OpenTelemetry Documentation](https://aws-otel.github.io/docs/)
3. [OpenTelemetry Protocol Specification](https://opentelemetry.io/docs/specs/otlp/)
4. [AWS X-Ray Developer Guide](https://docs.aws.amazon.com/xray/latest/devguide/)
5. [Application Signals Documentation](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/CloudWatch-Application-Signals.html)

## Future Considerations

As of June 2025, consider:
- OTLP support may have expanded to more regions
- Additional language SDKs may have native support
- API specifications may have evolved

Always refer to the latest AWS documentation for current specifications.