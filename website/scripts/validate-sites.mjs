import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const projectRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const workerPath = resolve(projectRoot, "dist/server/index.js");
const hostingPath = resolve(projectRoot, "dist/.openai/hosting.json");

const [workerSource, hostingSource] = await Promise.all([
  readFile(workerPath, "utf8"),
  readFile(hostingPath, "utf8"),
]);

const hosting = JSON.parse(hostingSource);
assert.match(hosting.project_id, /^appgprj_/);

const moduleUrl = `data:text/javascript;base64,${Buffer.from(workerSource).toString("base64")}`;
const worker = await import(moduleUrl);
assert.equal(typeof worker.default?.fetch, "function");

const checks = [
  ["/", 200, "text/html"],
  ["/styles.css", 200, "text/css"],
  ["/app.js", 200, "text/javascript"],
  ["/missing", 404, "text/plain"],
];

for (const [pathname, status, contentType] of checks) {
  const response = await worker.default.fetch(new Request(`https://example.test${pathname}`));
  assert.equal(response.status, status);
  assert.match(response.headers.get("content-type") ?? "text/plain", new RegExp(contentType));
}

console.log("Sites package is valid and serves every expected route");
