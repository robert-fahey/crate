// Drives the built sidecar as a child process, the way Crate.app does, using
// the offline fake SDK. Run with `npm test` after `npm run build`.

import assert from "node:assert/strict";
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { createInterface } from "node:readline";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import type { HostMessage, SidecarMessage, ToolSpec } from "../src/protocol.js";

const mainPath = fileURLToPath(new URL("../src/main.js", import.meta.url));

class Host {
  private readonly child: ChildProcessWithoutNullStreams;
  private readonly received: SidecarMessage[] = [];
  private waiters: (() => void)[] = [];
  onToolCall: (name: string, args: unknown) => { ok: boolean; content: unknown } | undefined = () => undefined;

  constructor() {
    this.child = spawn(process.execPath, [mainPath], {
      env: { ...process.env, CRATE_FAKE_SDK: "1" },
      stdio: ["pipe", "pipe", "pipe"],
    });
    this.child.stderr.on("data", (chunk: Buffer) => process.stderr.write(chunk));
    createInterface({ input: this.child.stdout }).on("line", (line) => {
      const message = JSON.parse(line) as SidecarMessage;
      this.received.push(message);
      if (message.type === "tool.call") {
        const reply = this.onToolCall(message.name, message.args);
        if (reply) this.send({ type: "tool.result", callId: message.callId, ok: reply.ok, content: reply.content as never });
      }
      for (const wake of this.waiters.splice(0)) wake();
    });
  }

  send(message: HostMessage): void {
    this.child.stdin.write(`${JSON.stringify(message)}\n`);
  }

  async waitFor<T extends SidecarMessage["type"]>(type: T, from = 0): Promise<Extract<SidecarMessage, { type: T }>> {
    const deadline = Date.now() + 10_000;
    for (;;) {
      const found = this.received.slice(from).find((message) => message.type === type);
      if (found) return found as Extract<SidecarMessage, { type: T }>;
      if (Date.now() > deadline) throw new Error(`Timed out waiting for ${type}`);
      await Promise.race([
        new Promise<void>((resolve) => this.waiters.push(resolve)),
        new Promise<void>((resolve) => setTimeout(resolve, 200)),
      ]);
    }
  }

  get count(): number {
    return this.received.length;
  }

  all<T extends SidecarMessage["type"]>(type: T): Extract<SidecarMessage, { type: T }>[] {
    return this.received.filter((message) => message.type === type) as Extract<SidecarMessage, { type: T }>[];
  }

  async stop(): Promise<number | null> {
    const exited = new Promise<number | null>((resolve) => this.child.on("exit", resolve));
    this.child.stdin.end();
    return exited;
  }
}

const searchTool: ToolSpec = {
  name: "library_search",
  description: "Search the library",
  inputSchema: { type: "object", properties: { query: { type: "string" } } },
  readOnly: true,
};

function startSession(host: Host, tools: ToolSpec[] = [searchTool], resumeId?: string): void {
  host.send({
    type: "session.start",
    id: "s1",
    model: "offline",
    cwd: process.cwd(),
    dirs: [],
    tools,
    mcpServers: {},
    builtinTools: ["read", "mcp"],
    ...(resumeId ? { resumeId } : {}),
  });
}

test("announces itself, lists models and reports auth", async () => {
  const host = new Host();
  const ready = await host.waitFor("ready");
  assert.equal(ready.fake, true);
  host.send({ type: "models.list", id: "m1" });
  assert.deepEqual((await host.waitFor("models.list.result")).models[0]?.id, "offline");
  host.send({ type: "auth.status", id: "a1" });
  assert.equal((await host.waitFor("auth.status.result")).loggedIn, true);
  assert.equal(await host.stop(), 0);
});

test("a tool call round-trips through the host and its result is streamed back", async () => {
  const host = new Host();
  const calls: { name: string; args: unknown }[] = [];
  host.onToolCall = (name, args) => {
    calls.push({ name, args });
    return { ok: true, content: { tracks: [{ title: "Paradise", artist: "Change" }] } };
  };
  await host.waitFor("ready");
  startSession(host);
  assert.match((await host.waitFor("session.started")).agentId, /^agent-fake-/);

  host.send({ type: "chat.send", id: "c1", text: '/tool library_search {"query":"change","limit":3}' });
  const ended = await host.waitFor("turn.ended");
  assert.equal(ended.status, "finished");
  assert.deepEqual(calls, [{ name: "library_search", args: { query: "change", limit: 3 } }]);
  assert.equal(host.all("tool.started")[0]?.name, "library_search");
  assert.equal(host.all("tool.finished")[0]?.ok, true);
  const text = host.all("text.delta").map((delta) => delta.text).join("");
  assert.match(text, /Paradise/);
  await host.stop();
});

