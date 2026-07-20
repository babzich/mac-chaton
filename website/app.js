const $ = (selector, root = document) => root.querySelector(selector);
const $$ = (selector, root = document) => [...root.querySelectorAll(selector)];

const storage = {
  get(key, fallback) {
    try {
      const value = localStorage.getItem(key);
      return value === null ? fallback : JSON.parse(value);
    } catch {
      return fallback;
    }
  },
  set(key, value) {
    try {
      localStorage.setItem(key, JSON.stringify(value));
    } catch {
      // The manual remains fully usable when local storage is unavailable.
    }
  },
};

const layerContent = {
  surface: {
    index: "LAYER 07 / USER BOUNDARY",
    title: "The surface is not the agent.",
    body: "A terminal UI, editor panel, or native app captures intent and renders state. It may own permission UX and process lifecycle, while the agent lives behind a protocol boundary.",
    owns: "Input, navigation, rendering, user decisions",
    asks: "What must the human see, decide, or recover?",
    lechaton: "SwiftUI views + app-owned controllers",
  },
  protocol: {
    index: "LAYER 06 / INTEROPERABILITY",
    title: "The protocol transports facts.",
    body: "ACP, Codex app-server, and Pi RPC expose lifecycle and events to another program. A protocol defines messages and correlation; it does not decide product policy or guarantee safe execution.",
    owns: "Framing, method shapes, IDs, capabilities",
    asks: "Which facts cross the process or product boundary?",
    lechaton: "JSON-RPC 2.0 over ACP stdio",
  },
  runtime: {
    index: "LAYER 05 / RESOURCE OWNERSHIP",
    title: "The runtime makes work real.",
    body: "The runtime launches processes, owns stdin and stdout, chooses cwd and environment, tracks descendants, enforces timeouts, and proves shutdown. It is where abstract tool intent becomes operating-system effects.",
    owns: "Processes, pipes, cwd, environment, cleanup",
    asks: "What can outlive this turn, and who must stop it?",
    lechaton: "ACPTransport actor + process tree terminator",
  },
  orchestrator: {
    index: "LAYER 04 / CONTROL LOOP",
    title: "The harness controls the loop.",
    body: "It assembles context, calls a provider, interprets tool intent, applies budgets, schedules tools, appends results, compacts history, and decides whether another model call is allowed.",
    owns: "Loop state, budgets, scheduling, stop reasons",
    asks: "Given the latest fact, what may happen next?",
    lechaton: "Vibe owns the inner model/tool loop",
  },
  tools: {
    index: "LAYER 03 / EFFECT BOUNDARY",
    title: "Tools turn tokens into effects.",
    body: "A good tool has a narrow schema, explicit effect class, stable call ID, bounded output, cancellation path, and normalized result. MCP is one way to discover and invoke external tools; built-ins are another.",
    owns: "Schemas, execution adapters, effect annotations",
    asks: "What capability is exposed, under which policy?",
    lechaton: "Vibe hosts tools; LeChaton mediates permission",
  },
  provider: {
    index: "LAYER 02 / INFERENCE BOUNDARY",
    title: "The provider is not the model.",
    body: "The provider layer handles authentication, model catalogs, request formats, streaming transports, rate limits, usage, and errors. A harness normalizes those differences behind a provider adapter.",
    owns: "Credentials, API shapes, streams, usage metadata",
    asks: "How do I obtain model output reliably?",
    lechaton: "Vibe owns inference; provider keys are narrowly injected",
  },
  model: {
    index: "LAYER 01 / PROBABILISTIC PLANNER",
    title: "The model proposes the next move.",
    body: "A model consumes a finite context and emits probabilistic text or structured tool intent. It does not inspect files, run commands, remember sessions, or enforce policy unless the harness supplies those capabilities.",
    owns: "Token generation and tool-call intent",
    asks: "What response best follows this context?",
    lechaton: "Selected through Vibe configuration",
  },
};

