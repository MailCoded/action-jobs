import { afterEach, test } from "node:test";
import assert from "node:assert/strict";
import worker from "../src/index.mjs";

const ENV = {
  GITHUB_TOKEN: "token-123",
  GITHUB_REPOSITORY: "owner/repo",
  WORKFLOW: "oracle-a1.yml",
  REF: "main",
  INPUTS: { capacity_check: "false", try_fault_domains: true },
};
const WORKFLOW_URL = "https://api.github.com/repos/owner/repo/actions/workflows/oracle-a1.yml";

const realFetch = globalThis.fetch;
afterEach(() => {
  globalThis.fetch = realFetch;
});

function stubFetch(...replies) {
  const calls = [];
  globalThis.fetch = async (url, init = {}) => {
    calls.push({ url: String(url), method: init.method ?? "GET", headers: init.headers ?? {}, body: init.body });
    assert.ok(replies.length > 0, `unexpected request: ${init.method ?? "GET"} ${url}`);
    const [status, body] = replies.shift();
    return new Response(body === undefined ? null : JSON.stringify(body), { status });
  };
  return calls;
}

function run(env = ENV) {
  return worker.scheduled({ cron: "*/10 * * * *", scheduledTime: Date.now() }, env, { waitUntil() {} });
}

test("dispatches an active workflow with string inputs", async (t) => {
  const log = t.mock.method(console, "log", () => {});
  const calls = stubFetch(
    [200, { state: "active" }],
    [200, { workflow_run_id: 7, html_url: "https://github.com/owner/repo/actions/runs/7" }],
  );
  await run();

  assert.deepEqual(
    calls.map(({ method, url }) => `${method} ${url}`),
    [`GET ${WORKFLOW_URL}`, `POST ${WORKFLOW_URL}/dispatches`],
  );
  assert.deepEqual(JSON.parse(calls[1].body), {
    ref: "main",
    inputs: { capacity_check: "false", try_fault_domains: "true" },
  });
  for (const { headers } of calls) {
    assert.equal(headers.Authorization, "Bearer token-123");
    assert.equal(headers.Accept, "application/vnd.github+json");
    assert.ok(headers["User-Agent"]);
  }
  assert.equal(calls[1].headers["Content-Type"], "application/json");
  assert.match(log.mock.calls[0].arguments[0], /actions\/runs\/7$/);
});

test("accepts a 204 reply without a body", async (t) => {
  t.mock.method(console, "log", () => {});
  const calls = stubFetch([200, { state: "active" }], [204]);
  await run();
  assert.equal(calls.length, 2);
});

test("reads INPUTS given as a JSON string", async (t) => {
  t.mock.method(console, "log", () => {});
  const calls = stubFetch([200, { state: "active" }], [204]);
  await run({ ...ENV, INPUTS: '{"capacity_check": false}' });
  assert.deepEqual(JSON.parse(calls[1].body).inputs, { capacity_check: "false" });
});

test("sends no inputs when INPUTS is unset", async (t) => {
  t.mock.method(console, "log", () => {});
  const calls = stubFetch([200, { state: "active" }], [204]);
  await run({ ...ENV, INPUTS: undefined });
  assert.deepEqual(JSON.parse(calls[1].body).inputs, {});
});

for (const state of ["disabled_manually", "disabled_inactivity"]) {
  test(`does not dispatch a ${state} workflow`, async (t) => {
    const log = t.mock.method(console, "log", () => {});
    const calls = stubFetch([200, { state }]);
    await run();
    assert.equal(calls.length, 1);
    assert.match(log.mock.calls[0].arguments[0], new RegExp(`is ${state}; not dispatching`));
  });
}

test("fails when the dispatch is rejected", async () => {
  stubFetch([200, { state: "active" }], [422, { message: "Unexpected inputs provided" }]);
  await assert.rejects(run(), /Dispatching oracle-a1\.yml failed: HTTP 422: .*Unexpected inputs provided/);
});

test("fails on a rejected token without dispatching", async () => {
  const calls = stubFetch([401, { message: "Bad credentials" }]);
  await assert.rejects(run(), /Reading oracle-a1\.yml failed: HTTP 401: .*Bad credentials/);
  assert.equal(calls.length, 1);
});

test("fails before any request without a token", async () => {
  const calls = stubFetch();
  await assert.rejects(run({ ...ENV, GITHUB_TOKEN: "" }), /GITHUB_TOKEN is not set/);
  assert.equal(calls.length, 0);
});
