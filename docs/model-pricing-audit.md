# Model pricing audit — 2025 through 2026

Verified on: **2026-09-23**. Currency: USD.

## Scope and coverage

The target inventory is public OpenAI/Codex, Anthropic/Claude, and Google/Gemini model IDs released since 2025-01-01. A few older still-documented audio and embedding endpoints are retained as supplemental references. This is a source-backed coverage expansion, **not a claim that every historical price or every experimental endpoint has been recovered**.

- 48 OpenAI, 18 Claude, and 16 Gemini model entries have automatic text-token estimation rules; exact aliases and dated snapshots are additional identifiers, not additional models.
- 60 entries have reference prices only. These rates never enter the conversation cost evaluator.
- 50 inventoried entries remain explicitly unverified. An empty price list is not a zero-dollar price.
- Rules are bundled and offline. Neither importing logs nor opening the catalog downloads a remote price list.

Use **Settings → Model Price Catalog** to search IDs and aliases, inspect rule dates, and open source links.

## Estimation contract

Automatic estimates represent list-price **API-equivalent token value**, not subscription charges or an actual invoice. Claude and Gemini automatic estimates use standard global text rates. Audio input, special service modes, regional premiums, negotiated prices, grounding, cache storage, and other tool charges are not included. Missing usage dimensions cannot be reconstructed from a total token count.

OpenAI special service tiers are accepted only when a rule exists for the event timestamp. Newly added current Batch/Flex/Fast rows start on the verification date where their earlier start dates have not been verified. Older existing tier timelines remain intact. A cached-token count with no published cache rate is unpriced, not free.

GPT-6 Sol and Luna use the official September 22, 2026 release date, standard short/long-context rates, and published Batch/Flex/Fast multipliers. Claude Opus 5.5 uses its September 22 release date, including its distinct cache-read price.

Image/audio/video/embedding references preserve their own units (million tokens, million characters, seconds, minutes, images, songs). Approximate per-minute figures are estimates, not conversions used for conversation totals. Imagen rows sourced from **Google Cloud Agent Platform** are labeled accordingly and must not be treated as Gemini Developer API rates. Other reference prices describe the fetched source's current list prices; no historical range is asserted.

## Historical boundaries and known gaps

- API release dates are distinct from snapshot dates: Claude Sonnet 3.7's `20250219` snapshot was publicly released on February 24; Opus 4.5's `20251101` snapshot on November 24; Haiku 4.5's `20251001` snapshot on October 15.
- OpenAI o3's current rates are applied from its documented 2025-06-10 reduction. Earlier o3 list prices are not backfilled without a recovered primary price source.
- `chat-latest` and the newly added Cyber references/rules are not backdated from today's rates.
- Gemini 2.5 caching historically had a 75% discount, while today's table lists a 90% discount. The exact transition has not been established from the checked primary sources. Before 2026-09-07, a Gemini 2.5 record containing cache hits remains unpriced; uncached text/output can use the recorded base rates. This deliberately avoids inventing a transition date.
- Gemini 2.0 Flash caching starts no earlier than the documented 2025-04-16 availability. Flash-Lite has no published cache price.
- Gemini 3.8 Flash rules start on 2026-09-02, not the older 3.7 promotion start. Existing 3.6/3.7 promotional periods remain bounded; the announced 2027 prices are separate rules.
- Claude Opus 4.6 and Sonnet 4.6 move from long-context premium pricing to standard 1M-context pricing on 2026-03-13. Legacy Sonnet 4/4.5 1M context is not estimated after its 2026-04-30 retirement.
- Unknown suffixes, private variants, and arbitrary future snapshot dates are not aliases. A word such as `sol` appearing inside a private model name no longer makes it a priced Sol model.
- Retired preview endpoints, free experimental access, and moving `latest` aliases require model-specific evidence. Missing prices do not imply that the endpoint is free, still available, or equivalent to its successor.

## Sources