function renderLayer(key) {
  const data = layerContent[key];
  const target = $("#layer-detail");
  target.innerHTML = `
    <p class="detail-index">${data.index}</p>
    <h3>${data.title}</h3>
    <p>${data.body}</p>
    <dl>
      <div><dt>Owns</dt><dd>${data.owns}</dd></div>
      <div><dt>Asks</dt><dd>${data.asks}</dd></div>
      <div><dt>LeChaton</dt><dd>${data.lechaton}</dd></div>
    </dl>`;
}

$$('.stack-layer').forEach((button) => {
  button.addEventListener('click', () => {
    $$('.stack-layer').forEach((item) => {
      item.classList.remove('is-active');
      item.setAttribute('aria-selected', 'false');
    });
    button.classList.add('is-active');
    button.setAttribute('aria-selected', 'true');
    renderLayer(button.dataset.layer);
  });
});

const modeContent = {
  interactive: {
    tag: "HUMAN ↔ TUI ↔ VIBE",
    title: "Use it to think with the codebase.",
    body: "Run <code>vibe</code> inside a repository. The TUI owns input, slash commands, file references, tool previews, approvals, and session navigation.",
    points: ["<code>@path</code> adds a file to the prompt.", "<code>!command</code> runs a shell command directly.", "<code>Shift+Tab</code> cycles agent profiles.", "<code>Escape</code> interrupts current work."],
    copy: "cd /path/to/repo\nvibe --agent plan",
    code: `<span class="muted"># Explore safely first</span>\n$ vibe --agent plan\n\n<span class="prompt">›</span> Trace authentication from UI to storage.\n<span class="prompt">›</span> @Sources/LeChatonCore/Vibe/VibeAdapter.swift\n<span class="prompt">›</span> !git status --short`,
  },
  programmatic: {
    tag: "SCRIPT ↔ STDOUT / STDERR ↔ VIBE",
    title: "Use it as a bounded command.",
    body: "Programmatic mode accepts one task, applies explicit limits, and exits. Choose text for humans, JSON for a completed record, or streaming for newline-delimited events.",
    points: ["Set <code>--max-turns</code> to bound the loop.", "Restrict capability with <code>--enabled-tools</code>.", "Choose an approval profile deliberately.", "Treat reported price as telemetry, not a hard guarantee."],
    copy: `vibe -p "Review this repository" --agent plan --max-turns 5 --output streaming`,
    code: `<span class="muted"># Machine-consumable, bounded run</span>\n$ vibe -p <span class="prompt">"Review this repository"</span> \\\n+  --agent plan \\\n+  --max-turns 5 \\\n+  --output streaming\n\n<span class="muted"># stdout: newline-delimited messages</span>`,
  },
  "acp-mode": {
    tag: "CLIENT ↔ JSON-RPC / STDIO ↔ VIBE",
    title: "Use it as an embeddable agent.",
    body: "<code>vibe-acp</code> removes the TUI and speaks ACP. Your client becomes responsible for initialization, session lifecycle, event rendering, permission decisions, cancellation, and complete process ownership.",
    points: ["Write JSON-RPC frames to stdin.", "Read responses, updates, and requests from stdout.", "Keep stderr separate for diagnostics.", "Never block the read loop on a permission dialog."],
    copy: "vibe-acp --version\nvibe-acp",
    code: `<span class="muted"># Normally launched by your client</span>\n$ vibe-acp\n\n<span class="prompt">stdin  →</span> {"method":"initialize", ...}\n<span class="prompt">stdout ←</span> {"id":1,"result":{...}}\n<span class="prompt">stdout ←</span> {"method":"session/update", ...}`,
  },
};

function renderMode(key) {
  const data = modeContent[key];
  $("#mode-panel").innerHTML = `
    <div>
      <p class="panel-tag">${data.tag}</p>
      <h3>${data.title}</h3>
      <p>${data.body}</p>
      <ul class="check-list">${data.points.map((point) => `<li>${point}</li>`).join('')}</ul>
    </div>
    <div class="code-window">
      <div class="code-title"><span>TERMINAL</span><button type="button" class="copy-code" data-copy="${escapeAttribute(data.copy)}">Copy</button></div>
      <pre><code>${data.code}</code></pre>
    </div>`;
}

