// Checks what a reverse proxy in front of Polysite must do, whichever proxy it is (nginx, Apache, Traefik): the same routing, limits and
// headers as the Caddyfile. Run by proxy/test/run.sh against a throwaway stack, after tests/smoke/smoke.mjs has created the first
// administrator and a site on plain http. Uses only Node's standard library.
//
//   PROXY_HOST=nginx MODE=plain node checks.mjs      plain http: routing, uploads, size limits, headers, forged X-Forwarded-For
//   PROXY_HOST=nginx MODE=tls   node checks.mjs      https: redirect, HSTS, X-Forwarded-Proto, TLS version, HTTP/2
import http from "node:http";
import https from "node:https";
import tls from "node:tls";
import zlib from "node:zlib";

const PROXY_HOST = process.env.PROXY_HOST ?? "proxy";
const MODE = process.env.MODE ?? "plain";
const SITE = process.env.SITE_HOST ?? "localhost";
const ADMIN = process.env.CMS_HOST ?? "admin.localhost";
const EMAIL = process.env.ADMIN_EMAIL ?? "smoke-admin@example.test";
const PASSWORD = process.env.ADMIN_PASSWORD ?? "Smoke-Test-Password-4821";
const TLS = MODE === "tls";

function request(host, method, path, { body, headers = {}, chunked = false, scheme = TLS ? "https" : "http", raw = false } = {}) {
  return new Promise((resolve, reject) => {
    const mod = scheme === "https" ? https : http;
    const h = { Host: host, Accept: "text/html,application/json", ...headers };
    const isBuf = Buffer.isBuffer(body);
    const payload = body === undefined ? undefined : isBuf ? body : typeof body === "string" ? Buffer.from(body) : Buffer.from(JSON.stringify(body));
    if (payload && !h["Content-Type"] && !h["content-type"]) h["Content-Type"] = isBuf ? "application/octet-stream" : "application/json";
    if (payload && !chunked) h["Content-Length"] = payload.length;
    if (payload && chunked) h["Transfer-Encoding"] = "chunked";
    const req = mod.request(
      { hostname: PROXY_HOST, port: scheme === "https" ? 443 : 80, method, path, headers: h, servername: host, rejectUnauthorized: false, agent: false },
      (res) => {
        const chunks = [];
        res.on("data", (c) => chunks.push(c));
        res.on("end", () => {
          const buf = Buffer.concat(chunks);
          const text = raw ? "" : buf.toString("utf8");
          let json;
          try {
            json = JSON.parse(text);
          } catch {
            /* not JSON */
          }
          resolve({ status: res.statusCode, headers: res.headers, text, buf, json });
        });
      },
    );
    req.setTimeout(120_000, () => req.destroy(new Error(`timeout: ${method} ${host}${path}`)));
    // A proxy that refuses a body it will not accept may close the connection before the whole body is sent; that is a rejection.
    req.on("error", (err) => (["EPIPE", "ECONNRESET"].includes(err.code) ? resolve({ status: "reset", headers: {}, text: "", buf: Buffer.alloc(0) }) : reject(err)));
    if (payload) {
      if (chunked) {
        for (let i = 0; i < payload.length; i += 16384) req.write(payload.subarray(i, i + 16384));
        req.end();
      } else req.end(payload);
    } else req.end();
  });
}
const site = (m, p, o) => request(SITE, m, p, o);
const admin = (m, p, o) => request(ADMIN, m, p, o);

const failures = [];
async function step(name, fn) {
  try {
    const note = await fn();
    console.log(`  ok   ${name}${note ? `  (${note})` : ""}`);
  } catch (err) {
    failures.push(name);
    console.log(`  FAIL ${name}\n       ${err.message}`);
  }
}
function expect(cond, message) {
  if (!cond) throw new Error(message);
}
// A valid 1x1 PNG, built here so no binary file is needed.
function tinyPng() {
  const chunk = (type, data) => {
    const len = Buffer.alloc(4);
    len.writeUInt32BE(data.length);
    const body = Buffer.concat([Buffer.from(type), data]);
    const crc = Buffer.alloc(4);
    crc.writeUInt32BE(zlib.crc32(body));
    return Buffer.concat([len, body, crc]);
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(1, 0);
  ihdr.writeUInt32BE(1, 4);
  ihdr[8] = 8; // bit depth
  ihdr[9] = 2; // RGB
  return Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), chunk("IHDR", ihdr), chunk("IDAT", zlib.deflateSync(Buffer.from([0, 255, 0, 0]))), chunk("IEND", Buffer.alloc(0))]);
}
// The proxy itself refused it: 413 (too large) or 411 (a chunked body it cannot count), not the app (which marks its answers with X-Powered-By), or the connection was closed while sending.
const rejected = (r) => r.status === "reset" || ((r.status === 413 || r.status === 411) && !r.headers["x-powered-by"]);

