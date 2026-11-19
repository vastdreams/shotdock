// The only API renderers get: invoke a typed request, and subscribe to state / navigation pushes.

import { contextBridge, ipcRenderer } from "electron";

const CHANNEL_INVOKE = "shotdock:invoke";
const CHANNEL_STATE = "shotdock:state";
const CHANNEL_NAV = "shotdock:nav";

contextBridge.exposeInMainWorld("shotdock", {
  platform: process.platform,
  invoke: (name: string, args?: unknown) => ipcRenderer.invoke(CHANNEL_INVOKE, name, args ?? {}),
  onState: (fn: (s: unknown) => void) => {
    const h = (_e: unknown, s: unknown) => fn(s);
    ipcRenderer.on(CHANNEL_STATE, h);
    return () => ipcRenderer.removeListener(CHANNEL_STATE, h);
  },
  onNav: (fn: (n: unknown) => void) => {
    const h = (_e: unknown, n: unknown) => fn(n);
    ipcRenderer.on(CHANNEL_NAV, h);
    return () => ipcRenderer.removeListener(CHANNEL_NAV, h);
  },
});
