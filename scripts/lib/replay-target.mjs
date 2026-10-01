// Retry / warm-up helpers for talking to a replay target (a PR preview Worker
// or prod). `send` is any `() => Promise<{ status, text }>`; keeping the
// network call injected lets the tests drive these without a real Worker.

const defaultSleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

export function isTransientResponse({ status, text }) {
  if (status >= 500 || status === 429) return true;
  try {
    JSON.parse(text);
    return false;
  } catch {
    return true;
  }
}

export async function sendWithRetry(
  send,
  { retries = 4, baseDelayMs = 2000, sleep = defaultSleep } = {},
) {
  for (let attempt = 0; ; attempt++) {
    const last = attempt === retries;
    try {
      const res = await send();
      if (last || !isTransientResponse(res)) return res;
    } catch (err) {
      if (last) throw err;
    }
    await sleep(baseDelayMs * 2 ** attempt);
  }
}

export async function waitUntilReady(
  send,
  {
    consecutive = 3,
    intervalMs = 2000,
    timeoutMs = 120000,
    sleep = defaultSleep,
    now = Date.now,
  } = {},
) {
  const deadline = now() + timeoutMs;
  let streak = 0;
  while (now() < deadline) {
    let good = false;
    try {
      good = !isTransientResponse(await send());
    } catch {
      good = false;
    }
    streak = good ? streak + 1 : 0;
    if (streak >= consecutive) return true;
    await sleep(intervalMs);
  }
  return false;
}

export function createHealthTracker({ maxConsecutive = 3 } = {}) {
  let streak = 0;
  return {
    record(res) {
      streak = isTransientResponse(res) ? streak + 1 : 0;
    },
    unhealthy: () => streak >= maxConsecutive,
  };
}

export async function sendTracked(send, health, retryOptions) {
  let res;
  try {
    res = await sendWithRetry(send, retryOptions);
  } catch (err) {
    res = { status: 0, text: "", error: err?.message ?? String(err) };
  }
  health.record(res);
  return res;
}