test("a failing tool is reported to the agent as an error, not a crash", async () => {
  const host = new Host();
  host.onToolCall = () => ({ ok: false, content: "The drive is not mounted." });
  await host.waitFor("ready");
  startSession(host);
  await host.waitFor("session.started");
  host.send({ type: "chat.send", id: "c1", text: "/tool library_search {}" });
  assert.equal((await host.waitFor("turn.ended")).status, "finished");
  assert.equal(host.all("tool.finished")[0]?.ok, false);
  assert.match(host.all("text.delta").map((delta) => delta.text).join(""), /not mounted/);
  await host.stop();
});

test("cancel stops a running turn and releases a tool the agent is waiting on", async () => {
  const host = new Host();
  await host.waitFor("ready");
  startSession(host);
  await host.waitFor("session.started");

  host.send({ type: "chat.send", id: "c1", text: "/slow" });
  await host.waitFor("text.delta");
  host.send({ type: "chat.cancel" });
  assert.equal((await host.waitFor("turn.ended")).status, "cancelled");

  // Now a tool the host never answers (a confirm sheet left open, say).
  const mark = host.count;
  host.onToolCall = () => undefined;
  host.send({ type: "chat.send", id: "c2", text: "/tool library_search {}" });
  await host.waitFor("tool.call", mark);
  host.send({ type: "chat.cancel" });
  const ended = await host.waitFor("turn.ended", mark);
  assert.equal(ended.id, "c2");
  assert.equal(ended.status, "cancelled");
  await host.stop();
});

test("sending without a session, or while busy, is refused with an error", async () => {
  const host = new Host();
  await host.waitFor("ready");
  host.send({ type: "chat.send", id: "c0", text: "hello" });
  assert.equal((await host.waitFor("error")).code, "no_session");

  startSession(host);
  await host.waitFor("session.started");
  const mark = host.count;
  host.send({ type: "chat.send", id: "c1", text: "/slow" });
  await host.waitFor("text.delta", mark);
  host.send({ type: "chat.send", id: "c2", text: "second" });
  const busy = await host.waitFor("error", mark);
  assert.equal(busy.code, "busy");
  assert.equal(busy.id, "c2");
  host.send({ type: "chat.cancel" });
  await host.waitFor("turn.ended", mark);
  assert.equal(await host.stop(), 0);
});

test("a send issued straight after session.start waits for the session", async () => {
  const host = new Host();
  host.onToolCall = () => ({ ok: true, content: "3 tracks" });
  await host.waitFor("ready");
  startSession(host);
  host.send({ type: "chat.send", id: "c1", text: "boogie" });
  assert.equal((await host.waitFor("turn.ended")).status, "finished");
  assert.equal(host.all("error").length, 0);
  assert.match(host.all("text.delta").map((delta) => delta.text).join(""), /3 tracks/);
  await host.stop();
});

test("a resumed conversation that was cut off mid-turn is replaced, and the message still goes through", async () => {
  const host = new Host();
  host.onToolCall = () => ({ ok: true, content: "3 tracks" });
  await host.waitFor("ready");
  startSession(host, [searchTool], "agent-stuck");
  const started = await host.waitFor("session.started");
  assert.equal(started.agentId, "agent-stuck");
  assert.equal(started.resumed, true);

  host.send({ type: "chat.send", id: "c1", text: "boogie" });
  const replaced = await host.waitFor("session.replaced");
  assert.match(replaced.agentId, /^agent-fake-/, "a fresh conversation takes over");
  assert.equal((await host.waitFor("turn.ended")).status, "finished");
  assert.equal(host.all("error").length, 0, "the person never sees the stuck conversation's error");
  assert.match(host.all("text.delta").map((delta) => delta.text).join(""), /3 tracks/);

  // The next message goes to the new conversation without another replacement.
  const before = host.count;
  host.send({ type: "chat.send", id: "c2", text: "disco" });
  assert.equal((await host.waitFor("turn.ended", before)).status, "finished");
  assert.equal(host.all("session.replaced").length, 1);
  await host.stop();
});
