// Protocol state machine: turns host messages into SDK calls and SDK events
// into sidecar messages. It owns no music logic. Every tool the agent can call
// is forwarded to the host and answered by a `tool.result` message.

import { randomUUID } from "node:crypto";
import type { HostMessage, Json, SessionConfig, SidecarMessage } from "./protocol.js";
import type { PortAgent, PortAgentOptions, PortEvent, PortRun, PortTool, PortToolResult, SdkPort } from "./sdk-port.js";

type Emit = (message: SidecarMessage) => void;

function asText(content: Json): string {
  return typeof content === "string" ? content : JSON.stringify(content);
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function errorCode(error: unknown): string {
  if (error instanceof Error) {
    const code = (error as { code?: unknown }).code;
    if (typeof code === "string") return code;
    return error.name;
  }
  return "Error";
}

export class Session {
  private agent: PortAgent | undefined;
  private run: PortRun | undefined;
  private readonly pendingTools = new Map<string, (result: PortToolResult) => void>();
  /** Settles when the latest session.start has finished, so a send queued right behind it waits. */
  private starting: Promise<void> = Promise.resolve();
  /** What the current agent was made with, to make another if it turns out to be stuck. */
  private options: PortAgentOptions | undefined;

  constructor(
    private readonly port: SdkPort,
    private readonly emit: Emit,
  ) {}

  /** Handles one host message. Never throws: failures become `error` messages. */
  async handle(message: HostMessage): Promise<void> {
    try {
      await this.dispatch(message);
    } catch (error) {
      const id = "id" in message ? message.id : undefined;
      this.emit({ type: "error", ...(id ? { id } : {}), code: errorCode(error), message: errorMessage(error) });
    }
  }

  private async dispatch(message: HostMessage): Promise<void> {
    switch (message.type) {
      case "auth.status":
        this.emit({ type: "auth.status.result", id: message.id, ...(await this.port.authStatus()) });
        return;
      case "auth.login": {
        const status = await this.port.login((url) => this.emit({ type: "auth.login.url", id: message.id, url }));
        this.emit({ type: "auth.status.result", id: message.id, ...status });
        return;
      }
      case "auth.logout":
        await this.port.logout();
        this.emit({ type: "auth.status.result", id: message.id, ...(await this.port.authStatus()) });
        return;
      case "models.list":
        this.emit({ type: "models.list.result", id: message.id, models: await this.port.listModels() });
        return;
      case "session.start":
        this.starting = this.start(message.id, message);
        await this.starting;
        return;
      case "chat.send":
        await this.send(message.id, message.text);
        return;
      case "chat.cancel":
        await this.cancel();
        return;
      case "tool.result":
        this.resolveTool(message.callId, {
          content: [{ type: "text", text: asText(message.content) }],
          ...(message.ok ? {} : { isError: true }),
        });
        return;
      case "shutdown":
        await this.close();
        return;
    }
  }

  private async start(id: string, config: SessionConfig): Promise<void> {
    if (this.run) throw Object.assign(new Error("A turn is still running."), { code: "busy" });
    await this.agent?.close();
    this.agent = undefined;

    const tools: Record<string, PortTool> = {};
    for (const spec of config.tools) {
      tools[spec.name] = {
        description: spec.description,
        inputSchema: spec.inputSchema,
        ...(spec.readOnly === undefined ? {} : { readOnly: spec.readOnly }),
        execute: (args) => this.callHost(spec.name, args),
      };
    }
    const options: PortAgentOptions = {
      model: config.model,
      cwd: config.cwd,
      dirs: config.dirs,
      builtinTools: config.builtinTools,
      mcpServers: config.mcpServers,
      tools,
    };

    this.options = options;
    let resumed = false;
    if (config.resumeId) {
      try {
        this.agent = await this.port.resumeAgent(config.resumeId, options);
        resumed = true;
      } catch {
        // The stored conversation is gone or unreadable; start a fresh one.
      }
    }
    this.agent ??= await this.port.createAgent(options);
    this.emit({ type: "session.started", id, agentId: this.agent.id, resumed });
  }

  private async send(id: string, text: string): Promise<void> {
    await this.starting.catch(() => {});
    if (!this.agent) throw Object.assign(new Error("No session. Send session.start first."), { code: "no_session" });
    if (this.run) throw Object.assign(new Error("A turn is already running."), { code: "busy" });

    const onEvent = (event: PortEvent): void => {
      switch (event.type) {
        case "text":
          this.emit({ type: "text.delta", id, text: event.text });
          break;
        case "thinking":
          this.emit({ type: "thinking.delta", id, text: event.text });
          break;
        case "tool.started":
          this.emit({ ...event, id });
          break;
        case "tool.finished":
          this.emit({ ...event, id });
          break;
      }
    };
    let run: PortRun;
    try {
      run = await this.agent.send(text, onEvent);
    } catch (error) {
      // A conversation whose last turn was cut off (the app quit while the agent was
      // working) still counts that turn as running and refuses every message after it.
      // It cannot be revived, so carry on in a new conversation rather than fail forever.
      if (!this.options || !/active run/i.test(errorMessage(error))) throw error;
      this.agent = await this.port.createAgent(this.options);
      this.emit({ type: "session.replaced", id, agentId: this.agent.id });
      run = await this.agent.send(text, onEvent);
    }
    this.run = run;
    try {
      const result = await run.done;
      this.emit({ type: "turn.ended", id, ...result });
    } catch (error) {
      this.emit({ type: "turn.ended", id, status: "error", error: errorMessage(error) });
    } finally {
      this.run = undefined;
      this.failPendingTools("The turn ended before this tool returned.");
    }
  }

  private async cancel(): Promise<void> {
    // Unblock any tool the agent is waiting on first, or the run cannot wind down.
    this.failPendingTools("Cancelled by the user.");
    await this.run?.cancel();
  }

  private callHost(name: string, args: Json): Promise<PortToolResult> {
    const callId = randomUUID();
    return new Promise<PortToolResult>((resolve) => {
      this.pendingTools.set(callId, resolve);
      this.emit({ type: "tool.call", callId, name, args });
    });
  }

  private resolveTool(callId: string, result: PortToolResult): void {
    const resolve = this.pendingTools.get(callId);
    if (!resolve) return;
    this.pendingTools.delete(callId);
    resolve(result);
  }

  private failPendingTools(reason: string): void {
    for (const callId of [...this.pendingTools.keys()]) {
      this.resolveTool(callId, { content: [{ type: "text", text: reason }], isError: true });
    }
  }

  async close(): Promise<void> {
    await this.cancel().catch(() => {});
    await this.agent?.close().catch(() => {});
    this.agent = undefined;
  }
}
