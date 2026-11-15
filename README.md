# iPhoneAssistantCore

This Swift package is the Swift migration of the existing Python
customer-service automation. The Python implementation remains the production
path until the iOS Runner passes device tests.

Migrated in this slice:

- Merchant shipping, delivery, trial, product-scope, and formula rules.
- Risk classification and high-risk handoff replies.
- Platform-notification filtering.
- PII redaction.
- Stable message and logistics idempotency keys.
- DeepSeek App prompt construction without a DeepSeek API key.
- Explicit task-state transitions.
- The send-uncertain safety rule: never resend blindly.
- Encrypted SQLite task persistence, priority claims, idempotency, and restart
  recovery.
- Logistics interception and address-change validation.
- Manual takeover task state, approval gates, emergency pause, audit events,
  and versioned local knowledge entries.
- DeepSeek App driver contract, accessibility parsing, stable-answer detection,
  rate-limit/login detection, and a fake-bridge 10-turn test.
- iCTRL protocol-v1 HMAC encryption, authenticated request/response envelopes,
  time-skew retry, and a concrete DeepSeek App bridge.
- Foreground-bundle verification before the DeepSeek bridge reads or taps UI.
- Generic customer-turn answer detection from newly added, stable DeepSeek
  answer nodes, without requiring a known answer token.

Not migrated yet:

- Notification-center observer.
- iCTRL/XCTest platform drivers.
- Pinduoduo, Qianniu, and WeChat UI drivers.
- Encrypted on-device logs and manual confirmation UI.
- Keychain provisioning of the paired iCTRL credential.
- A fresh real-device run of the concrete iCTRL bridge.

Run the package tests on a macOS host:

```bash
swift test
```
