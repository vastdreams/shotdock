import React from "react";
import { createRoot } from "react-dom/client";
import { useAppState } from "./api";
import { Hub } from "./views/Hub";
import { Widget } from "./views/Widget";
import "./styles.css";

const view = new URLSearchParams(location.search).get("view") ?? "hub";
document.documentElement.dataset.view = view;
document.documentElement.dataset.platform = window.shotdock.platform;

function App() {
  const state = useAppState();
  if (!state) return <div className="loading">Loading…</div>;
  return view === "widget" ? <Widget state={state} /> : <Hub state={state} />;
}

createRoot(document.getElementById("root")!).render(<App />);
