import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { Logger } from "pino";
import { z } from "zod";
import type { ProviderUsage, ProviderUsageWindow } from "../../../server/messages.js";
import type { ProviderApiFetch, ProviderUsageFetcher } from "../provider.js";
import { fetchProviderApi, unavailableUsage } from "../usage.js";

const QUOTA_LIMIT_URL = "https://api.z.ai/api/monitor/usage/quota/limit";

const QuotaLimitSchema = z
  .object({
    type: z.string(),
    unit: z.number().optional(),
    number: z.number().optional(),
    percentage: z.number().catch(0),
    currentValue: z.number().optional(),
    usage: z.number().optional(),
    nextResetTime: z.number().optional(),
  })
  .passthrough();

const QuotaResponseSchema = z.object({
  data: z
    .object({
      level: z.string().optional(),
      limits: z.array(QuotaLimitSchema).optional(),
    })
    .optional(),
});

/** Read the token written by `glm-acp-agent --setup`. */
function readStoredToken(): string | null {
  try {
    const path = join(
      process.env["XDG_CONFIG_HOME"] && process.env["XDG_CONFIG_HOME"].length > 0
        ? process.env["XDG_CONFIG_HOME"]
        : join(homedir(), ".config"),
      "glm-acp-agent",
      "credentials.json",
    );
    if (!existsSync(path)) return null;
    const parsed = JSON.parse(readFileSync(path, "utf-8")) as { z_ai_api_key?: unknown };
    return typeof parsed.z_ai_api_key === "string" && parsed.z_ai_api_key.length > 0
      ? parsed.z_ai_api_key
      : null;
  } catch {
    return null;
  }
}

/** Map a quota limit entry to a display window; null for unknown types. */
function windowFor(limit: z.infer<typeof QuotaLimitSchema>): ProviderUsageWindow | null {
  let id: string;
  let label: string;
  if (limit.type === "TOKENS_LIMIT" || limit.type === "CREDIT_LIMIT") {
    if (limit.unit === 3 && limit.number === 5) {
      id = "five_hour";
      label = "5-hour";
    } else if (limit.unit === 6 && limit.number === 1) {
      id = "weekly";
      label = "Weekly";
    } else {
      id = "tokens";
      label = "Token usage";
    }
  } else if (limit.type === "TIME_LIMIT") {
    id = "mcp_monthly";
    label = "MCP (1 month)";
  } else {
    return null;
  }
  // The API floors `percentage` (214/2000 ships as 10%); compute and round up.
  const usedPct =
    typeof limit.currentValue === "number" && typeof limit.usage === "number" && limit.usage > 0
      ? Math.ceil((limit.currentValue / limit.usage) * 100)
      : limit.percentage;
  return {
    id,
    label,
    usedPct,
    ...(limit.nextResetTime && limit.nextResetTime > 0
      ? { resetsAt: new Date(limit.nextResetTime).toISOString() }
      : {}),
  };
}

interface ZaiQuotaProviderOptions {
  logger: Logger;
  fetch?: ProviderApiFetch;
}

export class ZaiQuotaProvider implements ProviderUsageFetcher {
  readonly providerId = "glm-acp-agent";
  readonly displayName = "Z.ai";

  private readonly logger: Logger;
  private readonly fetchApi: ProviderApiFetch;

  constructor(options: ZaiQuotaProviderOptions) {
    this.logger = options.logger;
    this.fetchApi = options.fetch ?? fetch;
  }

  async fetchUsage(): Promise<ProviderUsage> {
    const token = process.env["ZAI_API_KEY"] || process.env["GLM_API_KEY"] || readStoredToken();
    if (!token) return unavailableUsage(this);

    // The monitor API takes the raw token — no "Bearer" prefix.
    const res = await fetchProviderApi(this.fetchApi, QUOTA_LIMIT_URL, {
      headers: {
        Authorization: token,
        Accept: "application/json",
        "Accept-Language": "en-US,en",
      },
    });

    if (!res.ok) {
      this.logger.debug({ status: res.status }, "Z.ai usage fetch failed");
      return unavailableUsage(this);
    }

    const resp = QuotaResponseSchema.parse(await res.json());
    const level = resp.data?.level;
    const windows: ProviderUsageWindow[] = [];
    for (const limit of resp.data?.limits ?? []) {
      const window = windowFor(limit);
      if (window) windows.push(window);
    }

    return {
      providerId: this.providerId,
      displayName: this.displayName,
      status: "available",
      planLabel:
        typeof level === "string" && level.length > 0
          ? level.charAt(0).toUpperCase() + level.slice(1)
          : null,
      windows,
      balances: [],
      details: [],
      error: null,
    };
  }
}