$$('.mode-tab').forEach((button) => {
  button.addEventListener('click', () => {
    $$('.mode-tab').forEach((item) => {
      item.classList.remove('is-active');
      item.setAttribute('aria-selected', 'false');
    });
    button.classList.add('is-active');
    button.setAttribute('aria-selected', 'true');
    renderMode(button.dataset.mode);
  });
});

function escapeAttribute(value) {
  return value
    .replaceAll('&', '&amp;')
    .replaceAll('"', '&quot;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');
}

const wireSteps = {
  initialize: {
    count: "01 / 07",
    direction: "CLIENT → AGENT · REQUEST",
    packet: "initialize →",
    reverse: false,
    json: {
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: {
        protocolVersion: 1,
        clientCapabilities: {
          fs: { readTextFile: false, writeTextFile: false },
          terminal: false,
        },
        clientInfo: { name: "LeChaton", version: "0.1.0" },
      },
    },
    rule: "Initialization must be the first ACP request. Negotiate the protocol version and inspect capabilities before using optional methods.",
  },
  new: {
    count: "02 / 07",
    direction: "CLIENT → AGENT · REQUEST",
    packet: "session/new →",
    reverse: false,
    json: {
      jsonrpc: "2.0",
      id: 2,
      method: "session/new",
      params: { cwd: "/absolute/project", mcpServers: [] },
    },
    rule: "A session ID scopes later prompts, updates, permission requests, and cancellation. Use session/load only when the agent advertised support.",
  },
  prompt: {
    count: "03 / 07",
    direction: "CLIENT → AGENT · REQUEST",
    packet: "session/prompt →",
    reverse: false,
    json: {
      jsonrpc: "2.0",
      id: "prompt-1",
      method: "session/prompt",
      params: {
        sessionId: "sess_abc123",
        prompt: [{ type: "text", text: "Explain the transport." }],
      },
    },
    rule: "One prompt request defines one turn. Keep its response continuation alive while independently consuming streaming notifications and agent-initiated requests.",
  },
  stream: {
    count: "04 / 07",
    direction: "AGENT → CLIENT · NOTIFICATION",
    packet: "← session/update",
    reverse: true,
    json: {
      jsonrpc: "2.0",
      method: "session/update",
      params: {
        sessionId: "sess_abc123",
        update: {
          sessionUpdate: "tool_call",
          toolCallId: "tool_7",
          title: "Read ACPTransport.swift",
          status: "pending",
        },
      },
    },
    rule: "Updates are facts, not append-only prose. Decode by discriminator, preserve identifiers, merge patches, tolerate unknown kinds, and reduce serially.",
  },
  permission: {
    count: "05 / 07",
    direction: "AGENT → CLIENT · REQUEST",
    packet: "← request_permission",
    reverse: true,
    json: {
      jsonrpc: "2.0",
      id: "permission-9",
      method: "session/request_permission",
      params: {
        sessionId: "sess_abc123",
        toolCall: { toolCallId: "tool_7", title: "Run tests" },
        options: [
          { optionId: "allow_once", name: "Allow once", kind: "allow_once" },
          { optionId: "reject_once", name: "Reject", kind: "reject_once" },
        ],
      },
    },
    rule: "This is a bidirectional JSON-RPC request. Queue it without blocking stdout, preserve its exact ID, and resolve it exactly once—even when cancellation races it.",
  },
  complete: {
    count: "06 / 07",
    direction: "AGENT → CLIENT · RESPONSE",
    packet: "← prompt result",
    reverse: true,
    json: {
      jsonrpc: "2.0",
      id: "prompt-1",
      result: { stopReason: "end_turn" },
    },
    rule: "The response ends the prompt request, not necessarily the runtime or session. Stop reasons are forward-compatible enums; unknown values must remain diagnosable.",
  },
  cancel: {
    count: "07 / 07",
    direction: "CLIENT → AGENT · NOTIFICATION",
    packet: "session/cancel →",
    reverse: false,
    json: {
      jsonrpc: "2.0",
      method: "session/cancel",
      params: { sessionId: "sess_abc123" },
    },
    rule: "Cancellation prevents future work but does not prove execution stopped. The runtime owner must resolve pending work once and verify every tracked descendant is gone.",
  },
};

