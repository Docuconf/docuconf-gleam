import { execSync } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import { Ok, Error, toList } from "./gleam.mjs";

export function shell(cmd) {
  try {
    const out = execSync(cmd, { shell: "/bin/sh", encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
    return [0, out];
  } catch (e) {
    return [e.status ?? -1, (e.stdout ?? "") + (e.stderr ?? "")];
  }
}

// [`${case id} ${var}`, digits] for every expected value that is an integer
// beyond ±(2^53 - 1), from the source text: JSON.parse rounds them.
export function big_expects(text) {
  const big = (_k, v, ctx) =>
    typeof v === "number" && !Number.isSafeInteger(v) && /^-?[0-9]+$/.test(ctx?.source ?? "") ? { digits: ctx.source } : v;
  const out = [];
  for (const c of JSON.parse(text, big).cases) {
    for (const [name, v] of Object.entries(c.expect ?? {})) {
      if (v !== null && typeof v === "object" && typeof v.digits === "string") out.push([`${c.id} ${name}`, v.digits]);
    }
  }
  return toList(out);
}

export function target() {
  return "javascript";
}

export function read_file(path) {
  try {
    return new Ok(readFileSync(path, "utf8"));
  } catch {
    return new Error(undefined);
  }
}

let remembered = [];

// A list of strings kept between calls, for callbacks.
export function remember(s) {
  remembered.push(s);
  return undefined;
}

export function recall() {
  const l = toList(remembered);
  remembered = [];
  return l;
}

// Writes bytes to a file, creating its directory.
export function write_bytes(path, bits) {
  const bytes = Buffer.alloc(bits.byteSize);
  for (let i = 0; i < bits.byteSize; i++) bytes[i] = bits.byteAt(i);
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, bytes);
  return undefined;
}

// Runs f after ms milliseconds, letting timers run meanwhile; gleeunit
// awaits the promise a test returns.
export function after(ms, f) {
  return new Promise((resolve, reject) =>
    setTimeout(() => {
      try {
        resolve(f());
      } catch (e) {
        reject(e);
      }
    }, ms),
  );
}
