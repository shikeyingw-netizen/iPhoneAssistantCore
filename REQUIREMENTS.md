# iPhone Assistant Requirements Backlog

## Deferred: AI Customer-Service Manual Takeover Center

Status: requirement captured; full integration deferred until after the
current Swift business-logic migration and SQLite queue phases.

Required behavior:

1. Unified pending-task list for Pinduoduo, Qianniu, and WeChat logistics.
2. Every task must show platform, store, buyer question, order information,
   AI decision reason, suggested reply, and processing timestamps.
3. New pending tasks must produce an on-device local notification.
4. The operator must be able to inspect the original conversation, edit the
   suggestion, enter a manual reply, approve, or reject it.
5. High-risk messages must never be sent before operator approval.
6. AI-unanswerable questions must allow the operator to add a standard answer.
7. Approved answers may be promoted into an on-device knowledge base.
8. Knowledge updates must record modification time and source.
9. A single manual answer must not automatically generalize to similar
   questions. Exact or fuzzy knowledge matches must remain reviewable.
10. Pending manual tasks must survive Runner termination and restart.

Mandatory controls:

- Runs entirely on iPhone during daily operation.
- No Windows dependency, DeepSeek API key, or paid service.
- Global emergency pause for all automatic replies.
- Operator can take over any Pinduoduo, Qianniu, or WeChat conversation.

Implementation status:

- Swift domain types, approval gates, emergency pause, audit events, versioned
  knowledge entries, and store abstraction exist in `AssistantCore`.
- Encrypted SQLite persistence, local-notification scheduling, the takeover UI,
  and platform deep-link integration are still pending.

## Current Migration Priorities

1. Complete the Swift port of existing Python business logic.
2. Implement the encrypted SQLite queue, scheduler, deduplication, and resume.
3. Integrate the tested DeepSeek App driver.
4. Migrate Pinduoduo, Qianniu, and WeChat UI drivers.
5. Add the free GitHub Actions macOS build.
6. Validate 30-minute, 8-hour, and 24-hour device runs.

## Deferred High Priority: Customer-Service History, Logistics State, and Pinduoduo Work Orders

Status: registered only. Do not implement until the current persistent queue,
scheduler, deduplication, and restart-recovery phase is complete and reported.

### Incident That Motivated the Requirement

A buyer asked why an address change had not been made. The AI replied that the
case had not been handled and requested the address again. The merchant had, in
fact, already notified the courier and was waiting for the parcel to reach a
local branch for rescanning and forwarding. The AI had no merchant-action
history, courier-group record, or reliable business-state view.

The customer-service system must distinguish:

- What the customer has said.
- What the merchant has already done.
- What the courier, factory, warehouse, or platform has confirmed.
- What remains unknown and requires human verification.

### Merchant Action Archive

Store every material action with:

1. Platform.
2. Store.
3. Order ID.
4. Buyer identifier.
5. Action type.
6. Action time.
7. Actor or source.
8. Action details.
9. Current outcome.
10. Evidence source.
11. Current processing status.
12. Last update time.

Supported action types must eventually include:

- Courier contacted.
- Address change requested.
- Factory contacted.
- Warehouse notified.
- Shipment interception requested.
- Refund or after-sales action.
- Platform work order submitted.
- Promise made to the customer.

Records must be strictly scoped by store and order. Merchant action records
outrank AI inference. AI must never claim an action occurred without evidence.
If an evidence source such as a WeChat courier group has not been integrated,
the system must explicitly report it as unavailable.

### Business State Tracking

Each business process needs an independent state machine and evidence trail.

Address-change example:

- No request made.
- Courier notified.
- Waiting for branch scanning.
- Forwarding confirmed.
- Courier explicitly rejected the change.
- State uncertain, waiting for human verification.

Future process types:

- Refund.
- Shipment interception.
- Replacement shipment.
- After-sales request.
- Factory communication.
- Platform work order.

States and records must remain in the iPhone-local database and survive Runner
restarts.

### Pre-Reply Verification

Before each AI reply, evaluate:

1. Current customer message.
2. Order-specific chat history.
3. Merchant action archive.
4. Existing logistics handling state.
5. Latest carrier tracking.
6. Accurately order-matched integrated WeChat group records.
7. Pending manual tasks and platform work orders.

If a courier was already notified and the shipment is waiting for branch
scanning:

- Do not request the address again.
- Do not say the merchant failed to handle it.
- Do not admit that no action was taken.
- State only that the courier was notified and forwarding is pending scanning.
- Do not claim success without reliable evidence.

When evidence is missing or conflicting, escalate to human review.

### Pinduoduo Work-Order Feedback

Recognize work-order dialogs and the blue "反馈" entry.

Processing sequence:

1. Pause automatic replies for the current conversation.
2. Read the work-order text.
3. Load related chats and merchant action history.
4. Verify the facts.
5. Proceed only if evidence confirms a platform-recognition error.
6. Open "反馈".
7. Select "系统识别错误".
8. Fill the approved reason "系统".
9. Submit only after explicit human authorization.
10. Read the page to verify the result.
11. Persist the work-order outcome.
12. Resume customer replies only after verification.

Never select "系统识别错误" unconditionally. Never submit twice. If the page
structure or options differ, escalate. Uncertain submission results require
reconciliation and must not be retried blindly.

### Correct Example Response

If the merchant-action archive proves the courier was already notified and the
parcel is waiting for branch scanning:

> 您好，这边已经帮您联系快递反馈修改地址了，目前需要等待包裹到达网点后重新扫描转运，后续以物流更新为准。我们也会继续关注处理进度。

This is an evidence-dependent example, not a universal template.