function syntaxJSON(value) {
  const escaped = JSON.stringify(value, null, 2)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');
  return escaped.replace(/("(?:\\u[a-fA-F0-9]{4}|\\[^u]|[^\\"])*"\s*:)|("(?:\\u[a-fA-F0-9]{4}|\\[^u]|[^\\"])*")|\b(true|false|null)\b|-?\d+(?:\.\d+)?/g, (match, key, string) => {
    if (key) return `<span class="json-key">${match}</span>`;
    if (string) return `<span class="json-string">${match}</span>`;
    return `<span class="json-number">${match}</span>`;
  });
}

let activeWire = 'initialize';

function renderWire(key) {
  const data = wireSteps[key];
  activeWire = key;
  $("#wire-counter").textContent = data.count;
  $("#wire-direction").textContent = data.direction;
  $("#wire-packet").textContent = data.packet;
  $("#wire-packet").classList.toggle('is-reverse', data.reverse);
  $("#wire-json").innerHTML = syntaxJSON(data.json);
  $("#wire-rule-text").textContent = data.rule;
}

$$('.wire-step').forEach((button) => {
  button.addEventListener('click', () => {
    $$('.wire-step').forEach((item) => item.classList.remove('is-active'));
    button.classList.add('is-active');
    renderWire(button.dataset.wire);
  });
});

renderWire('initialize');

const toast = $("#toast");
let toastTimer;

function showToast(message = 'Copied to clipboard') {
  toast.textContent = message;
  toast.classList.add('is-visible');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => toast.classList.remove('is-visible'), 1800);
}

async function copyText(text) {
  try {
    await navigator.clipboard.writeText(text);
    showToast();
  } catch {
    showToast('Clipboard unavailable');
  }
}

document.addEventListener('click', (event) => {
  const button = event.target.closest('.copy-code');
  if (!button) return;
  if (button.id === 'copy-wire') {
    copyText(JSON.stringify(wireSteps[activeWire].json, null, 2));
  } else {
    copyText(button.dataset.copy || '');
  }
});

const labKey = 'agent-field-manual-labs';
let completedLabs = new Set(storage.get(labKey, []));

function renderLabs() {
  $$('.lab-card').forEach((card) => {
    const isComplete = completedLabs.has(card.dataset.lab);
    card.classList.toggle('is-complete', isComplete);
    const button = $('.lab-check', card);
    button.setAttribute('aria-pressed', String(isComplete));
    button.setAttribute('aria-label', `${isComplete ? 'Mark incomplete' : 'Mark complete'}: ${$('h3', card).textContent}`);
  });
  const count = completedLabs.size;
  const percent = Math.round((count / 8) * 100);
  $("#completed-count").textContent = String(count);
  $("#course-progress-label").textContent = `${percent}%`;
  $("#course-progress-bar").style.width = `${percent}%`;
}

$$('.lab-check').forEach((button) => {
  button.addEventListener('click', () => {
    const id = button.closest('.lab-card').dataset.lab;
    if (completedLabs.has(id)) completedLabs.delete(id);
    else completedLabs.add(id);
    storage.set(labKey, [...completedLabs]);
    renderLabs();
  });
});

$("#reset-labs").addEventListener('click', () => {
  completedLabs = new Set();
  storage.set(labKey, []);
  renderLabs();
  showToast('Lab progress reset');
});

renderLabs();

const explanations = [
  "A load response marks the barrier, but publication waits until staging has reduced every event through that sequence.",
  "Optional ACP methods are capability-gated. A client should shape its UI from the handshake, not probe by error.",
  "ACP is the client–agent boundary; MCP is the tool/data boundary. Both may use JSON-RPC, but they solve different interoperability problems.",
  "Vibe 2.21.0 can return a provisional ID before durable storage exists. LeChaton confirms it through session/list after visible work.",
  "Protocol cancellation and OS cleanup are separate proofs. The process owner remains responsible for verified descendants.",
  "Pi is useful to study because its small harness core and TypeScript extension seams keep responsibilities visible.",
  "The sandbox constrains capability even if approval is granted; approval governs when human consent is required. Together they provide defense in depth.",
  "Forward-compatible clients preserve unknown values, avoid invented meaning, and degrade safely while retaining diagnostics.",
];

