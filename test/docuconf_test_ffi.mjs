import { execSync } from "node:child_process";

export function shell(cmd) {
  try {
    const out = execSync(cmd, { shell: "/bin/sh", encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
    return [0, out];
  } catch (e) {
    return [e.status ?? -1, (e.stdout ?? "") + (e.stderr ?? "")];
  }
}
