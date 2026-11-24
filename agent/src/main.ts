// Crate agent sidecar entry point.
// stdin: one HostMessage per line. stdout: one SidecarMessage per line.
// stdout carries nothing but protocol; all logging goes to stderr.

import { createInterface } from "node:readline";
import type { HostMessage, SidecarMessage } from "./protocol.js";
import type { SdkPort } from "./sdk-port.js";
import { Session } from "./session.js";

const protocolOut = process.stdout.write.bind(process.stdout);
for (const level of ["log", "info", "debug", "warn"] as const) {
  console[level] = (...args: unknown[]) => console.error(...args);
}

function emit(message: SidecarMessage): void {
  protocolOut(`${JSON.stringify(message)}\n`);
}

async function loadPort(): Promise<SdkPort> {
  if (process.env["CRATE_FAKE_SDK"] === "1") {
    return (await import("./fake-sdk.js")).createFakeSdkPort();
  }
  return (await import("./cursor-sdk.js")).createCursorSdkPort();
}

const port = await loadPort();
const session = new Session(port, emit);
emit({ type: "ready", sdk: port.version, node: process.version, fake: port.fake });

let exiting = false;
async function exit(code: number): Promise<void> {
  if (exiting) return;
  exiting = true;
  await session.close();
  process.exit(code);
}

const lines = createInterface({ input: process.stdin, crlfDelay: Infinity });
lines.on("line", (line) => {
  if (!line.trim()) return;
  let message: HostMessage;
  try {
    message = JSON.parse(line) as HostMessage;
  } catch {
    emit({ type: "error", code: "bad_json", message: "Could not parse a host message as JSON." });
    return;
  }
  if (message.type === "shutdown") {
    void exit(0);
    return;
  }
  // Not awaited: a chat turn stays in flight while tool results and cancel arrive.
  void session.handle(message);
});
// The host closing our stdin means the app has gone away.
lines.on("close", () => void exit(0));
process.on("SIGTERM", () => void exit(0));
process.on("SIGINT", () => void exit(0));