### Deferred Tests

1. Courier notified, waiting for scanning: do not request the address again.
2. Forwarding confirmed: report the verified result.
3. Courier rejected the change: do not claim success.
4. No merchant-action history: escalate to human.
5. History belongs to another order: do not cross-associate.
6. WeChat group source unavailable: do not pretend it was checked.
7. Runner restart: history and business state survive.
8. Same buyer follows up repeatedly: do not repeat false admissions or request
   duplicate information.
9. Work-order options do not match expectations: escalate.
10. Work-order submission result uncertain: do not resubmit.
11. Human changes business state: subsequent AI reads the latest value.
12. Historical action conflicts with current tracking: pause auto replies and
   escalate.

### Deferred Data and Interface Notes

Future schema should use separate tables for:

- `merchant_actions`
- `business_cases`
- `business_state_transitions`
- `evidence_records`
- `customer_promises`
- `platform_work_orders`

Every record must carry immutable store and order identifiers, a source
timestamp, and a deduplication key. Cross-order reads must be prohibited by
query design, not by prompt instructions.

### Acceptance Requirements

- Real implementation, not only reply templates.
- Versioned local database migration.
- State-transition and history-association tests.
- Runner-restart recovery tests.
- Work-order recognition and manual-confirmation tests.
- Free macOS CI build result.
- Real-device test record.
- No real customer automation or work-order submission without authorization.

## Deferred High Priority: Foreground New-Message Detection for Pinduoduo and Qianniu

Status: registered only. Do not implement until the persistent queue, scheduler,
deduplication, and restart-recovery task is complete and reported.

### Observed Problem

The current implementation primarily relies on notification banners. In real
use, Pinduoduo or Qianniu may be in the foreground when another customer sends
a message. The phone may produce only a sound and no banner. A banner-only
trigger can therefore miss a valid customer message.

### Required Detection Sources

1. Top notification banners: retain the current detector and record platform,
   visible content, and arrival time.
2. Foreground customer-service pages: inspect the current page, only as
   permitted by the app's accessibility tree.
3. Notification Center: retain and extend the notification-center detector.

Foreground page inspection should identify, where reliably exposed:

- New message in the current conversation.
- Changes in conversation-list unread counts.
- New unread markers.
- New customer message content in the active conversation.
- New customer conversations.

Constraints:

- Do not navigate away from the active customer merely to inspect others.
- Do not interrupt input, send, or send-verification operations.
- If the page cannot be interpreted reliably, record a detection failure.
- Do not infer that a message exists when no readable evidence exists.
- Do not claim notification-center success if no matching notification exists.

### Active-Reply Protection

If customer B messages while the system is replying to customer A:

1. Persist customer A's current task and reply.
2. Do not abruptly switch to customer B.
3. Record customer B's message with first-seen time and source.
4. Add customer B to the persistent local queue.
5. Complete or safely pause customer A's current operation.
6. Process customer B according to priority after customer A is safe.

If customer A's send result is uncertain, reconcile before any retry. Customer
B must never cause a cross-conversation send.

### Cross-Source Deduplication and Missed-Detection Records

The same customer message discovered by banners, Notification Center, and page
inspection must create only one task. The eventual identity key should include
reliable platform, store, customer, order, and message-content fields.

Record:

- First discovery time.
- Discovery source or sources.
- Whether it entered the task queue.
- Whether it was processed.
- Detection errors.
- Possible missed detections.

All records must survive an iPhone Runner restart.

### iOS and App Limitations to Verify Later

Do not assume iPhone can force banners for either app. Before implementation,
perform real-device tests of:

1. Whether Pinduoduo and Qianniu banner notifications are enabled.
2. Whether foreground notifications actually show a banner.
3. Whether Notification Center retains the corresponding notification.
4. Whether foreground pages expose other-customer activity through the
   accessibility tree.

If neither banners, Notification Center, nor page contents expose the event,
report the limitation. Do not use jailbreaks, private APIs, paid services, or
other unauthorized bypasses.

### Deferred Test Matrix

1. Pinduoduo foreground, new message with banner.
2. Pinduoduo foreground, sound only, no banner.
3. Qianniu foreground, new message with banner.
4. Qianniu foreground, sound only, no banner.
5. Customer B messages while replying to customer A.
6. Several customers message consecutively.
7. Banner and Notification Center discover the same message.
8. Foreground page exposes a message absent from Notification Center.
9. Restart preserves unprocessed messages.
10. Detection failure is logged rather than silently discarded.

Real-device records must report banner, foreground-page, and notification-center
detection success rates separately.

## Deferred Research: Notification-Sound Detection

Status: registered only and explicitly deferred. No microphone capture, audio
model, background service, or current automation change should be introduced
before the current queue task is complete.

Research questions:

1. Whether an allowed iOS API can observe notification-sound events from
   Pinduoduo or Qianniu.
2. Whether the microphone can reliably recognize characteristic sounds from
   those apps.
3. Whether the two apps' sounds can be distinguished.
4. Whether foreground sounds can be detected.
5. Whether audio monitoring can coexist safely with customer-service UI work.
6. Whether the approach complies with iOS permissions and background rules.

Required constraints:

- Do not assume third-party notification sounds or sound events are readable
  through a public iOS API.
- Do not assume a normal app can record or listen indefinitely in the
  background.
- Do not degrade current UI automation through microphone capture or audio
  processing.
- Sound is only an auxiliary alert.
- Every sound event must be verified through page or notification evidence
  before creating or replying to a customer task.
- If reliable implementation is impossible, report the exact limitation.

The deferral is intentional. This research must not alter the current queue,
scheduler, idempotency, or recovery implementation.
