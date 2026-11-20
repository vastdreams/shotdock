// Voice to text, on this Mac only: the renderer records 16 kHz mono WAV, whisper.cpp turns it into text.
// Nothing leaves the machine. Needs `brew install whisper-cpp` and a model in ~/Library/Application Support/ShotDock/whisper.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFile } from "node:child_process";
import { ok, fail, type Result } from "../shared/ipc";
import { log } from "./core/log";

const MODEL_DIR = path.join(os.homedir(), "Library", "Application Support", "ShotDock", "whisper");
const MODELS = ["ggml-small.en.bin", "ggml-base.en.bin", "ggml-tiny.en.bin"];   // best first
const BINS = ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli", "/opt/homebrew/bin/whisper-cpp"];

const firstExisting = (paths: string[]) => paths.find((p) => { try { return fs.statSync(p).size > 0; } catch { return false; } });
const binary = () => firstExisting(BINS);
const model = () => firstExisting(MODELS.map((m) => path.join(MODEL_DIR, m)));

export function voiceStatus(): { ready: boolean; reason?: string } {
  if (!binary()) return { ready: false, reason: "Install the speech engine: brew install whisper-cpp" };
  if (!model()) return { ready: false, reason: `Add a Whisper model to ${MODEL_DIR}` };
  return { ready: true };
}

export function transcribe(wavBase64: string): Promise<Result<unknown>> {
  const st = voiceStatus();
  if (!st.ready) return Promise.resolve(fail("voice_unavailable", st.reason ?? "Voice is not set up."));
  const file = path.join(os.tmpdir(), `shotdock-voice-${Date.now()}.wav`);
  fs.writeFileSync(file, Buffer.from(wavBase64, "base64"));
  const args = ["-m", model()!, "-f", file, "-l", "en", "-nt", "-np", "-t", String(Math.max(2, Math.min(8, os.cpus().length - 2)))];
  return new Promise((resolve) => {
    execFile(binary()!, args, { timeout: 120_000, maxBuffer: 8 * 1024 * 1024 }, (err, stdout, stderr) => {
      fs.rm(file, { force: true }, () => undefined);
      if (err) {
        log("warn", "voice", "whisper failed", { err: String(err).slice(0, 200), stderr: String(stderr).slice(0, 300) });
        resolve(fail("voice_failed", "Could not turn the recording into text. Try again, a little closer to the mic."));
        return;
      }
      const text = stdout.replace(/\[[^\]]*\]/g, " ").replace(/\s+/g, " ").trim();   // drop [BLANK_AUDIO] and similar
      resolve(text ? ok(text) : fail("voice_empty", "Didn't catch anything. Try again."));
    });
  });
}
