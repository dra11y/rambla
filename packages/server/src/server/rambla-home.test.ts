import { mkdtempSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, expect, test, vi } from "vitest";

import { resolvePaseoHome } from "./paseo-home.js";

afterEach(() => {
  vi.restoreAllMocks();
});

describe("rambla home", () => {
  test("defaults to ~/.rambla when no home is configured", () => {
    const fakeHome = mkdtempSync(path.join(os.tmpdir(), "rambla-home-"));
    vi.spyOn(os, "homedir").mockReturnValue(fakeHome);
    try {
      expect(resolvePaseoHome({})).toBe(path.join(fakeHome, ".rambla"));
    } finally {
      rmSync(fakeHome, { recursive: true, force: true });
    }
  });
});
