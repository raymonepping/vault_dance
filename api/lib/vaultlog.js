// lib/vaultlog.js: why a rotation failed, in Vault's own words.
//
// Vault 2.2.1 reports a failed rotation only in the active node's log
// ("rotation-job-manager: rotation failed, attempting to re-queue:
// rotationID=… error=…"); an account or role read has no error field
// (prompt 05). Every node writes its log to a file (log_file in its HCL); the
// API mounts the three log volumes read-only and reads only the new lines.
// Only lines for the ten known credentials are kept.
import { openSync, readSync, closeSync, statSync, readdirSync } from "node:fs";
import { all, rotationId } from "./credentials.js";

const LOG_DIRS = (process.env.VAULT_LOG_DIRS || "/var/log/vault/vault-1,/var/log/vault/vault-2,/var/log/vault/vault-3")
  .split(",")
  .filter(Boolean);
const MAX_READ = 256 * 1024;
const offsets = new Map(); // file → bytes read
let primed = false;

const LINE =
  /^(\S+)\s+\[ERROR\]\s+rotation-job-manager:\s+rotation failed[^:]*:\s+rotationID=(\S+)(?:\s+error="(.*)")?\s*$/;

// Pure: one log line → { at, rotationId, error } or null. A multi-line
// error has no error="…" on this line; parseLog collects it.
export function parseLine(line) {
  const m = LINE.exec(line);
  if (!m) return null;
  return {
    at: m[1],
    rotationId: m[2],
    error: (m[3] || "").replace(/\\"/g, '"').slice(0, 400),
  };
}

// Pure: a chunk of log text → failures. Vault writes a multi-line error as
//   <time> [ERROR] rotation-job-manager: rotation failed, …: rotationID=<id>
//     error=
//     | failed to rotate credential for account "x": You must wait longer …
//     | Process exited with status 10
export function parseLog(text) {
  const out = [];
  let cur = null;
  for (const line of text.split("\n")) {
    const f = parseLine(line);
    if (f) {
      cur = f;
      out.push(f);
      continue;
    }
    if (cur && !cur.error && /^\s+\|\s?/.test(line)) {
      cur.multi = [...(cur.multi || []), line.replace(/^\s+\|\s?/, "").trim()];
      continue;
    }
    if (cur && /^\s+error=\s*$/.test(line)) continue;
    if (cur?.multi) cur.error = cur.multi.filter(Boolean).join(" ").slice(0, 400);
    cur = null;
  }
  if (cur?.multi) cur.error = cur.multi.filter(Boolean).join(" ").slice(0, 400);
  for (const f of out) delete f.multi;
  return out;
}

function newest(dir) {
  try {
    const files = readdirSync(dir)
      .filter((f) => f.endsWith(".log"))
      .map((f) => ({ f: `${dir}/${f}`, t: statSync(`${dir}/${f}`).mtimeMs }))
      .sort((a, b) => b.t - a.t);
    return files[0]?.f || null;
  } catch {
    return null;
  }
}

function readNew(file) {
  let size;
  try {
    size = statSync(file).size;
  } catch {
    return "";
  }
  let from = offsets.get(file) ?? (primed ? 0 : size);
  if (from > size) from = 0; // rotated or truncated
  const len = Math.min(size - from, MAX_READ);
  offsets.set(file, from + len);
  if (len <= 0) return "";
  const buf = Buffer.alloc(len);
  const fd = openSync(file, "r");
  try {
    readSync(fd, buf, 0, len, from);
  } finally {
    closeSync(fd);
  }
  return buf.toString("utf8");
}

// New failure lines since the last call, mapped to credential ids. The first
// call only remembers where each file ends (history stays in the files).
export function readFailures() {
  const known = new Map(all().map((c) => [rotationId(c), c.id]));
  const out = [];
  for (const dir of LOG_DIRS) {
    const file = newest(dir);
    if (!file) continue;
    for (const f of parseLog(readNew(file))) {
      if (!known.has(f.rotationId)) continue;
      out.push({
        id: known.get(f.rotationId),
        node: dir.split("/").pop(),
        vaultTime: f.at,
        detail: f.error,
      });
    }
  }
  primed = true;
  return out;
}

export function logsAvailable() {
  return LOG_DIRS.map((d) => ({ node: d.split("/").pop(), file: newest(d) !== null }));
}