$("#quiz-form").addEventListener('submit', (event) => {
  event.preventDefault();
  let score = 0;
  $$('.quiz-card').forEach((card, index) => {
    const selected = $('input:checked', card)?.value;
    const correct = selected === card.dataset.answer;
    if (correct) score += 1;
    card.classList.toggle('is-correct', correct);
    card.classList.toggle('is-wrong', Boolean(selected) && !correct);
    $('.quiz-explanation', card).textContent = selected ? explanations[index] : 'Choose an answer, then score again.';
  });
  $("#score-value").textContent = String(score);
  $("#score-dial").style.setProperty('--score', `${(score / 8) * 100}%`);
  storage.set('agent-field-manual-score', score);
  showToast(score === 8 ? 'Field exam mastered' : `Score: ${score} / 8`);
  $("#score-dial").scrollIntoView({ behavior: 'smooth', block: 'center' });
});

const savedScore = storage.get('agent-field-manual-score', null);
if (typeof savedScore === 'number') {
  $("#score-value").textContent = String(savedScore);
  $("#score-dial").style.setProperty('--score', `${(savedScore / 8) * 100}%`);
}

const sections = $$('[data-section]');
const navLinks = $$('.chapter-nav a[data-nav]');
const observer = new IntersectionObserver((entries) => {
  const visible = entries
    .filter((entry) => entry.isIntersecting)
    .sort((a, b) => b.intersectionRatio - a.intersectionRatio)[0];
  if (!visible) return;
  navLinks.forEach((link) => link.classList.toggle('is-active', link.dataset.nav === visible.target.id));
}, { rootMargin: '-18% 0px -66% 0px', threshold: [0, 0.1, 0.3] });
sections.forEach((section) => observer.observe(section));

const themeKey = 'agent-field-manual-theme';
const savedTheme = storage.get(themeKey, null);
if (savedTheme === 'dark' || savedTheme === 'light') document.documentElement.dataset.theme = savedTheme;

$("#theme-toggle").addEventListener('click', () => {
  const theme = document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark';
  document.documentElement.dataset.theme = theme;
  storage.set(themeKey, theme);
  showToast(`${theme === 'dark' ? 'Dark' : 'Light'} field mode`);
});