console.log(`Proxy checks against ${PROXY_HOST} (${MODE}, site ${SITE}, admin ${ADMIN})`);

if (TLS) {
  await step("plain http redirects to https (permanent), keeping host and path", async () => {
    const res = await request(SITE, "GET", "/some/page?x=1", { scheme: "http" });
    expect(res.status === 301 || res.status === 308, `expected a permanent redirect, got ${res.status}`);
    expect(res.headers.location === `https://${SITE}/some/page?x=1`, `redirect target was ${res.headers.location}`);
    const adm = await request(ADMIN, "GET", "/admin", { scheme: "http" });
    expect(adm.headers.location === `https://${ADMIN}/admin`, `admin redirect target was ${adm.headers.location}`);
  });
  await step("the admin answers over https with the admin headers, and the bare root goes to /admin", async () => {
    const res = await admin("GET", "/");
    expect(res.status === 302 && /\/admin$/.test(res.headers.location ?? ""), `GET / gave ${res.status} ${res.headers.location}`);
    expect(res.headers["x-frame-options"] === "DENY", "X-Frame-Options DENY is missing");
    expect(res.headers["content-security-policy"] === "frame-ancestors 'none'", "frame-ancestors 'none' is missing");
    expect(/max-age=31536000/.test(res.headers["strict-transport-security"] ?? ""), "HSTS is missing");
    const health = await admin("GET", "/api/health");
    expect(health.status === 200 && health.json?.status === "ok", `health gave ${health.status}`);
  });
  await step("the app is told the request was https (X-Forwarded-Proto): its own absolute links say https", async () => {
    const res = await site("GET", "/robots.txt");
    expect(res.status === 200, `robots.txt gave ${res.status}`);
    expect(/https:\/\/localhost\/sitemap\.xml/.test(res.text), `robots.txt did not point at https://localhost/sitemap.xml:\n${res.text.slice(0, 300)}`);
  });
  await step("TLS 1.0 and 1.1 are refused, TLS 1.2 and 1.3 work, HTTP/2 is offered", async () => {
    const connect = (opts) =>
      new Promise((resolve) => {
        const s = tls.connect({ host: PROXY_HOST, port: 443, servername: SITE, rejectUnauthorized: false, ALPNProtocols: ["h2", "http/1.1"], ...opts }, () => {
          const info = { ok: true, version: s.getProtocol(), alpn: s.alpnProtocol };
          s.end();
          resolve(info);
        });
        s.on("error", (e) => resolve({ ok: false, error: e.code ?? e.message }));
      });
    const old = await connect({ minVersion: "TLSv1", maxVersion: "TLSv1.1" });
    expect(!old.ok, `TLS ${old.version} was accepted`);
    const two = await connect({ minVersion: "TLSv1.2", maxVersion: "TLSv1.2" });
    expect(two.ok, `TLS 1.2 failed: ${two.error}`);
    const three = await connect({ minVersion: "TLSv1.3" });
    expect(three.ok, `TLS 1.3 failed: ${three.error}`);
    return `ALPN ${three.alpn}`;
  });
  await step("an unknown host name gets neither site nor admin", async () => {
    const res = await request("evil.example", "GET", "/").catch((e) => ({ status: `closed (${e.code})`, text: "" }));
    expect(res.status !== 200 || !/Polysite/.test(res.text), "an unknown host was served");
    return `status ${res.status}`;
  });
  if (failures.length) {
    console.log(`\n${failures.length} check(s) failed:\n  - ${failures.join("\n  - ")}`);
    process.exit(1);
  }
  console.log("\nAll proxy checks passed.");
  process.exit(0);
}

