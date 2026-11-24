// Wire protocol between Crate.app (the host) and this sidecar.
// One JSON object per line: host -> sidecar on stdin, sidecar -> host on stdout.
// The Swift side mirrors these shapes in Sources/Crate/Agent/AgentProtocol.swift.

export type Json = string | number | boolean | null | Json[] | { [key: string]: Json };

/** A tool the host implements. The sidecar only forwards calls to it. */
export interface ToolSpec {
  name: string;
  description: string;
  inputSchema: { [key: string]: Json };
  readOnly?: boolean;
}

export type McpServer =
  | { type?: "stdio"; command: string; args?: string[]; env?: Record<string, string>; cwd?: string }
  | { type?: "http" | "sse"; url: string; headers?: Record<string, string> };

export interface SessionConfig {
  model: string;
  /** Agent working directory. Holds AGENTS.md, which carries the instructions. */
  cwd: string;
  /** Library folders, so the read-only file tools can look inside them. */
  dirs: string[];
  tools: ToolSpec[];
  mcpServers: Record<string, McpServer>;
  /** Built-in Cursor tools to allow. Must include "mcp" or host tools vanish. */
  builtinTools: string[];
  resumeId?: string;
}

export type HostMessage =
  | { type: "auth.status"; id: string }
  | { type: "auth.login"; id: string }
  | { type: "auth.logout"; id: string }
  | { type: "models.list"; id: string }
  | ({ type: "session.start"; id: string } & SessionConfig)
  | { type: "chat.send"; id: string; text: string }
  | { type: "chat.cancel" }
  | { type: "tool.result"; callId: string; ok: boolean; content: Json }
  | { type: "shutdown" };

export interface Usage {
  inputTokens?: number;
  outputTokens?: number;
}

export type SidecarMessage =
  | { type: "ready"; sdk: string; node: string; fake: boolean }
  | { type: "auth.status.result"; id: string; loggedIn: boolean; email?: string; via?: "apiKey" | "login" }
  | { type: "auth.login.url"; id: string; url: string }
  | { type: "models.list.result"; id: string; models: { id: string; name: string }[] }
  | { type: "session.started"; id: string; agentId: string; resumed: boolean }
  /** The resumed conversation could not take a new message (it was cut off mid-turn), so a fresh one replaced it. */
  | { type: "session.replaced"; id: string; agentId: string }
  | { type: "text.delta"; id: string; text: string }
  | { type: "thinking.delta"; id: string; text: string }
  | { type: "tool.started"; id: string; callId: string; name: string; server?: string; args?: Json }
  | { type: "tool.finished"; id: string; callId: string; name: string; ok: boolean }
  | { type: "tool.call"; callId: string; name: string; args: Json }
  | { type: "turn.ended"; id: string; status: "finished" | "error" | "cancelled"; error?: string; usage?: Usage }
  | { type: "error"; id?: string; code: string; message: string };