const searchItems = [
  { index: '01', title: 'Mental model', detail: 'The seven layers of a coding agent system', href: '#model', terms: 'surface protocol runtime orchestrator tools provider model' },
  { index: '01', title: 'Agent loop', detail: 'Context → model → tool → result → repeat', href: '#model', terms: 'loop stop turn execution planning' },
  { index: '01', title: 'ACP versus MCP', detail: 'Client–agent boundary versus agent–tool boundary', href: '#model', terms: 'mcp difference interoperability' },
  { index: '02', title: 'Vibe interactive mode', detail: '@ files, ! shell, slash commands, agents', href: '#vibe', terms: 'cli tui command shortcuts' },
  { index: '02', title: 'Vibe programmatic mode', detail: '--prompt, limits, tools, streaming output', href: '#vibe', terms: 'automation json max turns output' },
  { index: '02', title: 'vibe-acp', detail: 'Run Vibe as an ACP process over stdio', href: '#acp', terms: 'server executable json rpc' },
  { index: '03', title: 'ACP lifecycle', detail: 'Initialize, session, prompt, updates, permissions, cancel', href: '#acp', terms: 'handshake capabilities jsonrpc protocol' },
  { index: '03', title: 'Replay barrier', detail: 'Why updates can precede the load response', href: '#acp', terms: 'session load sequence staging concurrency' },
  { index: '04', title: 'Harness engineering', detail: 'Nine production components around the model loop', href: '#anatomy', terms: 'build harness architecture context provider tools policy events' },
  { index: '04', title: 'Context engineering', detail: 'Instructions, retrieval, compaction, prompt caching', href: '#anatomy', terms: 'tokens files history system prompt' },
  { index: '04', title: 'Tool design', detail: 'Schemas, effects, idempotency, truncation, cancellation', href: '#anatomy', terms: 'function calling bash execute' },
  { index: '04', title: 'Evals and observability', detail: 'Trace outcome and trajectory quality', href: '#anatomy', terms: 'metrics telemetry regression cost latency' },
  { index: '04', title: 'Harness build order', detail: 'Seven milestones from provider to external protocol', href: '#anatomy', terms: 'roadmap own coding agent' },
  { index: '05', title: 'Codex architecture', detail: 'Sandbox, approvals, app-server, MCP, surfaces', href: '#landscape', terms: 'openai cli cloud agents md' },
  { index: '05', title: 'Pi architecture', detail: 'Minimal loop, JSONL sessions, RPC, extensions', href: '#landscape', terms: 'coding agent sdk typescript provider' },
  { index: '06', title: 'LeChaton code map', detail: 'Read the transport, adapter, reducer, and runtime', href: '#lechaton', terms: 'swift acp implementation source' },
  { index: '06', title: 'Vibe integration traps', detail: 'Seven constraints observed in Vibe 2.21.0', href: '#lechaton', terms: 'cwd auth replay persistence cancellation' },
  { index: '07', title: 'Expert labs', detail: 'Eight prediction-driven implementation exercises', href: '#labs', terms: 'practice exercises learn' },
  { index: '08', title: 'Field exam', detail: 'Eight architecture and protocol scenarios', href: '#exam', terms: 'quiz test mastery' },
  { index: 'SRC', title: 'Primary sources', detail: 'Official Vibe, ACP, Codex, Pi, and local references', href: '#sources', terms: 'docs citations reference current' },
];

const dialog = $("#command-dialog");
const searchInput = $("#command-input");
const resultContainer = $("#command-results");
let selectedResult = 0;
let currentResults = searchItems;

function renderSearch(query = '') {
  const words = query.trim().toLowerCase().split(/\s+/).filter(Boolean);
  currentResults = searchItems.filter((item) => {
    const haystack = `${item.title} ${item.detail} ${item.terms}`.toLowerCase();
    return words.every((word) => haystack.includes(word));
  });
  selectedResult = Math.min(selectedResult, Math.max(0, currentResults.length - 1));
  if (!currentResults.length) {
    resultContainer.innerHTML = '<div class="command-empty">No matching field notes.</div>';
    return;
  }
  resultContainer.innerHTML = currentResults.map((item, index) => `
    <button type="button" class="command-result ${index === selectedResult ? 'is-selected' : ''}" data-result="${index}">
      <span>${item.index}</span><span><strong>${item.title}</strong><small>${item.detail}</small></span><span>↗</span>
    </button>`).join('');
}

function openSearch() {
  renderSearch('');
  dialog.showModal();
  requestAnimationFrame(() => searchInput.focus());
}

function chooseResult(index) {
  const item = currentResults[index];
  if (!item) return;
  dialog.close();
  location.hash = item.href;
}

$("#open-command").addEventListener('click', openSearch);
searchInput.addEventListener('input', () => renderSearch(searchInput.value));
resultContainer.addEventListener('click', (event) => {
  const button = event.target.closest('[data-result]');
  if (button) chooseResult(Number(button.dataset.result));
});

dialog.addEventListener('click', (event) => {
  if (event.target === dialog) dialog.close();
});

document.addEventListener('keydown', (event) => {
  if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'k') {
    event.preventDefault();
    if (dialog.open) dialog.close();
    else openSearch();
  }
  if (!dialog.open) return;
  if (event.key === 'ArrowDown') {
    event.preventDefault();
    selectedResult = Math.min(currentResults.length - 1, selectedResult + 1);
    renderSearch(searchInput.value);
  }
  if (event.key === 'ArrowUp') {
    event.preventDefault();
    selectedResult = Math.max(0, selectedResult - 1);
    renderSearch(searchInput.value);
  }
  if (event.key === 'Enter' && document.activeElement === searchInput) {
    event.preventDefault();
    chooseResult(selectedResult);
  }
});
