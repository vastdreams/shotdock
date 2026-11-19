// Ownership (Rule 2): one live writer per session. ShotDock only writes to sessions it has claimed.

export type Writer = "shotdock" | "external";

export class Registry {
  private owners = new Map<string, Writer>();

  ownedByUs(id: string): boolean { return this.owners.get(id) === "shotdock"; }

  /** Claim a session for ShotDock. Fails if an external writer is live (the caller decides to fork instead). */
  claim(id: string, externalLive: boolean): { ok: true } | { ok: false; reason: string } {
    if (this.owners.get(id) === "shotdock") return { ok: true };
    if (externalLive) return { ok: false, reason: "The session is still active in another app. Fork it, or wait until it is idle." };
    this.owners.set(id, "shotdock");
    return { ok: true };
  }

  release(id: string): void { this.owners.delete(id); }

  list(): string[] { return [...this.owners.entries()].filter(([, w]) => w === "shotdock").map(([id]) => id); }
}
