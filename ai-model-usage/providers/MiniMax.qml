import QtQuick
import Quickshell

Item {
    id: root
    visible: false

    property string providerId: "minimax"
    property string providerName: "MiniMax"
    property string providerIcon: "ai"
    property bool enabled: false
    property bool ready: false
    property string usageStatusText: ""

    property real rateLimitPercent: -1
    property string rateLimitLabel: "5h window"
    property string rateLimitResetAt: ""
    property real secondaryRateLimitPercent: -1
    property string secondaryRateLimitLabel: "Weekly (7-day)"
    property string secondaryRateLimitResetAt: ""

    property int todayPrompts: 0
    property int todaySessions: 0
    property int todayTotalTokens: 0
    property var todayTokensByModel: ({})

    property var recentDays: []
    property int totalPrompts: 0
    property int totalSessions: 0
    property var modelUsage: ({})

    property string tierLabel: ""
    property string authHelpText: "Set MINIMAX_API_KEY or enter key in settings."
    property bool hasLocalStats: false

    property var providerSettings: ({})

    // ----- API key resolution -----

    property string apiKey: {
        // 1. Settings (explicit override)
        const settingsKey = providerSettings?.apiKey ?? "";
        if (settingsKey && settingsKey.trim() !== "")
            return settingsKey.trim();

        // 2. Direct MiniMax env vars
        const directKey = Quickshell.env("MINIMAX_TOKEN_PLAN_API_KEY")
                        ?? Quickshell.env("MINIMAX_CODING_PLAN_API_KEY")
                        ?? Quickshell.env("MINIMAX_API_KEY")
                        ?? "";
        if (directKey)
            return directKey;

        // 3. ANTHROPIC_AUTH_TOKEN proxied through minimax base URL
        const anthropicToken = Quickshell.env("ANTHROPIC_AUTH_TOKEN") ?? "";
        const anthropicBase = Quickshell.env("ANTHROPIC_BASE_URL") ?? "";
        if (anthropicToken && /minimax/i.test(anthropicBase))
            return anthropicToken;

        // 4. OPENAI_API_KEY proxied through minimax base URL
        const openaiKey = Quickshell.env("OPENAI_API_KEY") ?? "";
        const openaiBase = Quickshell.env("OPENAI_BASE_URL")
                        ?? Quickshell.env("OPENAI_API_BASE")
                        ?? "";
        if (openaiKey && /minimax/i.test(openaiBase))
            return openaiKey;

        return "";
    }

    // ----- Endpoint resolution -----

    property string apiBaseUrl: {
        // Custom override from settings takes priority
        const override = providerSettings?.apiBaseUrl ?? "";
        if (override && override.trim() !== "")
            return override.trim();

        // Region-based default
        const region = providerSettings?.region ?? "international";
        if (region === "china")
            return "https://api.minimaxi.com/v1";
        // "international" or any other value
        return "https://api.minimax.io/v1";
    }

    // ----- Refresh timer -----

    Timer {
        interval: 5 * 60 * 1000
        running: root.enabled && root.apiKey !== ""
        repeat: true
        onTriggered: root.fetchQuota()
    }

    onEnabledChanged: {
        if (!enabled)
            return;
        refresh();
    }

    onApiKeyChanged: {
        if (enabled)
            refresh();
    }

    // ----- Fetch -----

    function quotaUrl(path) {
        let base = String(root.apiBaseUrl ?? "").trim();
        while (base.endsWith("/"))
            base = base.slice(0, -1);
        return base.endsWith("/v1") ? (base + path) : (base + "/v1" + path);
    }

    function fetchQuota() {
        if (!root.apiKey) {
            root.usageStatusText = "Missing API key";
            root.rateLimitPercent = -1;
            root.secondaryRateLimitPercent = -1;
            root.ready = true;
            return;
        }

        root.ready = false;
        root.usageStatusText = "";
        root.fetchQuotaEndpoint([
            "/api/openplatform/coding_plan/remains",
            "/token_plan/remains"
        ], 0, "");
    }

    function fetchQuotaEndpoint(paths, index, lastError) {
        const url = root.quotaUrl(paths[index]);
        const xhr = new XMLHttpRequest();
        xhr.open("GET", url);
        xhr.setRequestHeader("Authorization", "Bearer " + root.apiKey);
        xhr.setRequestHeader("Content-Type", "application/json");

        xhr.onreadystatechange = function () {
            if (xhr.readyState !== XMLHttpRequest.DONE)
                return;

            if (xhr.status !== 200) {
                const err = "HTTP " + xhr.status;
                if (index + 1 < paths.length) {
                    root.fetchQuotaEndpoint(paths, index + 1, err);
                    return;
                }
                root.usageStatusText = err + " from " + url;
                root.rateLimitPercent = -1;
                root.secondaryRateLimitPercent = -1;
                root.ready = true;
                return;
            }

            try {
                const data = JSON.parse(xhr.responseText);

                const appStatus = data?.base_resp?.status_code
                               ?? data?.base_resp?.statuscode
                               ?? data?.status_code
                               ?? 0;
                if (appStatus !== 0 && appStatus !== "0" && appStatus !== "success" && appStatus !== 200) {
                    const msg = data?.base_resp?.status_msg
                             ?? data?.base_resp?.message
                             ?? data?.message
                             ?? ("status " + appStatus);
                    if (index + 1 < paths.length) {
                        root.fetchQuotaEndpoint(paths, index + 1, msg);
                        return;
                    }
                    root.usageStatusText = msg + " from " + url;
                    root.rateLimitPercent = -1;
                    root.secondaryRateLimitPercent = -1;
                    root.ready = true;
                    return;
                }

                if (root.parseQuotaResponse(data)) {
                    root.ready = true;
                    return;
                }

                if (index + 1 < paths.length) {
                    root.fetchQuotaEndpoint(paths, index + 1, "No quota data");
                    return;
                }

                root.usageStatusText = (lastError || "No quota data") + " from " + url;
                root.rateLimitPercent = -1;
                root.secondaryRateLimitPercent = -1;
                root.ready = true;
            } catch (e) {
                if (index + 1 < paths.length) {
                    root.fetchQuotaEndpoint(paths, index + 1, "Parse error");
                    return;
                }
                root.usageStatusText = "Parse error from " + url;
                root.rateLimitPercent = -1;
                root.secondaryRateLimitPercent = -1;
                root.ready = true;
                Logger.e("model-usage/minimax", "Failed to parse quota response:", e);
            }
        };

        xhr.send();
    }

    function parseFinite(value) {
        if (value === null || value === undefined || value === "")
            return NaN;
        const n = Number(value);
        return isFinite(n) ? n : NaN;
    }

    function firstFinite(values) {
        for (let i = 0; i < values.length; i++) {
            const n = root.parseFinite(values[i]);
            if (isFinite(n))
                return n;
        }
        return NaN;
    }

    function normalizeRecords(modelRemains) {
        if (Array.isArray(modelRemains))
            return modelRemains;
        if (!modelRemains || typeof modelRemains !== "object")
            return [];

        const result = [];
        for (const key in modelRemains) {
            const value = modelRemains[key];
            if (value && typeof value === "object") {
                value.model_name = value.model_name ?? value.model ?? key;
                result.push(value);
            }
        }
        return result;
    }

    function parseQuotaResponse(data) {
        const modelRemains = data?.model_remains
                          ?? data?.data?.model_remains
                          ?? data?.result?.model_remains;
        const records = root.normalizeRecords(modelRemains);

        if (records.length > 0)
            return root.parseModelRemains(records);

        const quota = data?.data ?? data?.result ?? data;
        return root.parseFlatQuota(quota);
    }

    function parseFlatQuota(quota) {
        if (!quota || typeof quota !== "object")
            return false;

        const total = root.firstFinite([
            quota.total_quota,
            quota.total,
            quota.quota,
            quota.total_intervals
        ]);
        let used = root.firstFinite([
            quota.used_quota,
            quota.used,
            quota.current_interval_usage_count
        ]);
        const remaining = root.firstFinite([
            quota.remaining_quota,
            quota.remaining,
            quota.tokens,
            quota.current_interval_remaining_count
        ]);

        if (!(total > 0))
            return false;
        if (!isFinite(used) && isFinite(remaining))
            used = total - remaining;
        if (!isFinite(used))
            return false;

        used = Math.min(total, Math.max(0, used));
        root.rateLimitPercent = Math.min(1, Math.max(0, used / total));
        root.rateLimitLabel = "5h window";
        root.rateLimitResetAt = quota.reset_timestamp ? new Date(Number(quota.reset_timestamp) * 1000).toISOString() : "";
        root.secondaryRateLimitPercent = -1;
        root.secondaryRateLimitLabel = "";
        root.secondaryRateLimitResetAt = "";
        return true;
    }

    function parseModelRemains(records) {
        if (records.length === 0)
            return false;

        // Prefer MiniMax-M* coding models; fall back to the row with the
        // tightest quota utilization.
        let codingRow = null;
        for (let i = 0; i < records.length; i++) {
            const rec = records[i];
            const id = rec?.model_name ?? rec?.model ?? "";
            if (/^MiniMax-M/i.test(id)) {
                codingRow = rec;
                break;
            }
            if (!codingRow) {
                codingRow = rec;
            } else {
                const prevTotal = root.firstFinite([codingRow?.total_intervals, codingRow?.total]);
                const prevUsed = root.firstFinite([codingRow?.current_interval_usage_count, codingRow?.used]);
                const prevRatio = prevTotal > 0 && isFinite(prevUsed) ? prevUsed / prevTotal : 0;

                const currTotal = root.firstFinite([rec?.total_intervals, rec?.total]);
                const currUsed = root.firstFinite([rec?.current_interval_usage_count, rec?.used]);
                const currRatio = currTotal > 0 && isFinite(currUsed) ? currUsed / currTotal : 0;

                if (currRatio > prevRatio)
                    codingRow = rec;
            }
        }

        if (!codingRow)
            return false;

        const total5h = root.firstFinite([codingRow?.total_intervals, codingRow?.total]);
        const used5h = root.firstFinite([codingRow?.current_interval_usage_count, codingRow?.used]);
        const totalWk = root.firstFinite([codingRow?.total_weekly_intervals, codingRow?.weekly_total]);
        const usedWk = root.firstFinite([codingRow?.current_weekly_usage_count, codingRow?.weekly_used]);

        let parsed = false;

        // 5-hour rolling window -> primary
        if (total5h > 0 && isFinite(used5h)) {
            root.rateLimitPercent = Math.min(1, Math.max(0, used5h / total5h));
            root.rateLimitLabel = "5h window";
            // No discrete reset time in this endpoint -- leave resetAt empty
            root.rateLimitResetAt = "";
            parsed = true;
        } else {
            root.rateLimitPercent = -1;
        }

        // Weekly window -> secondary (only if weekly fields are present)
        if (totalWk > 0 && isFinite(usedWk)) {
            root.secondaryRateLimitPercent = Math.min(1, Math.max(0, usedWk / totalWk));
            root.secondaryRateLimitLabel = "Weekly (7-day)";
            root.secondaryRateLimitResetAt = "";
            parsed = true;
        } else {
            root.secondaryRateLimitPercent = -1;
            root.secondaryRateLimitLabel = "";
            root.secondaryRateLimitResetAt = "";
        }

        return parsed;
    }

    function refresh() {
        fetchQuota();
    }

    function formatResetTime(isoTimestamp) {
        if (!isoTimestamp)
            return "";
        const reset = new Date(isoTimestamp);
        const now = new Date();
        const diffMs = reset.getTime() - now.getTime();
        if (diffMs <= 0)
            return "now";
        const hours = Math.floor(diffMs / 3600000);
        const mins  = Math.floor((diffMs % 3600000) / 60000);
        if (hours > 24)
            return Math.floor(hours / 24) + "d " + (hours % 24) + "h";
        if (hours > 0)
            return hours + "h " + mins + "m";
        return mins + "m";
    }
}