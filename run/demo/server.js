import { execFileSync } from "node:child_process";
import http from "node:http";
import path from "node:path";
import fs from "node:fs";
import { Readable } from "node:stream";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const workspaceRoot = path.resolve(__dirname, "../..");
const publicDir = path.join(__dirname, "public");
const teldriveComposeDir = path.join(workspaceRoot, "run", "teldrive");

const host = process.env.HOST || "127.0.0.1";
const port = Number.parseInt(process.env.PORT || "8890", 10);
const teldriveOrigin = process.env.TELDRIVE_ORIGIN || "http://127.0.0.1:8787";

const staticTypes = new Map([
  [".html", "text/html; charset=utf-8"],
  [".css", "text/css; charset=utf-8"],
  [".js", "text/javascript; charset=utf-8"],
  [".json", "application/json; charset=utf-8"]
]);

let cachedSession = { hash: "", at: 0 };

function runPsql(sql) {
  return execFileSync(
    "docker",
    ["compose", "exec", "-T", "postgres", "psql", "-U", "teldrive", "-d", "postgres", "-t", "-A", "-c", sql],
    {
      cwd: teldriveComposeDir,
      encoding: "utf8",
      windowsHide: true,
      timeout: 15000
    }
  ).trim();
}

function getSessionHash() {
  const now = Date.now();
  if (cachedSession.hash && now - cachedSession.at < 5000) {
    return cachedSession.hash;
  }

  const hash = runPsql("select hash from teldrive.sessions order by session_date desc limit 1;");
  cachedSession = { hash, at: now };
  return hash;
}

function discoverMedia() {
  const sql = `
    select coalesce(json_agg(row_to_json(x)), '[]'::json)
    from (
      select
        id::text,
        name,
        mime_type,
        size,
        category,
        created_at,
        updated_at
      from teldrive.files
      where type = 'file'
        and status = 'active'
        and (
          category in ('image', 'video')
          or mime_type like 'image/%'
          or mime_type like 'video/%'
        )
      order by created_at desc
      limit 80
    ) x;
  `;
  const raw = runPsql(sql);
  const rows = JSON.parse(raw || "[]");
  return rows.map((item) => {
    const kind = String(item.mime_type || "").startsWith("video/") || item.category === "video" ? "video" : "image";
    return {
      ...item,
      kind,
      media_url: `/media/${encodeURIComponent(item.id)}/${encodeURIComponent(item.name)}`
    };
  });
}

function sendJson(res, status, body) {
  const payload = JSON.stringify(body, null, 2);
  res.writeHead(status, {
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": Buffer.byteLength(payload),
    "Cache-Control": "no-store"
  });
  res.end(payload);
}

function sendStatic(req, res, pathname) {
  const targetPath = pathname === "/" ? "/index.html" : pathname;
  const filePath = path.resolve(publicDir, `.${decodeURIComponent(targetPath)}`);
  if (!filePath.startsWith(publicDir)) {
    res.writeHead(404);
    return res.end("Not found");
  }

  if (!fs.existsSync(filePath) || !fs.statSync(filePath).isFile()) {
    res.writeHead(404);
    return res.end("Not found");
  }

  const ext = path.extname(filePath).toLowerCase();
  const stat = fs.statSync(filePath);
  res.writeHead(200, {
    "Content-Type": staticTypes.get(ext) || "application/octet-stream",
    "Content-Length": stat.size,
    "Cache-Control": "no-cache"
  });
  if (req.method === "HEAD") {
    return res.end();
  }
  fs.createReadStream(filePath).pipe(res);
}

async function proxyMedia(req, res, id, filename) {
  const hash = getSessionHash();
  if (!hash) {
    sendJson(res, 503, { error: "No active Teldrive session found. Log in to Teldrive first." });
    return;
  }

  const upstreamUrl = `${teldriveOrigin}/api/files/${encodeURIComponent(id)}/${encodeURIComponent(filename)}?hash=${encodeURIComponent(hash)}`;
  const headers = {};
  if (req.headers.range) headers.Range = req.headers.range;
  if (req.headers["user-agent"]) headers["User-Agent"] = req.headers["user-agent"];

  const upstream = await fetch(upstreamUrl, {
    method: req.method === "HEAD" ? "GET" : req.method,
    headers
  });

  const responseHeaders = {};
  for (const name of [
    "accept-ranges",
    "content-disposition",
    "content-length",
    "content-range",
    "content-type",
    "etag",
    "last-modified"
  ]) {
    const value = upstream.headers.get(name);
    if (value) responseHeaders[name] = value;
  }
  responseHeaders["cache-control"] = "private, max-age=30";

  res.writeHead(upstream.status, responseHeaders);
  if (req.method === "HEAD" || !upstream.body) {
    return res.end();
  }
  Readable.fromWeb(upstream.body).pipe(res);
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url || "/", `http://${req.headers.host || `${host}:${port}`}`);

  try {
    if (url.pathname === "/api/catalog") {
      const items = discoverMedia();
      return sendJson(res, 200, {
        teldrive_origin: teldriveOrigin,
        count: items.length,
        items
      });
    }

    const mediaMatch = /^\/media\/([^/]+)\/(.+)$/.exec(url.pathname);
    if (mediaMatch) {
      return proxyMedia(req, res, decodeURIComponent(mediaMatch[1]), decodeURIComponent(mediaMatch[2]));
    }

    if (req.method === "GET" || req.method === "HEAD") {
      return sendStatic(req, res, url.pathname);
    }

    sendJson(res, 405, { error: "Method not allowed" });
  } catch (error) {
    console.error(error);
    sendJson(res, 500, { error: error.message || "Internal server error" });
  }
});

server.listen(port, host, () => {
  console.log(`TeleDrive demo listening on http://${host}:${port}`);
  console.log(`Proxying Teldrive media from ${teldriveOrigin}`);
});
