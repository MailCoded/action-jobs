const API = "https://api.github.com";

export default {
  async scheduled(_controller, env) {
    await dispatch(env);
  },
};

async function dispatch(env) {
  const { GITHUB_TOKEN, GITHUB_REPOSITORY, WORKFLOW, REF } = env;
  if (!GITHUB_TOKEN) {
    throw new Error("GITHUB_TOKEN is not set: run `wrangler secret put GITHUB_TOKEN`.");
  }
  const workflowUrl = `${API}/repos/${GITHUB_REPOSITORY}/actions/workflows/${WORKFLOW}`;
  const headers = {
    Accept: "application/vnd.github+json",
    Authorization: `Bearer ${GITHUB_TOKEN}`,
    // GitHub rejects API requests without a User-Agent, and a Worker's fetch sends none.
    "User-Agent": "freebie-hub-trigger",
    "X-GitHub-Api-Version": "2022-11-28",
  };

  const workflow = await fetch(workflowUrl, { headers });
  if (!workflow.ok) {
    throw new Error(`Reading ${WORKFLOW} failed: ${await describe(workflow)}`);
  }
  const { state } = await workflow.json();
  // The workflow disables itself after a success, which is also how this trigger stops.
  if (state !== "active") {
    console.log(`${WORKFLOW} is ${state}; not dispatching.`);
    return;
  }

  const res = await fetch(`${workflowUrl}/dispatches`, {
    method: "POST",
    headers: { ...headers, "Content-Type": "application/json" },
    body: JSON.stringify({ ref: REF, inputs: parseInputs(env.INPUTS) }),
  });
  if (!res.ok) {
    throw new Error(`Dispatching ${WORKFLOW} failed: ${await describe(res)}`);
  }
  const run = res.status === 200 ? await res.json().catch(() => ({})) : {};
  console.log(`Dispatched ${WORKFLOW} on ${REF}${run.html_url ? `: ${run.html_url}` : "."}`);
}

function parseInputs(inputs) {
  const parsed = typeof inputs === "string" ? JSON.parse(inputs) : (inputs ?? {});
  return Object.fromEntries(Object.entries(parsed).map(([key, value]) => [key, String(value)]));
}

async function describe(res) {
  return `HTTP ${res.status}: ${(await res.text()).slice(0, 300)}`;
}