- [OpenAI current prices](https://developers.openai.com/api/docs/pricing) and its markdown representation expose full tables, including rows collapsed in the HTML page.
- [OpenAI API changelog](https://developers.openai.com/api/docs/changelog), [GPT-6 Sol](https://developers.openai.com/api/docs/models/gpt-6-sol), [GPT-6 Luna](https://developers.openai.com/api/docs/models/gpt-6-luna), and [current prices](https://developers.openai.com/api/docs/pricing) establish release dates and model rates.
- [Claude prices](https://platform.claude.com/docs/en/about-claude/pricing) and [release notes](https://platform.claude.com/docs/en/release-notes/overview) establish base/cache rates and lifecycle changes.
- [Claude Opus 5.5 launch](https://www.anthropic.com/claude-opus-5-5) establishes its release date, API model ID, and standard/cache-read prices.
- [Claude Opus 4.6 launch](https://www.anthropic.com/news/claude-opus-4-6) documents its original long-context premium.
- [Historical Claude long-context documentation](https://docs.anthropic.com/en/docs/about-claude/pricing?4810b549_page=3&73cdfb14_page=2&939688b5_page=1&e768fcd2_page=2) documents the Sonnet input/output premiums and stacking with cache multipliers. The canonical page changes over time.
- [Project Glasswing](https://www.anthropic.com/glasswing) documents Mythos Preview participant list pricing; it is not general public availability.
- [Gemini Developer API prices](https://ai.google.dev/gemini-api/docs/pricing), [release notes](https://ai.google.dev/gemini-api/docs/changelog), and [deprecations](https://ai.google.dev/gemini-api/docs/deprecations) establish model inventory and current prices.
- [Gemini implicit caching launch](https://developers.googleblog.com/en/gemini-2-5-models-now-support-implicit-caching/) establishes the earlier 75% discount; it does not establish the later price-change date.
- [Google Cloud Agent Platform prices](https://cloud.google.com/gemini-enterprise-agent-platform/generative-ai/pricing) supply the separately labeled Imagen reference rates.

## Reference-price inventory

These are **reference only**, not conversation billing rules. Values are copied as factual rates, not estimated from a successor model. No unknown rates have been filled with zero.

| Provider | Model | Category | Rates | Evidence |
| --- | --- | --- | --- | --- |
| Anthropic | `claude-mythos-preview` | text | input_text: $25/millionTokens; output_text: $125/millionTokens | [Source](https://www.anthropic.com/glasswing) |
| Google | `gemini-2.5-flash-image` | image | input_text: $0.3/millionTokens; input_image: $0.3/millionTokens; output_text: $2.5/millionTokens; output_image: $30/millionTokens | [Source](https://ai.google.dev/gemini-api/docs/pricing) |
| Google | `gemini-2.5-flash-native-audio-preview-12-2025` | audio | input_text: $0.5/millionTokens; output_text: $2/millionTokens; input_audio: $3/millionTokens; output_audio: $12/millionTokens | [Source](https://ai.google.dev/gemini-api/docs/pricing) |
| Google | `gemini-2.5-flash-preview-tts` | audio | input_text: $0.5/millionTokens; output_audio: $10/millionTokens | [Source](https://ai.google.dev/gemini-api/docs/pricing) |
| Google | `gemini-2.5-pro-preview-tts` | audio | input_text: $1/millionTokens; output_audio: $20/millionTokens | [Source](https://ai.google.dev/gemini-api/docs/pricing) |
| Google | `gemini-3-pro-image` | image | input_text: $2/millionTokens; input_image: $2/millionTokens; output_text: $12/millionTokens; output_image: $120/millionTokens | [Source](https://ai.google.dev/gemini-api/docs/pricing) |
| Google | `gemini-3.1-flash-image` | image | input_text: $0.5/millionTokens; input_image: $0.5/millionTokens; output_text: $3/millionTokens; output_image: $60/millionTokens | [Source](https://ai.google.dev/gemini-api/docs/pricing) |
| Google | `gemini-3.1-flash-lite-image` | image | input_text: $0.25/millionTokens; input_image: $0.25/millionTokens; output_text: $1.5/millionTokens; output_image: $30/millionTokens | [Source](https://ai.google.dev/gemini-api/docs/pricing) |
| Google | `gemini-3.1-flash-live-preview` | audio | input_text: $0.75/millionTokens; output_text: $4.5/millionTokens; input_audio: $3/millionTokens; output_audio: $12/millionTokens; input_image: $1/millionTokens | [Source](https://ai.google.dev/gemini-api/docs/pricing) |
| Google | `gemini-3.1-flash-tts-preview` | audio | input_text: $1/millionTokens; output_audio: $20/millionTokens | [Source](https://ai.google.dev/gemini-api/docs/pricing) |
| Google | `gemini-3.5-live-translate-preview` | audio | input_audio: $3.5/millionTokens; output_audio: $21/millionTokens | [Source](https://ai.google.dev/gemini-api/docs/pricing) |
| Google | `gemini-3.5-transcribe` | audio | output_text: $12/millionTokens; input_audio: $2/millionTokens | [Source](https://ai.google.dev/gemini-api/docs/pricing) |
| Google | `gemini-3.5-transcribe-live` | audio | output_text: $21/millionTokens; input_audio: $3.5/millionTokens | [Source](https://ai.google.dev/gemini-api/docs/pricing) |
| Google | `gemini-embedding-001` | embedding | input_text: $0.15/millionTokens | [Source](https://ai.google.dev/gemini-api/docs/pricing) |
| Google | `gemini-embedding-2` | embedding | input_text: $0.2/millionTokens; input_image: $0.45/millionTokens; input_audio: $6.5/millionTokens; input_video: $12/millionTokens | [Source](https://ai.google.dev/gemini-api/docs/pricing) |
| Google | `gemini-omni-1.1-flash` | video | input: $1.5/millionTokens; output_text: $9/millionTokens; output_video: $17.5/millionTokens (720p) | [Source](https://ai.google.dev/gemini-api/docs/pricing) |
| Google | `gemini-omni-flash-preview` | video | input: $1.5/millionTokens; output_text: $9/millionTokens; output_video: $17.5/millionTokens (720p) | [Source](https://ai.google.dev/gemini-api/docs/pricing) |
| Google | `imagen-3.0-generate-002` | image | output_image: $0.04/image (Agent Platform) | [Source](https://cloud.google.com/gemini-enterprise-agent-platform/generative-ai/pricing) |
| Google | `imagen-4.0-fast-generate-001` | image | output_image: $0.02/image (Agent Platform) | [Source](https://cloud.google.com/gemini-enterprise-agent-platform/generative-ai/pricing) |
| Google | `imagen-4.0-generate-001` | image | output_image: $0.04/image (Agent Platform) | [Source](https://cloud.google.com/gemini-enterprise-agent-platform/generative-ai/pricing) |
| Google | `imagen-4.0-ultra-generate-001` | image | output_image: $0.06/image (Agent Platform) | [Source](https://cloud.google.com/gemini-enterprise-agent-platform/generative-ai/pricing) |
| Google | `lyria-3-clip-preview` | audio | output_audio: $0.04/song | [Source](https://ai.google.dev/gemini-api/docs/pricing) |
| Google | `lyria-3-pro-preview` | audio | output_audio: $0.08/song | [Source](https://ai.google.dev/gemini-api/docs/pricing) |
| Google | `lyria-3.5` | audio | output_audio: $0.08/song | [Source](https://ai.google.dev/gemini-api/docs/pricing) |
| Google | `veo-3.1-fast-generate-preview` | video | output_video: $0.1/second (720p); output_video: $0.12/second (1080p); output_video: $0.3/second (4K) | [Source](https://ai.google.dev/gemini-api/docs/pricing) |
| Google | `veo-3.1-generate-preview` | video | output_video: $0.4/second (720p / 1080p); output_video: $0.6/second (4K) | [Source](https://ai.google.dev/gemini-api/docs/pricing) |
| Google | `veo-3.1-lite-generate-preview` | video | output_video: $0.05/second (720p); output_video: $0.08/second (1080p) | [Source](https://ai.google.dev/gemini-api/docs/pricing) |
| OpenAI | `chatgpt-image-latest` | image | input_image: $8.00/millionTokens; cached_image: $2.00/millionTokens; output_image: $32.00/millionTokens; input_text: $5.00/millionTokens; cached_text: $1.25/millionTokens; output_text: $10.00/millionTokens | [Source](https://developers.openai.com/api/docs/pricing) |
| OpenAI | `gpt-4o-audio-preview` | audio | input_text: $2.5/millionTokens; output_text: $10/millionTokens; input_audio: $40/millionTokens; output_audio: $80/millionTokens | [Source](https://developers.openai.com/api/docs/models/gpt-4o-audio-preview) |
| OpenAI | `gpt-4o-mini-audio-preview` | audio | input_text: $0.15/millionTokens; output_text: $0.6/millionTokens; input_audio: $10/millionTokens; output_audio: $20/millionTokens | [Source](https://developers.openai.com/api/docs/models/gpt-4o-mini-audio-preview) |
| OpenAI | `gpt-4o-mini-realtime-preview` | audio | input_text: $0.6/millionTokens; cached_text: $0.3/millionTokens; output_text: $2.4/millionTokens; input_audio: $10/millionTokens; cached_audio: $0.3/millionTokens; output_audio: $20/millionTokens | [Source](https://developers.openai.com/api/docs/models/gpt-4o-mini-realtime-preview) |
| OpenAI | `gpt-4o-mini-transcribe` | audio | input_text: $1.25/millionTokens; output_text: $5.00/millionTokens; estimate: $0.003/minute | [Source](https://developers.openai.com/api/docs/pricing) |
| OpenAI | `gpt-4o-mini-tts` | audio | output_audio: $12.00/millionTokens; input_text: $0.60/millionTokens | [Source](https://developers.openai.com/api/docs/pricing) |
| OpenAI | `gpt-4o-realtime-preview` | audio | input_text: $5/millionTokens; cached_text: $2.5/millionTokens; output_text: $20/millionTokens; input_audio: $40/millionTokens; cached_audio: $2.5/millionTokens; output_audio: $80/millionTokens | [Source](https://developers.openai.com/api/docs/models/gpt-4o-realtime-preview) |
| OpenAI | `gpt-4o-transcribe` | audio | input_text: $2.50/millionTokens; output_text: $10.00/millionTokens; estimate: $0.006/minute | [Source](https://developers.openai.com/api/docs/pricing) |
| OpenAI | `gpt-4o-transcribe-diarize` | audio | input_text: $2.50/millionTokens; output_text: $10.00/millionTokens; estimate: $0.006/minute | [Source](https://developers.openai.com/api/docs/pricing) |
| OpenAI | `gpt-audio` | audio | input_audio: $32.00/millionTokens; output_audio: $64.00/millionTokens; input_text: $2.50/millionTokens; output_text: $10.00/millionTokens | [Source](https://developers.openai.com/api/docs/pricing) |
| OpenAI | `gpt-audio-1.5` | audio | input_audio: $32.00/millionTokens; output_audio: $64.00/millionTokens; input_text: $2.50/millionTokens; output_text: $10.00/millionTokens | [Source](https://developers.openai.com/api/docs/pricing) |
| OpenAI | `gpt-audio-mini` | audio | input_audio: $10.00/millionTokens; output_audio: $20.00/millionTokens; input_text: $0.60/millionTokens; output_text: $2.40/millionTokens | [Source](https://developers.openai.com/api/docs/pricing) |
| OpenAI | `gpt-image-1` | image | input_image: $10.00/millionTokens; cached_image: $2.50/millionTokens; output_image: $40.00/millionTokens; input_text: $5.00/millionTokens; cached_text: $1.25/millionTokens | [Source](https://developers.openai.com/api/docs/pricing) |
| OpenAI | `gpt-image-1-mini` | image | input_image: $2.50/millionTokens; cached_image: $0.25/millionTokens; output_image: $8.00/millionTokens; input_text: $2.00/millionTokens; cached_text: $0.20/millionTokens | [Source](https://developers.openai.com/api/docs/pricing) |
| OpenAI | `gpt-image-1.5` | image | input_image: $8.00/millionTokens; cached_image: $2.00/millionTokens; output_image: $32.00/millionTokens; input_text: $5.00/millionTokens; cached_text: $1.25/millionTokens; output_text: $10.00/millionTokens | [Source](https://developers.openai.com/api/docs/pricing) |
| OpenAI | `gpt-image-2` | image | input_image: $8.00/millionTokens; cached_image: $2.00/millionTokens; output_image: $30.00/millionTokens; input_text: $5.00/millionTokens; cached_text: $1.25/millionTokens | [Source](https://developers.openai.com/api/docs/pricing) |
| OpenAI | `gpt-live-transcribe` | audio | estimate: $0.017/minute | [Source](https://developers.openai.com/api/docs/pricing) |
| OpenAI | `gpt-realtime` | audio | input_audio: $32.00/millionTokens; cached_audio: $0.40/millionTokens; output_audio: $64.00/millionTokens; input_text: $4.00/millionTokens; cached_text: $0.40/millionTokens; output_text: $16.00/millionTokens; input_image: $5.00/millionTokens; cached_image: $0.50/millionTokens | [Source](https://developers.openai.com/api/docs/pricing) |
| OpenAI | `gpt-realtime-1.5` | audio | input_audio: $32.00/millionTokens; cached_audio: $0.40/millionTokens; output_audio: $64.00/millionTokens; input_text: $4.00/millionTokens; cached_text: $0.40/millionTokens; output_text: $16.00/millionTokens; input_image: $5.00/millionTokens; cached_image: $0.50/millionTokens | [Source](https://developers.openai.com/api/docs/pricing) |
| OpenAI | `gpt-realtime-2` | audio | input_audio: $32.00/millionTokens; cached_audio: $0.40/millionTokens; output_audio: $64.00/millionTokens; input_text: $4.00/millionTokens; cached_text: $0.40/millionTokens; output_text: $24.00/millionTokens; input_image: $5.00/millionTokens; cached_image: $0.50/millionTokens | [Source](https://developers.openai.com/api/docs/pricing) |
| OpenAI | `gpt-realtime-2.1` | audio | input_audio: $32.00/millionTokens; cached_audio: $0.40/millionTokens; output_audio: $64.00/millionTokens; input_text: $4.00/millionTokens; cached_text: $0.40/millionTokens; output_text: $24.00/millionTokens; input_image: $5.00/millionTokens; cached_image: $0.50/millionTokens | [Source](https://developers.openai.com/api/docs/pricing) |
| OpenAI | `gpt-realtime-2.1-mini` | audio | input_audio: $10.00/millionTokens; cached_audio: $0.30/millionTokens; output_audio: $20.00/millionTokens; input_text: $0.60/millionTokens; cached_text: $0.06/millionTokens; output_text: $2.40/millionTokens; input_image: $0.80/millionTokens; cached_image: $0.08/millionTokens | [Source](https://developers.openai.com/api/docs/pricing) |
| OpenAI | `gpt-realtime-mini` | audio | input_audio: $10.00/millionTokens; cached_audio: $0.30/millionTokens; output_audio: $20.00/millionTokens; input_text: $0.60/millionTokens; cached_text: $0.06/millionTokens; output_text: $2.40/millionTokens; input_image: $0.80/millionTokens; cached_image: $0.08/millionTokens | [Source](https://developers.openai.com/api/docs/pricing) |
| OpenAI | `gpt-realtime-translate` | audio | estimate: $0.034/minute | [Source](https://developers.openai.com/api/docs/pricing) |
| OpenAI | `gpt-realtime-whisper` | audio | estimate: $0.017/minute | [Source](https://developers.openai.com/api/docs/pricing) |
| OpenAI | `gpt-transcribe` | audio | estimate: $0.0045/minute | [Source](https://developers.openai.com/api/docs/pricing) |
| OpenAI | `sora-2` | video | output_video: $0.10/second (720p) | [Source](https://developers.openai.com/api/docs/pricing) |
| OpenAI | `sora-2-pro` | video | output_video: $0.30/second (720p); output_video: $0.50/second (1024p); output_video: $0.70/second (1080p) | [Source](https://developers.openai.com/api/docs/pricing) |
| OpenAI | `text-embedding-3-large` | embedding | input_text: $0.13/millionTokens | [Source](https://developers.openai.com/api/docs/pricing) |
| OpenAI | `text-embedding-3-small` | embedding | input_text: $0.02/millionTokens | [Source](https://developers.openai.com/api/docs/pricing) |
| OpenAI | `text-embedding-ada-002` | embedding | input_text: $0.10/millionTokens | [Source](https://developers.openai.com/api/docs/pricing) |
| OpenAI | `tts-1` | audio | input_text: $15.00/millionCharacters | [Source](https://developers.openai.com/api/docs/pricing) |
| OpenAI | `tts-1-hd` | audio | input_text: $30.00/millionCharacters | [Source](https://developers.openai.com/api/docs/pricing) |

## Unverified inventory

These identifiers were found in official model/lifecycle inventories or are explicitly encountered Codex identifiers, but a suitable applicable price was not established. They remain visible rather than receiving an inferred price. Further work requires matching primary historical price publications, including applicable units and dates.

| Provider | Model | Evidence to continue checking |
| --- | --- | --- |
| Google | `gemini-2.0-flash-exp` | [Inventory source](https://ai.google.dev/gemini-api/docs/changelog) |
| Google | `gemini-2.0-flash-exp-image-generation` | [Inventory source](https://ai.google.dev/gemini-api/docs/changelog) |
| Google | `gemini-2.0-flash-lite-preview` | [Inventory source](https://ai.google.dev/gemini-api/docs/changelog) |
| Google | `gemini-2.0-flash-lite-preview-02-05` | [Inventory source](https://ai.google.dev/gemini-api/docs/changelog) |
| Google | `gemini-2.0-flash-live-001` | [Inventory source](https://ai.google.dev/gemini-api/docs/changelog) |
| Google | `gemini-2.0-flash-preview-image-generation` | [Inventory source](https://ai.google.dev/gemini-api/docs/changelog) |
| Google | `gemini-2.0-flash-thinking-exp` | [Inventory source](https://ai.google.dev/gemini-api/docs/changelog) |
| Google | `gemini-2.0-flash-thinking-exp-01-21` | [Inventory source](https://ai.google.dev/gemini-api/docs/changelog) |
| Google | `gemini-2.0-flash-thinking-exp-1219` | [Inventory source](https://ai.google.dev/gemini-api/docs/changelog) |
| Google | `gemini-2.0-pro-exp` | [Inventory source](https://ai.google.dev/gemini-api/docs/changelog) |
| Google | `gemini-2.0-pro-exp-02-05` | [Inventory source](https://ai.google.dev/gemini-api/docs/changelog) |
| Google | `gemini-2.5-flash-exp-native-audio-thinking-dialog` | [Inventory source](https://ai.google.dev/gemini-api/docs/changelog) |
| Google | `gemini-2.5-flash-image-preview` | [Inventory source](https://ai.google.dev/gemini-api/docs/changelog) |
| Google | `gemini-2.5-flash-lite-preview-06-17` | [Inventory source](https://ai.google.dev/gemini-api/docs/changelog) |
| Google | `gemini-2.5-flash-lite-preview-09-2025` | [Inventory source](https://ai.google.dev/gemini-api/docs/changelog) |
| Google | `gemini-2.5-flash-native-audio-preview-09-2025` | [Inventory source](https://ai.google.dev/gemini-api/docs/changelog) |
| Google | `gemini-2.5-flash-preview-04-17` | [Inventory source](https://ai.google.dev/gemini-api/docs/changelog) |
| Google | `gemini-2.5-flash-preview-05-20` | [Inventory source](https://ai.google.dev/gemini-api/docs/changelog) |
| Google | `gemini-2.5-flash-preview-09-2025` | [Inventory source](https://ai.google.dev/gemini-api/docs/changelog) |
| Google | `gemini-2.5-flash-preview-native-audio-dialog` | [Inventory source](https://ai.google.dev/gemini-api/docs/changelog) |
| Google | `gemini-2.5-pro-exp-03-25` | [Inventory source](https://ai.google.dev/gemini-api/docs/changelog) |
| Google | `gemini-2.5-pro-preview-03-25` | [Inventory source](https://ai.google.dev/gemini-api/docs/changelog) |
| Google | `gemini-2.5-pro-preview-05-06` | [Inventory source](https://ai.google.dev/gemini-api/docs/changelog) |
| Google | `gemini-2.5-pro-preview-06-05` | [Inventory source](https://ai.google.dev/gemini-api/docs/changelog) |
| Google | `gemini-3-pro-image-preview` | [Inventory source](https://ai.google.dev/gemini-api/docs/changelog) |
| Google | `gemini-3-pro-preview` | [Inventory source](https://ai.google.dev/gemini-api/docs/changelog) |
| Google | `gemini-3.1-flash-image-preview` | [Inventory source](https://ai.google.dev/gemini-api/docs/changelog) |
| Google | `gemini-3.1-flash-lite-preview` | [Inventory source](https://ai.google.dev/gemini-api/docs/changelog) |
| Google | `gemini-embedding-2-preview` | [Inventory source](https://ai.google.dev/gemini-api/docs/changelog) |
| Google | `gemini-embedding-exp` | [Inventory source](https://ai.google.dev/gemini-api/docs/changelog) |
| Google | `gemini-embedding-exp-03-07` | [Inventory source](https://ai.google.dev/gemini-api/docs/changelog) |
| Google | `gemini-flash-latest` | [Inventory source](https://ai.google.dev/gemini-api/docs/changelog) |
| Google | `gemini-live-2.5-flash-preview` | [Inventory source](https://ai.google.dev/gemini-api/docs/changelog) |
| Google | `gemini-pro-latest` | [Inventory source](https://ai.google.dev/gemini-api/docs/changelog) |
| Google | `gemini-robotics-er-1.5-preview` | [Inventory source](https://ai.google.dev/gemini-api/docs/changelog) |
| Google | `gemini-robotics-er-2-streaming-preview` | [Inventory source](https://ai.google.dev/gemini-api/docs/changelog) |
| Google | `imagen-4.0-generate-preview-06-06` | [Inventory source](https://ai.google.dev/gemini-api/docs/changelog) |
| Google | `imagen-4.0-ultra-generate-preview-06-06` | [Inventory source](https://ai.google.dev/gemini-api/docs/changelog) |
| Google | `lyria-realtime-exp` | [Inventory source](https://ai.google.dev/gemini-api/docs/changelog) |
| Google | `veo-2.0-generate-001` | [Inventory source](https://ai.google.dev/gemini-api/docs/changelog) |
| Google | `veo-3.0-fast-generate-001` | [Inventory source](https://ai.google.dev/gemini-api/docs/changelog) |
| Google | `veo-3.0-fast-generate-preview` | [Inventory source](https://ai.google.dev/gemini-api/docs/changelog) |
| Google | `veo-3.0-generate-001` | [Inventory source](https://ai.google.dev/gemini-api/docs/changelog) |
| Google | `veo-3.0-generate-preview` | [Inventory source](https://ai.google.dev/gemini-api/docs/changelog) |
| OpenAI | `gpt-5.3-codex-spark` | [Inventory source](https://developers.openai.com/api/docs/models) |
| OpenAI | `gpt-5.4-cyber` | [Inventory source](https://developers.openai.com/api/docs/models) |
| OpenAI | `gpt-daybreak-blue-latest` | [Inventory source](https://developers.openai.com/api/docs/models) |
| OpenAI | `gpt-daybreak-red-latest` | [Inventory source](https://developers.openai.com/api/docs/models) |
| OpenAI | `gpt-oss-120b` | [Inventory source](https://developers.openai.com/api/docs/models) |
| OpenAI | `gpt-oss-20b` | [Inventory source](https://developers.openai.com/api/docs/models) |

## Validation and upgrade behavior

Tests cover model/alias/rule uniqueness, non-overlapping periods, official rate examples, dated model boundaries, long context, absent cache prices, precision, reference-unit isolation, and ledger repricing without rereading unchanged logs. Parser version 9 performs a one-time bounded rebuild to correct previously over-broad model aliases; ordinary subsequent scans remain incremental. Missing source files keep their existing derived history for recovery.

This catalog must not be advertised as a fully verified historical billing database until the unverified inventory and date-specific gaps above have been resolved.
