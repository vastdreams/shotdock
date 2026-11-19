import React from "react";
import { createRoot } from "react-dom/client";
import { useAppState } from "./api";
import { Hub } from "./views/Hub";
import { Widget } from "./views/Widget";
import { Bar } from "./views/Bar";
import "./styles.css";

const view = new URLSearchParams(location.search).get("view") ?? "hub";
// Window errors go to ShotDock's log (redacted there), so problems in the UI are never silent.
const report = (msg: string) => void window.shotdock.invoke("log.renderer", { level: "error", msg: `[${view}] ${msg}`.slice(0, 4000) });
window.addEventListener("error", (e) => report(`${e.message} @ ${e.filename}:${e.lineno}`));
window.addEventListener("unhandledrejection", (e) => report(`unhandled: ${String((e as PromiseRejectionEvent).reason?.stack ?? (e as PromiseRejectionEvent).reason)}`));
document.documentElement.dataset.view = view;
document.documentElement.dataset.platform = window.shotdock.platform;

function App() {
  const state = useAppState();
  if (!state) return <div className="loading">Loading…</div>;
  return view === "widget" ? <Widget state={state} /> : view === "bar" ? <Bar state={state} /> : <Hub state={state} />;
}

createRoot(document.getElementById("root")!).render(<App />);
