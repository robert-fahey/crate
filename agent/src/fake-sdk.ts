// An offline stand-in for the Cursor SDK, selected with CRATE_FAKE_SDK=1.
// It makes no network calls and costs nothing, so the app's agent plumbing
// (streaming, tool round-trips, cancel) can be developed and tested without a
// Cursor account. It is not an AI: it follows the small script below.
//
//   /tool <name> <json args>   call one host tool and print what it returned
//   /slow                      stream text slowly until cancelled
//   anything else              run library_search with the text, if that tool exists

import type { Json } from "./protocol.js";
import type { PortAgent, PortAgentOptions, PortEvent, PortRun, PortRunResult, SdkPort } from "./sdk-port.js";

const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

function makeAgent(id: string, options: PortAgentOptions): PortAgent {
  let callCounter = 0;

  async function callTool(name: string, args: { [key: string]: Json }, onEvent: (e: PortEvent) => void): Promise<string> {
    const tool = options.tools[name];
    if (!tool) return `No tool named "${name}". Available: ${Object.keys(options.tools).join(", ") || "none"}.`;
    const callId = `fake-call-${++callCounter}`;
    onEvent({ type: "tool.started", callId, name, args });
    const result = await tool.execute(args);
    onEvent({ type: "tool.finished", callId, name, ok: result.isError !== true });
    return result.content.map((part) => part.text).join("\n");
  }

  return {
    id,
    async send(text, onEvent): Promise<PortRun> {
      let cancelled = false;
      const say = async (message: string) => {
        for (const word of message.split(/(?<=\s)/)) {
          if (cancelled) return;
          onEvent({ type: "text", text: word });
          await sleep(5);
        }
      };

      const done = (async (): Promise<PortRunResult> => {
        const trimmed = text.trim();
        if (trimmed === "/slow") {
          for (let i = 0; i < 2000 && !cancelled; i++) {
            onEvent({ type: "text", text: `tick ${i} ` });
            await sleep(20);
          }
        } else if (trimmed.startsWith("/tool ")) {
          const [, name = "", rest = ""] = /^\/tool\s+(\S+)\s*([\s\S]*)$/.exec(trimmed) ?? [];
          let args: { [key: string]: Json } = {};
          if (rest.trim()) {
            try {
              args = JSON.parse(rest) as { [key: string]: Json };
            } catch {
              await say(`Could not parse the arguments as JSON: ${rest}`);
              return { status: "finished" };
            }
          }
          await say(await callTool(name, args, onEvent));
        } else if (options.tools["library_search"]) {
          await say("(offline agent) Searching your library. ");
          await say(await callTool("library_search", { query: trimmed, limit: 5 }, onEvent));
        } else {
          await say(`(offline agent) You said: ${trimmed}`);
        }
        return cancelled ? { status: "cancelled" } : { status: "finished", usage: { inputTokens: 0, outputTokens: 0 } };
      })();

      return {
        done,
        async cancel() {
          cancelled = true;
        },
      };
    },
    async close() {},
  };
}

export function createFakeSdkPort(): SdkPort {
  let counter = 0;
  return {
    version: "fake",
    fake: true,
    async authStatus() {
      return { loggedIn: true, via: "apiKey" };
    },
    async login(onUrl) {
      onUrl("https://example.invalid/fake-login");
      return { loggedIn: true, via: "login" };
    },
    async logout() {},
    async listModels() {
      return [{ id: "offline", name: "Offline test agent (no AI)" }];
    },
    async createAgent(options) {
      return makeAgent(`agent-fake-${++counter}`, options);
    },
    async resumeAgent(agentId, options) {
      const agent = makeAgent(agentId, options);
      // "agent-stuck" stands in for a conversation that was cut off mid-turn.
      if (agentId !== "agent-stuck") return agent;
      return {
        ...agent,
        async send() {
          throw new Error(`Agent ${agentId} already has active run`);
        },
      };
    },
  };
}
