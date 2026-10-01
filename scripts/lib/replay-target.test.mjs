// Tests for the replay-target retry / warm-up helpers used by replay.mjs.
// Run with `node --test scripts/`.

import assert from "node:assert/strict";
import { test } from "node:test";

import {
  createHealthTracker,
  isTransientResponse,
  sendWithRetry,
  waitUntilReady,
} from "./replay-target.mjs";

const ok = { status: 200, text: '{"ok":true}' };
const unavailable = { status: 503, text: "<!DOCTYPE html><title>error</title>" };

function scripted(responses) {
  const calls = [];
  const send = async () => {
    const next = responses[calls.length];
    calls.push(next);
    if (next instanceof Error) throw next;
    return next;
  };
  return { send, calls };
}

function recordingSleep() {
  const waits = [];
  return { sleep: async (ms) => void waits.push(ms), waits };
}

// ---------------------------------------------------------------------------
// isTransientResponse
// ---------------------------------------------------------------------------

test("isTransientResponse: a 200 JSON response is not transient", () => {
  assert.equal(isTransientResponse(ok), false);
});

test("isTransientResponse: a 4xx JSON response is not transient", () => {
  assert.equal(isTransientResponse({ status: 413, text: '{"ok":false,"error":"too large"}' }), false);
});

test("isTransientResponse: a 5xx response is transient", () => {
  assert.equal(isTransientResponse({ status: 503, text: '{"ok":false}' }), true);
});

test("isTransientResponse: a JSON 429 rate-limit response is transient", () => {
  assert.equal(isTransientResponse({ status: 429, text: '{"ok":false,"error":"rate limit exceeded"}' }), true);
});

test("isTransientResponse: a non-JSON body is transient even with status 200", () => {
  assert.equal(isTransientResponse({ status: 200, text: "<html>" }), true);
});

// ---------------------------------------------------------------------------
// sendWithRetry
// ---------------------------------------------------------------------------

test("sendWithRetry: returns the first response without waiting when it is not transient", async () => {
  const { send, calls } = scripted([ok]);
  const { sleep, waits } = recordingSleep();
  assert.deepEqual(await sendWithRetry(send, { sleep }), ok);
  assert.equal(calls.length, 1);
  assert.deepEqual(waits, []);
});

test("sendWithRetry: retries a transient response with exponential backoff until it succeeds", async () => {
  const { send, calls } = scripted([unavailable, unavailable, ok]);
  const { sleep, waits } = recordingSleep();
  assert.deepEqual(await sendWithRetry(send, { retries: 3, baseDelayMs: 100, sleep }), ok);
  assert.equal(calls.length, 3);
  assert.deepEqual(waits, [100, 200]);
});

test("sendWithRetry: returns the last transient response once retries are exhausted", async () => {
  const { send, calls } = scripted([unavailable, unavailable, unavailable]);
  const { sleep } = recordingSleep();
  assert.deepEqual(await sendWithRetry(send, { retries: 2, baseDelayMs: 1, sleep }), unavailable);
  assert.equal(calls.length, 3);
});

test("sendWithRetry: retries a thrown network error and rethrows it once retries are exhausted", async () => {
  const { send, calls } = scripted([new Error("timed out"), new Error("timed out")]);
  const { sleep } = recordingSleep();
  await assert.rejects(sendWithRetry(send, { retries: 1, baseDelayMs: 1, sleep }), /timed out/);
  assert.equal(calls.length, 2);
});

// ---------------------------------------------------------------------------
// waitUntilReady
// ---------------------------------------------------------------------------

function fakeClock() {
  let t = 0;
  return {
    now: () => t,
    sleep: async (ms) => {
      t += ms;
    },
  };
}

test("waitUntilReady: resolves true after the required number of consecutive good responses", async () => {
  const { send, calls } = scripted([unavailable, ok, unavailable, ok, ok, ok]);
  const clock = fakeClock();
  const ready = await waitUntilReady(send, { consecutive: 3, intervalMs: 10, timeoutMs: 1000, ...clock });
  assert.equal(ready, true);
  assert.equal(calls.length, 6);
});

test("waitUntilReady: resolves false when the target never stabilises before the timeout", async () => {
  const { send } = scripted(Array(100).fill(unavailable));
  const clock = fakeClock();
  const ready = await waitUntilReady(send, { consecutive: 3, intervalMs: 10, timeoutMs: 50, ...clock });
  assert.equal(ready, false);
});

test("waitUntilReady: a thrown network error resets the consecutive count instead of aborting", async () => {
  const { send } = scripted([ok, new Error("ECONNRESET"), ok, ok]);
  const clock = fakeClock();
  const ready = await waitUntilReady(send, { consecutive: 2, intervalMs: 10, timeoutMs: 1000, ...clock });
  assert.equal(ready, true);
});

// ---------------------------------------------------------------------------
// createHealthTracker
// ---------------------------------------------------------------------------

test("createHealthTracker: reports unhealthy after the configured number of consecutive transient results", () => {
  const health = createHealthTracker({ maxConsecutive: 3 });
  health.record(unavailable);
  health.record(unavailable);
  assert.equal(health.unhealthy(), false);
  health.record(unavailable);
  assert.equal(health.unhealthy(), true);
});

test("createHealthTracker: a good result resets the streak", () => {
  const health = createHealthTracker({ maxConsecutive: 2 });
  health.record(unavailable);
  health.record(ok);
  health.record(unavailable);
  assert.equal(health.unhealthy(), false);
});