// ---- plain http ----
await step("the API answers on the site's own domain with the API headers", async () => {
  const res = await site("GET", "/api/health");
  expect(res.status === 200 && res.json?.status === "ok", `GET /api/health gave ${res.status}`);
  expect(res.headers["x-content-type-options"] === "nosniff", "X-Content-Type-Options nosniff is missing");
  expect(res.headers["referrer-policy"] === "strict-origin-when-cross-origin", `Referrer-Policy was ${res.headers["referrer-policy"]}`);
  expect(res.headers["strict-transport-security"] === "max-age=31536000; includeSubDomains", `HSTS was ${res.headers["strict-transport-security"]}`);
  expect(res.headers["x-frame-options"] === undefined, "the site's API must not carry X-Frame-Options");
});

await step("the admin domain: / goes to /admin, the login page loads, the admin headers are there", async () => {
  const root = await admin("GET", "/");
  expect(root.status === 302 && /\/admin$/.test(root.headers.location ?? ""), `GET / gave ${root.status} ${root.headers.location}`);
  const exact = await admin("GET", "/admin/login");
  expect(exact.status === 200, `GET /admin/login gave ${exact.status}`);
  expect(exact.headers["x-frame-options"] === "DENY", `X-Frame-Options was ${exact.headers["x-frame-options"]}`);
  expect(exact.headers["content-security-policy"] === "frame-ancestors 'none'", `CSP was ${exact.headers["content-security-policy"]}`);
  expect(exact.headers["x-content-type-options"] === "nosniff", "nosniff missing on the admin");
  const api = await admin("GET", "/api/health");
  expect(api.status === 200 && api.json?.status === "ok", `the API on the admin domain gave ${api.status}`);
});

let home;
await step("the public site renders, and its own headers (CSP allowing the admin to frame it for Live Preview) are not touched", async () => {
  home = await site("GET", "/");
  expect(home.status === 200 && /Smoke Site/.test(home.text), `GET / gave ${home.status}`);
  const csp = home.headers["content-security-policy"] ?? "";
  expect(csp.includes(ADMIN), `the page's CSP does not allow ${ADMIN} to frame it: ${csp.slice(0, 200)}`);
  expect(home.headers["x-frame-options"] === undefined, `the site must not send X-Frame-Options (it breaks Live Preview), got ${home.headers["x-frame-options"]}`);
});

