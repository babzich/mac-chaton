import { cp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const projectRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const distRoot = resolve(projectRoot, "dist");

const [html, css, javascript] = await Promise.all([
  readFile(resolve(projectRoot, "index.html"), "utf8"),
  readFile(resolve(projectRoot, "styles.css"), "utf8"),
  readFile(resolve(projectRoot, "app.js"), "utf8"),
]);

const workerSource = `const assets = new Map(${JSON.stringify([
  ["/", { body: html, contentType: "text/html; charset=utf-8" }],
  ["/index.html", { body: html, contentType: "text/html; charset=utf-8" }],
  ["/styles.css", { body: css, contentType: "text/css; charset=utf-8" }],
  ["/app.js", { body: javascript, contentType: "text/javascript; charset=utf-8" }],
])});

const securityHeaders = {
  "Referrer-Policy": "strict-origin-when-cross-origin",
  "X-Content-Type-Options": "nosniff",
  "X-Frame-Options": "SAMEORIGIN",
};

export default {
  async fetch(request) {
    if (request.method !== "GET" && request.method !== "HEAD") {
      return new Response("Method Not Allowed", {
        status: 405,
        headers: { ...securityHeaders, Allow: "GET, HEAD" },
      });
    }

    const { pathname } = new URL(request.url);
    const asset = assets.get(pathname);
    if (!asset) {
      return new Response("Not Found", { status: 404, headers: securityHeaders });
    }

    const cacheControl = asset.contentType.startsWith("text/html")
      ? "no-cache"
      : "public, max-age=3600";

    return new Response(request.method === "HEAD" ? null : asset.body, {
      headers: {
        ...securityHeaders,
        "Cache-Control": cacheControl,
        "Content-Type": asset.contentType,
      },
    });
  },
};
`;

await rm(distRoot, { recursive: true, force: true });
await mkdir(resolve(distRoot, "server"), { recursive: true });
await mkdir(resolve(distRoot, ".openai"), { recursive: true });
await writeFile(resolve(distRoot, "server/index.js"), workerSource, "utf8");
await cp(
  resolve(projectRoot, ".openai/hosting.json"),
  resolve(distRoot, ".openai/hosting.json"),
);

console.log(`Built ${distRoot}`);
