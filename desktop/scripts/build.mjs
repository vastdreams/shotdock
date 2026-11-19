// Build: esbuild for main + preload (CommonJS, Node), Vite for the renderer. Output in dist/.
import { build } from "esbuild";
import { build as viteBuild } from "vite";
import react from "@vitejs/plugin-react";
import { rmSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
rmSync(path.join(root, "dist"), { recursive: true, force: true });

const common = { bundle: true, platform: "node", format: "cjs", target: "node22", sourcemap: true, logLevel: "warning",
                 external: ["electron", "@anthropic-ai/claude-agent-sdk"] };
await build({ ...common, entryPoints: [path.join(root, "src/main/index.ts")], outfile: path.join(root, "dist/main/index.js") });
await build({ ...common, entryPoints: [path.join(root, "src/preload/index.ts")], outfile: path.join(root, "dist/preload/index.js") });

// macOS element helper (Swift). Kept outside app.asar when packaged (asarUnpack: assets/bin).
if (process.platform === "darwin") {
  const { execFileSync } = await import("node:child_process");
  const { mkdirSync } = await import("node:fs");
  mkdirSync(path.join(root, "assets/bin"), { recursive: true });
  execFileSync("swiftc", ["-O", "-o", path.join(root, "assets/bin/shotdock-element"), path.join(root, "native/macos/element.swift")], { stdio: "inherit" });
}

await viteBuild({
  root: path.join(root, "src/renderer"), base: "./", logLevel: "warn", plugins: [react()],
  build: { outDir: path.join(root, "dist/renderer"), emptyOutDir: true, target: "chrome130", sourcemap: true },
});
console.log("built dist/");
