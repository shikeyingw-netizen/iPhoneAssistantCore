# iPhoneAssistantCore

This Swift package is the first migration slice of the existing Python
customer-service automation. The Python implementation remains the production
path until the Swift package passes macOS CI and device tests.

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

Not migrated yet:

- Notification-center observer.
- Notification-center observer.
- iCTRL/XCTest platform drivers.
- Pinduoduo, Qianniu, and WeChat UI drivers.
- Encrypted on-device logs and manual confirmation UI.

Run the package tests on a macOS host:

```bash
swift test
```
