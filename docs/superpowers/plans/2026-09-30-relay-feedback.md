# Relay feedback implementation plan

> **For agentic workers:** Use superpowers:executing-plans for implementation and a whole-branch review before finishing.

**Goal:** Build an opt-in Vizor experiment that shows relay observation and supported inclusion estimates on send receipts and pending transaction details.

**Architecture:** A typed client uses Vizor's NetworkHttpClient. Shared Riverpod watchers poll only while a user has opted in and the relevant unlocked account is visible. Relay evidence is displayed separately from the wallet's authoritative transaction state.

**Tech stack:** Flutter 3.47.2, Dart, Riverpod; existing Rust-backed privacy transport. No new runtime dependencies.

**Spec:** The September 30 conversation's Vizor integration design, approved by "build it". This first increment covers send and activity feedback; swap orchestration and server deployment remain later increments.

## Global constraints

- Disabled unless VIZOR_RELAY_API_URL configures an endpoint; a second, session-only user opt-in is required before requests.
- POST only network and a canonical display-order transaction ID. Never transmit account IDs, amounts, addresses, memos or keys.
- Respect the existing Tor route; no direct fallback. Cancel on disposal, lock, account switch and backgrounding.
- Accept HTTPS endpoints or numeric loopback HTTP for local tunnels. No embedded credentials, queries or fragments.
- Unknown/stale/error evidence is unavailable, not zero inclusion probability or send failure.
- Numeric forecasts require validated=true, synthetic=false and shadow=false; invalid probability distributions are withheld.
- Never alter wallet balances, confirmation state, input locks, retries or spendability based on relay results.
- Preserve all returned IDs for multi-transaction sends; do not aggregate their probabilities as independent events.
- Existing model support governs available horizons. No invented ETA, rare-expiry score or automatic fee recommendation.
- This UI pilot measures feedback after a broadcast result is available; an exact broadcast-start callback and server model promotion are separate work.

## Review focus

- Late responses after lock/account change must not publish private data or restart polling.
- Pending after provisional inclusion must display correctly on reorg.
- Byte-order conversion must happen once at the caller's known boundary.
- Batch sends must not imply the whole payment completed when one ID is included.
- Disabled and unconfigured builds must make zero relay requests and retain existing UI behavior.

### Task 1: Typed protocol and routed client

**Files:** Create `lib/src/features/relay_feedback/relay_forecast.dart`, `relay_forecast_client.dart`, and `test/features/relay_feedback/relay_forecast_test.dart`, `relay_forecast_client_test.dart`.

**Interfaces:** `RelayTransaction(network, txid)` with boundary factory; `RelayForecast.fromJson(data, transaction, now)`; `RelayForecastClient.fetch(transaction, cancelSignal)` returning a typed observation. Endpoint and response identity validation live here.

- [x] Write tests for network/ID normalization, stale/malformed responses, research forecast withholding, valid cumulative probabilities and routed POST payload.
- [x] Observe failures, implement the types/client, then run `fvm flutter test test/features/relay_feedback`.
- [x] Commit the tested protocol/client.

### Task 2: Shared lifecycle tracking and consent panel

**Files:** Create `relay_feedback_provider.dart`, `relay_feedback_panel.dart`, and focused provider/widget tests under `test/features/relay_feedback/`.

**Interfaces:** Panel accepts account UUID and display-order IDs, with an explicit active/pending flag. Providers share one watcher per account/network/txid. Consent is session-local. The panel hides before reading wallet providers when unconfigured.

- [x] Write tests proving no request before consent, shared watching, cancellation/late-response suppression, unavailable fallbacks and inclusion-to-pending transitions.
- [x] Implement bounded serial polling and the accessible panel; run the focused tests.
- [x] Commit the tested watcher and panel.

### Task 3: Integrate send and activity screens

**Files:** Modify desktop/mobile send status and activity status screens, `send_flow.dart`, and the mobile progress component only as needed for an optional supporting widget. Add integration tests to existing send tests and document activation in README.

**Interfaces:** Send outcomes retain every returned ID without changing broadcast behavior. Activity callers explicitly convert protocol-order IDs. Wallet-reported mined/expired transactions stop requesting forecasts.

- [x] Add integration tests for all returned IDs, disabled behavior and pending activity rendering; observe failure.
- [x] Wire the panel into desktop/mobile surfaces and retain existing wallet semantics.
- [ ] Run focused tests, desktop suite, mobile tests for changed surfaces, analysis, and compile a desktop build where the toolchain permits.
- [ ] Review the whole branch, fix material findings with regression tests, commit and push the experiment branch.

## Decisions and progress

- User's direct build instruction authorizes implementation of the presented design without another approval round.
- The existing isolated fork checkout is clean at upstream 4bff2e7. No observer infrastructure or wallet funds are changed.

- Independent review found five important edge cases, all fixed: redirect replay, truncated wallet history, persisted network mismatch, display freshness expiry, and Tor bootstrap timeout.
- The relay client opts out of redirects through a new optional transport argument; existing clients keep the previous default.
- Terminal wallet evidence persists for the unlocked account session and resumes only on explicit wallet pending evidence.
- Validation so far: 104 focused desktop/protocol/transport tests, 52 mobile tests, analyzer clean, and rendered consent/observation panels inspected.
- The initial full desktop run passed 4,858 tests with 136 intentional skips and one receive QR-save failure. The same QR-save test also fails in a separate untouched upstream worktree; no receive code is changed.
- Native debug compilation uses unsigned Xcode settings because the upstream macOS development profile is unavailable on this host. No wallet is launched by validation.