await step("a built script is served by the web app through the proxy (no shared static volume needed)", async () => {
  const m = /\/_nuxt\/[^"' ]+\.js/.exec(home?.text ?? "");
  expect(m, "no /_nuxt/*.js reference in the home page");
  const res = await site("GET", m[0]);
  expect(res.status === 200 && /javascript/.test(res.headers["content-type"] ?? ""), `GET ${m[0]} gave ${res.status} ${res.headers["content-type"]}`);
  return `cache-control: ${res.headers["cache-control"]}`;
});

await step("an unknown page is the branded 404 (status passes through)", async () => {
  const res = await site("GET", "/definitely-not-here");
  expect(res.status === 404 && /find that page/.test(res.text.replace(/&#39;/g, "'")), `GET gave ${res.status}`);
});

if (process.env.EXPECT_ACME_WEBROOT === "1") {
  await step("the certificate challenge path is answered by the proxy itself (certbot --webroot), not passed on to the app", async () => {
    const res = await site("GET", "/.well-known/acme-challenge/nothing-here");
    expect((res.status === 404 || res.status === 403) && !res.headers["x-powered-by"], `gave ${res.status}, x-powered-by ${res.headers["x-powered-by"]}`);
  });
}

await step("a forged Host that is neither the site nor the admin is not served", async () => {
  const res = await request("evil.example", "GET", "/", {}).catch((e) => ({ status: `closed (${e.code})`, text: "" }));
  expect(res.status !== 200 || !/Smoke Site/.test(res.text), "an unknown host got the site");
  return `status ${res.status}`;
});

let token = "";
await step("sign in through the proxy", async () => {
  const res = await admin("POST", "/api/users/login", { body: { email: EMAIL, password: PASSWORD } });
  expect(res.status === 200 && res.json?.token, `login gave ${res.status}`);
  token = res.json.token;
});

await step("an upload with a space in its name is stored, and served on the site with the long-cache header and nosniff", async () => {
  const png = tinyPng();
  const boundary = "----polysiteproxytest";
  const parts = [
    `--${boundary}\r\nContent-Disposition: form-data; name="_payload"\r\n\r\n{"alt":"proxy test","site":1}\r\n`,
    `--${boundary}\r\nContent-Disposition: form-data; name="file"; filename="my test image.png"\r\nContent-Type: image/png\r\n\r\n`,
  ];
  const body = Buffer.concat([Buffer.from(parts.join("")), png, Buffer.from(`\r\n--${boundary}--\r\n`)]);
  const up = await admin("POST", "/api/media", { body, headers: { "Content-Type": `multipart/form-data; boundary=${boundary}`, Authorization: `JWT ${token}` } });
  expect(up.status === 201, `upload gave ${up.status}: ${up.text.slice(0, 200)}`);
  const filename = up.json.doc.filename;
  expect(/my.test.image/.test(filename), `unexpected stored name ${filename}`);
  const onSite = await site("GET", `/api/media/file/${encodeURIComponent(filename)}`);
  expect(onSite.status === 200 && /^image\//.test(onSite.headers["content-type"] ?? ""), `the file gave ${onSite.status} ${onSite.headers["content-type"]}`);
  expect(onSite.buf.length > 20, "the file came back empty");
  expect(onSite.headers["cache-control"] === "public, max-age=86400", `Cache-Control was ${onSite.headers["cache-control"]}`);
  expect(onSite.headers["x-content-type-options"] === "nosniff", "nosniff missing on an uploaded file");
  const onAdmin = await admin("GET", `/api/media/file/${encodeURIComponent(filename)}`);
  expect(onAdmin.status === 200, `on the admin domain the file gave ${onAdmin.status}`);
  expect(onAdmin.headers["cache-control"] !== "public, max-age=86400", "the admin domain must not get the public cache header");
});

await step("a form submission may be 64 KB but not more, chunked or not; the rest of the API takes far more", async () => {
  const small = await site("POST", "/api/form-intake/1", { body: { data: { a: "x" } } });
  expect(!rejected(small), `a small body was refused (${small.status})`);
  const big = Buffer.alloc(70_000, 0x61);
  const sized = await site("POST", "/api/form-intake/1", { body: big, headers: { "Content-Type": "application/json" } });
  expect(rejected(sized), `70 KB with a length was ${sized.status}, expected 413`);
  const chunked = await site("POST", "/api/form-intake/1", { body: big, headers: { "Content-Type": "application/json" }, chunked: true });
  expect(rejected(chunked), `70 KB sent in chunks was ${chunked.status}, expected 413`);
  const other = await site("POST", "/api/users/login", { body: Buffer.alloc(70_000, 0x20), headers: { "Content-Type": "application/json" } });
  expect(!rejected(other), `70 KB to another API path was refused (${other.status}): the 64 KB cap must apply to form intake only`);
});

await step("a request body over 100 MB is refused; 60 MB reaches the app (which then judges it)", async () => {
  const over = await admin("POST", "/api/users/login", { body: Buffer.alloc(101_000_000, 0x20), headers: { "Content-Type": "application/json" } });
  expect(rejected(over), `101 MB was ${over.status}, expected 413`);
  const overChunked = await site("POST", "/api/users/login", { body: Buffer.alloc(101_000_000, 0x20), headers: { "Content-Type": "application/json" }, chunked: true });
  expect(rejected(overChunked), `101 MB in chunks was ${overChunked.status}, expected 413`);
  const under = await admin("POST", "/api/users/login", { body: Buffer.alloc(60_000_000, 0x20), headers: { "Content-Type": "application/json" } });
  expect(!rejected(under), `60 MB was refused by the proxy (${under.status})`);
  return `60 MB answered ${under.status}`;
});

await step("the Server header does not give the proxy's version away", async () => {
  const res = await site("GET", "/api/health");
  const server = res.headers.server;
  expect(!server || !/\d+\.\d+/.test(server), `Server: ${server}`);
  return server ? `Server: ${server}` : "no Server header";
});

await step("a forged X-Forwarded-For does not get around the sign-in limit (the proxy appends the address it saw)", async () => {
  // The CMS limits sign-ins per address, read from the LAST entry of X-Forwarded-For. The stack is started with a limit of 4.
  const statuses = [];
  for (let i = 0; i < 9; i++) {
    const res = await admin("POST", "/api/users/login", { body: { email: "nobody@example.test", password: "wrong-wrong-wrong" }, headers: { "X-Forwarded-For": `203.0.113.${i + 1}` } });
    statuses.push(res.status);
  }
  expect(statuses.includes(429), `no 429 in ${statuses.join(",")}: a forged header escaped the limit`);
  return statuses.join(",");
});

if (failures.length) {
  console.log(`\n${failures.length} check(s) failed:\n  - ${failures.join("\n  - ")}`);
  process.exit(1);
}
console.log("\nAll proxy checks passed.");
