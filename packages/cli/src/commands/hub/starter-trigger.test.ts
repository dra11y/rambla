import { describe, expect, it } from "vitest";
import { availableStarterTriggerConnections } from "./starter-trigger.js";

describe("starter trigger connections", () => {
  it("returns only concrete connections that can back the generated trigger", () => {
    expect(
      availableStarterTriggerConnections(
        {
          github: [
            {
              slug: "github-getpaseo",
              accountLogin: "getpaseo",
              accountType: "Organization",
              repositories: ["getpaseo/paseo"],
            },
          ],
          slack: [{ slug: "paseo", teamName: "Rambla" }],
          discord: [{ slug: "paseo-discord", guildName: "Rambla Discord" }],
          daemons: [],
          linear: [],
        },
        "getpaseo/paseo",
      ),
    ).toEqual([
      {
        id: "github:getpaseo/paseo",
        label: "GitHub — getpaseo/paseo",
        provider: "github",
        filters: { connection: "github-getpaseo", repo: "getpaseo/paseo" },
      },
      {
        id: "slack:paseo",
        label: "Slack — Rambla",
        provider: "slack",
        filters: { connection: "paseo" },
      },
      {
        id: "discord:paseo-discord",
        label: "Discord — Rambla Discord",
        provider: "discord",
        filters: { connection: "paseo-discord" },
      },
    ]);
  });

  it("does not offer GitHub when the current repository is not connected", () => {
    expect(
      availableStarterTriggerConnections(
        {
          github: [
            {
              slug: "github-getpaseo",
              accountLogin: "getpaseo",
              accountType: "Organization",
              repositories: ["getpaseo/hub"],
            },
          ],
          slack: [],
          discord: [],
          daemons: [],
          linear: [],
        },
        "getpaseo/paseo",
      ),
    ).toEqual([]);
  });
});
