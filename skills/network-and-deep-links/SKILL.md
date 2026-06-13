---
name: network-and-deep-links
description: "Start/stop network traffic captures, analyze HTTP request profiles, and validate Android/iOS deep link configurations."
---

# Network Profiling and Deep Link Validation

Use this skill when you need to inspect HTTP requests/responses, analyze network performance, or validate app deep linking configurations on Android and iOS.

## Exposed Tools
*   `get_network_profile`: Retrieves current network profile request histories.
*   `start_network_capture`: Begins a stateful capture session for HTTP network traffic.
*   `stop_network_capture`: Ends the capture session and retrieves request histories.
*   `validate_deep_links`: Validates scheme/host configurations on Android and iOS.

## Guidelines & Workflows

### 1. Network Capture and Profiling
*   To trace network requests triggered by a specific action (e.g. login submission):
    - Run `start_network_capture` to begin capturing traffic.
    - Ask the user to execute the flow.
    - Run `stop_network_capture` to get the list of requests.
*   Sort or filter the requests (using `sortBy: "time"`, `sortBy: "duration"`, or `sortBy: "size"`).
*   Look for failed requests (non-2xx status codes), high latency, or large payloads. Pass `includeRawResponse: true` if you need to read the full payload body.

### 2. Validating Deep Links
*   If deep links are not launching the app or navigating to the correct screen:
    - Call `validate_deep_links` with `platform: "android"` or `platform: "ios"`.
    - Provide the build configuration / build variant parameters if targetting custom schemes.
    - Review the generated validation report to identify errors in `AndroidManifest.xml` (Android App Links) or `Runner.entitlements` (iOS Universal Links).
