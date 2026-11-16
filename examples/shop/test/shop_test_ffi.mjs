import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";

// A new, empty directory.
export function temp_dir() {
  return mkdtempSync(join(tmpdir(), "shop-test-"));
}

// Writes a file, creating its directory.
export function write_file(path, text) {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, text);
  return undefined;
}

export function remove_dir(path) {
  rmSync(path, { recursive: true, force: true });
  return undefined;
}
