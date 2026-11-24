// The narrow slice of the Cursor SDK the sidecar depends on. Keeping it behind
// an interface lets the fake SDK stand in for tests and for UI work without a
// Cursor account.

import type { Json, McpServer, Usage } from "./protocol.js";

export interface PortTool {
  description: string;
  inputSchema: { [key: string]: Json };
  readOnly?: boolean;
  execute(args: { [key: string]: Json }): Promise<PortToolResult>;
}

export interface PortToolResult {
  content: { type: "text"; text: string }[];
  isError?: boolean;
}

export interface PortAgentOptions {
  model: string;
  cwd: string;
  dirs: string[];
  builtinTools: string[];
  mcpServers: Record<string, McpServer>;
  tools: Record<string, PortTool>;
}

export type PortEvent =
  | { type: "text"; text: string }
  | { type: "thinking"; text: string }
  | { type: "tool.started"; callId: string; name: string; server?: string; args?: Json }
  | { type: "tool.finished"; callId: string; name: string; ok: boolean };

export interface PortRunResult {
  status: "finished" | "error" | "cancelled";
  error?: string;
  usage?: Usage;
}

export interface PortRun {
  /** Resolves when the turn is over. Events arrive through `onEvent` before that. */
  done: Promise<PortRunResult>;
  cancel(): Promise<void>;
}

export interface PortAgent {
  id: string;
  send(text: string, onEvent: (event: PortEvent) => void): Promise<PortRun>;
  close(): Promise<void>;
}

export interface AuthStatus {
  loggedIn: boolean;
  email?: string;
  via?: "apiKey" | "login";
}

export interface SdkPort {
  version: string;
  fake: boolean;
  authStatus(): Promise<AuthStatus>;
  login(onUrl: (url: string) => void): Promise<AuthStatus>;
  logout(): Promise<void>;
  listModels(): Promise<{ id: string; name: string }[]>;
  createAgent(options: PortAgentOptions): Promise<PortAgent>;
  resumeAgent(agentId: string, options: PortAgentOptions): Promise<PortAgent>;
}
