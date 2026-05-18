# Noctalia AI Model Usage Plugin

Plugin for [Noctalia Shell](https://github.com/noctalia-dev/noctalia-shell) showing AI coding assistant usage stats.

## Install

1. Open **Settings → Plugins → Sources**
2. Click **Add custom repository**
3. Add `https://github.com/BestSithInEU/ai-model-usage-repo`
4. Sync and install **AI Model Usage**

## Supported Providers

- **Claude** — local auth files
- **Codex** — local history/session files (5h + weekly rate limits)
- **Copilot** — GitHub auth
- **OpenRouter** — API key
- **Zen** — OpenCode Zen API
- **MiniMax** — coding/token plan endpoint (5h + weekly quotas)

## MiniMax Setup

Set `MINIMAX_API_KEY` env var, or enter your key in the plugin settings. Choose region (International/China) in settings.