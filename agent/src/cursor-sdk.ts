// SdkPort backed by the real @cursor/sdk local runtime.

import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { join, sep } from "node:path";
import { Agent, Cursor } from "@cursor/sdk";
import type {
  AgentOptions,
  InteractionUpdate,
  McpServerConfig,
  SDKAgent,
  SDKCustomTool,
  SDKJsonValue,
} from "@cursor/sdk";
import type { Json } from "./protocol.js";
import type {
  AuthStatus,
  PortAgent,
  PortAgentOptions,
  PortEvent,
  PortRun,
  SdkPort,
} from "./sdk-port.js";

const CUSTOM_TOOLS_SERVER = "custom-user-tools";

function sdkVersion(): string {
  // A compiled single-file build has no node_modules to look in; build.sh bakes the version in.
  if (process.env.CRATE_SDK_VERSION) return process.env.CRATE_SDK_VERSION;
  // package.json is not an exported subpath, so find it from the entry file.
  try {
    const entry = createRequire(import.meta.url).resolve("@cursor/sdk");
    const root = entry.slice(0, entry.lastIndexOf(`${sep}dist${sep}`));
    return (JSON.parse(readFileSync(join(root, "package.json"), "utf8")) as { version: string }).version;
  } catch {
    return "unknown";
  }
}

function toAgentOptions(options: PortAgentOptions): AgentOptions {
  const customTools: Record<string, SDKCustomTool> = {};
  for (const [name, tool] of Object.entries(options.tools)) {
    customTools[name] = {
      description: tool.description,
      inputSchema: tool.inputSchema as Record<string, SDKJsonValue>,
      annotations: { readOnlyHint: tool.readOnly === true },
      execute: (args) => tool.execute(args as { [key: string]: Json }),
    };
  }
  return {
    name: "Crate",
    model: { id: options.model },
    // An allow-list: shell, edit, write and delete are simply never offered.
    tools: options.builtinTools,
    mcpServers: options.mcpServers as Record<string, McpServerConfig>,
    local: {
      cwd: options.cwd,
      dirs: options.dirs,
      // "project" loads AGENTS.md from cwd. Never "user": that would pull the
      // MCP servers configured for the Cursor editor into the music player.
      settingSources: ["project"],
      customTools,
    },
  };
}

/** Pulls a display name out of the SDK's tool-call union without trusting its shape. */
function describeToolCall(toolCall: unknown): { name: string; server?: string; args?: Json } {
  const call = (toolCall ?? {}) as { type?: string; args?: Record<string, unknown> };
  const args = call.args ?? {};
  if (call.type === "mcp") {
    const server = typeof args["providerIdentifier"] === "string" ? args["providerIdentifier"] : undefined;
    const name = typeof args["toolName"] === "string" ? args["toolName"] : "mcp";
    return {
      name,
      ...(server && server !== CUSTOM_TOOLS_SERVER ? { server } : {}),
      args: (args["args"] ?? {}) as Json,
    };
  }
  return { name: call.type ?? "tool", args: args as Json };
}

function toolCallSucceeded(toolCall: unknown): boolean {
  const result = (toolCall as { result?: { status?: string; value?: { isError?: boolean } } } | undefined)?.result;
  if (!result) return true;
  if (result.status && result.status !== "success") return false;
  return result.value?.isError !== true;
}

function wrap(agent: SDKAgent): PortAgent {
  return {
    id: agent.agentId,
    async send(text, onEvent): Promise<PortRun> {
      let sawTextDelta = false;
      const onDelta = ({ update }: { update: InteractionUpdate }): void => {
        let event: PortEvent | undefined;
        switch (update.type) {
          case "text-delta":
            sawTextDelta = true;
            event = { type: "text", text: update.text };
            break;
          case "thinking-delta":
            event = { type: "thinking", text: update.text };
            break;
          case "tool-call-started":
            event = { type: "tool.started", callId: update.callId, ...describeToolCall(update.toolCall) };
            break;
          case "tool-call-completed": {
            const { name } = describeToolCall(update.toolCall);
            event = { type: "tool.finished", callId: update.callId, name, ok: toolCallSucceeded(update.toolCall) };
            break;
          }
          default:
            break;
        }
        if (event) onEvent(event);
      };

      const run = await agent.send(text, { onDelta });
      const done = (async () => {
        // The stream has to be drained for the run to make progress. Deltas
        // normally carry the text; whole assistant messages are the fallback.
        for await (const message of run.stream()) {
          if (message.type === "assistant" && !sawTextDelta) {
            for (const block of message.message.content) {
              if (block.type === "text") onEvent({ type: "text", text: block.text });
            }
          }
        }
        const result = await run.wait();
        return {
          status: result.status,
          ...(result.error ? { error: result.error.message } : {}),
          ...(result.usage
            ? { usage: { inputTokens: result.usage.inputTokens, outputTokens: result.usage.outputTokens } }
            : {}),
        };
      })();
      return {
        done,
        async cancel() {
          if (run.supports("cancel")) await run.cancel();
        },
      };
    },
    async close() {
      await agent[Symbol.asyncDispose]();
    },
  };
}

export function createCursorSdkPort(): SdkPort {
  const authStatus = async (): Promise<AuthStatus> => {
    if (process.env["CURSOR_API_KEY"]) return { loggedIn: true, via: "apiKey" };
    const status = await Cursor.auth.status();
    if (status.status !== "logged-in") return { loggedIn: false };
    return { loggedIn: true, via: "login", ...(status.email ? { email: status.email } : {}) };
  };

  return {
    version: sdkVersion(),
    fake: false,
    authStatus,
    async login(onUrl) {
      await Cursor.auth.login({ apiKeyName: "Crate music player", onLoginUrl: onUrl });
      return authStatus();
    },
    async logout() {
      await Cursor.auth.logout();
    },
    async listModels() {
      const models = await Cursor.models.list();
      return models.map((model) => ({ id: model.id, name: model.displayName }));
    },
    async createAgent(options) {
      return wrap(await Agent.create(toAgentOptions(options)));
    },
    async resumeAgent(agentId, options) {
      return wrap(await Agent.resume(agentId, toAgentOptions(options)));
    },
  };
}
