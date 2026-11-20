// Typed IPC contract between main and renderers. Every request is validated with zod in main before it runs.
// Renderers call window.shotdock.invoke(name, args); main pushes "state" snapshots on the "state" channel.

import { z } from "zod";

export const Requests = {
  "state.get": z.object({}),
  "transcript.load": z.object({ id: z.string().min(1) }),
  "session.new": z.object({ folder: z.string().min(1), prompt: z.string().default(""), model: z.string().optional() }),
  "session.send": z.object({ id: z.string().min(1), text: z.string(), shotIds: z.array(z.string()).default([]) }),
  "session.stop": z.object({ id: z.string().min(1) }),
  "session.permission": z.object({
    id: z.string().min(1), requestId: z.string().min(1), decision: z.enum(["allow", "always", "deny"]),
  }),
  "session.takeOver": z.object({ id: z.string().min(1), fork: z.boolean().default(false), confirmClosed: z.boolean().default(false) }),
  "session.openTerminal": z.object({ id: z.string().optional(), folder: z.string().optional() }),
  "checks.run": z.object({ id: z.string().min(1) }),
  "session.handBack": z.object({ id: z.string().min(1) }),
  "session.openInEditor": z.object({ id: z.string().min(1) }),
  "session.setModel": z.object({ id: z.string().min(1), model: z.string().min(1) }),
  "shot.capture": z.object({ mode: z.enum(["area", "window", "screen", "element"]).default("area") }),
  "shot.assign": z.object({ id: z.string().min(1), sessionId: z.string().min(1) }),
  "shot.save": z.object({ id: z.string().min(1), dataUrl: z.string().max(60_000_000) }),
  "shot.paste": z.object({ dataUrl: z.string().max(40_000_000) }),
  "voice.transcribe": z.object({ wavBase64: z.string().min(100).max(80_000_000) }),
  "voice.status": z.object({}),
  "shot.remove": z.object({ id: z.string().min(1) }),
  "transcript.close": z.object({ id: z.string().min(1) }),
  "shot.clear": z.object({}),
  "folder.pick": z.object({}),
  "settings.update": z.object({
    connection: z.enum(["claude-code", "api-key"]).optional(),
    model: z.string().min(1).optional(),
    permissionMode: z.enum(["default", "acceptEdits", "plan"]).optional(),
    alwaysOnTop: z.boolean().optional(),
    showOnAllDesktops: z.boolean().optional(),
    recentDays: z.number().int().min(1).max(30).optional(),
    closeTo: z.enum(["bar", "menubar"]).optional(),
  }),
  "settings.setApiKey": z.object({ key: z.string() }),  // "" clears it
  "settings.test": z.object({}),
  "window.show": z.object({ view: z.enum(["hub", "settings"]), sessionId: z.string().optional() }),
  "window.hideWidget": z.object({}),
  "app.quit": z.object({}),
  "permissions.get": z.object({}),
  "log.renderer": z.object({ level: z.enum(["error", "warn", "info"]), msg: z.string().max(4000) }),
  "files.changes": z.object({ folder: z.string().min(1) }),
  "files.read": z.object({ folder: z.string().min(1), path: z.string().min(1) }),
  "files.write": z.object({ folder: z.string().min(1), path: z.string().min(1), content: z.string().max(8_000_000) }),
  "files.list": z.object({ folder: z.string().min(1), query: z.string().default("") }),
  "window.collapse": z.object({}),
  "window.expand": z.object({}),
  "window.widgetFromBar": z.object({}),
  "permissions.open": z.object({ which: z.enum(["screen", "accessibility"]) }),
} as const;

export type RequestName = keyof typeof Requests;
export type RequestArgs<N extends RequestName> = z.input<(typeof Requests)[N]>;

/** Every request resolves to this: ok with an optional value, or a coded error the UI can show. */
export type Result<T = unknown> = { ok: true; value?: T } | { ok: false; code: string; message: string };

export const ok = <T>(value?: T): Result<T> => ({ ok: true, value });
export const fail = (code: string, message: string): Result<never> => ({ ok: false, code, message });

export const CHANNEL_INVOKE = "shotdock:invoke";
export const CHANNEL_STATE = "shotdock:state";
export const CHANNEL_NAV = "shotdock:nav";
