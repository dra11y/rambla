import { describe, expect, it } from "vitest";
import { resolveCliInstallSourcePath } from "./path";

describe("cli-install-path", () => {
  it("uses the bundled shim for packaged macOS installs", () => {
    expect(
      resolveCliInstallSourcePath({
        platform: "darwin",
        isPackaged: true,
        executablePath: "/Applications/Rambla.app/Contents/MacOS/Rambla",
        shimPath: "/Applications/Rambla.app/Contents/Resources/bin/rambla",
      }),
    ).toBe("/Applications/Rambla.app/Contents/Resources/bin/rambla");
  });

  it("prefers the original AppImage path on linux", () => {
    expect(
      resolveCliInstallSourcePath({
        platform: "linux",
        isPackaged: true,
        executablePath: "/tmp/.mount_paseo123/paseo",
        shimPath: "/tmp/.mount_paseo123/resources/bin/rambla",
        appImagePath: "/home/user/Applications/Rambla.AppImage",
      }),
    ).toBe("/home/user/Applications/Rambla.AppImage");
  });

  it("uses the bundled shim for packaged linux installs outside an AppImage", () => {
    expect(
      resolveCliInstallSourcePath({
        platform: "linux",
        isPackaged: true,
        executablePath: "/opt/Rambla/Rambla",
        shimPath: "/opt/Rambla/resources/bin/rambla",
      }),
    ).toBe("/opt/Rambla/resources/bin/rambla");
  });

  it("falls back to the shim on windows and in development", () => {
    expect(
      resolveCliInstallSourcePath({
        platform: "win32",
        isPackaged: true,
        executablePath: "C:\\Users\\user\\AppData\\Local\\Programs\\Rambla\\Rambla.exe",
        shimPath: "C:\\Users\\user\\AppData\\Local\\Programs\\Rambla\\resources\\bin\\paseo.cmd",
      }),
    ).toBe("C:\\Users\\user\\AppData\\Local\\Programs\\Rambla\\resources\\bin\\paseo.cmd");

    expect(
      resolveCliInstallSourcePath({
        platform: "linux",
        isPackaged: false,
        executablePath: "/opt/Rambla/paseo",
        shimPath: "/opt/Rambla/resources/bin/rambla",
      }),
    ).toBe("/opt/Rambla/resources/bin/rambla");
  });
});
