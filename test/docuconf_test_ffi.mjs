import { execSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { Ok, Error, toList } from "./gleam.mjs";

export function shell(cmd) {
  try {
    const out = execSync(cmd, { shell: "/bin/sh", encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
    return [0, out];
  } catch (e) {
    return [e.status ?? -1, (e.stdout ?? "") + (e.stderr ?? "")];
  }
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
