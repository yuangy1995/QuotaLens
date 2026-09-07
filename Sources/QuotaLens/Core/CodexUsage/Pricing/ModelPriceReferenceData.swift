// 核对日期：2026-09-07。仅供参考；缺失价格为空数组，不用零代替未知。
import Foundation

extension ModelPriceReferenceCatalog {
    static let referenceJSON = #"""
[
  {
    "provider": "OpenAI",
    "modelID": "gpt-realtime-2.1",
    "category": "audio",
    "rates": [
      {
        "metric": "input_audio",
        "usd": "32.00",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "cached_audio",
        "usd": "0.40",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "output_audio",
        "usd": "64.00",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "input_text",
        "usd": "4.00",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "cached_text",
        "usd": "0.40",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "output_text",
        "usd": "24.00",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "input_image",
        "usd": "5.00",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "cached_image",
        "usd": "0.50",
        "unit": "millionTokens",
        "condition": ""
      }
    ],
    "sourceURL": "https://developers.openai.com/api/docs/pricing"
  },
  {
    "provider": "OpenAI",
    "modelID": "gpt-realtime-2.1-mini",
    "category": "audio",
    "rates": [
      {
        "metric": "input_audio",
        "usd": "10.00",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "cached_audio",
        "usd": "0.30",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "output_audio",
        "usd": "20.00",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "input_text",
        "usd": "0.60",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "cached_text",
        "usd": "0.06",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "output_text",
        "usd": "2.40",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "input_image",
        "usd": "0.80",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "cached_image",
        "usd": "0.08",
        "unit": "millionTokens",
        "condition": ""
      }
    ],
    "sourceURL": "https://developers.openai.com/api/docs/pricing"
  },
  {
    "provider": "OpenAI",
    "modelID": "gpt-realtime-2",
    "category": "audio",
    "rates": [
      {
        "metric": "input_audio",
        "usd": "32.00",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "cached_audio",
        "usd": "0.40",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "output_audio",
        "usd": "64.00",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "input_text",
        "usd": "4.00",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "cached_text",
        "usd": "0.40",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "output_text",
        "usd": "24.00",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "input_image",
        "usd": "5.00",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "cached_image",
        "usd": "0.50",
        "unit": "millionTokens",
        "condition": ""
      }
    ],
    "sourceURL": "https://developers.openai.com/api/docs/pricing"
  },
  {
    "provider": "OpenAI",
    "modelID": "gpt-realtime-1.5",
    "category": "audio",
    "rates": [
      {
        "metric": "input_audio",
        "usd": "32.00",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "cached_audio",
        "usd": "0.40",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "output_audio",
        "usd": "64.00",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "input_text",
        "usd": "4.00",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "cached_text",
        "usd": "0.40",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "output_text",
        "usd": "16.00",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "input_image",
        "usd": "5.00",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "cached_image",
        "usd": "0.50",
        "unit": "millionTokens",
        "condition": ""
      }
    ],
    "sourceURL": "https://developers.openai.com/api/docs/pricing"
  },
  {
    "provider": "OpenAI",
    "modelID": "gpt-realtime-mini",
    "category": "audio",
    "rates": [
      {
        "metric": "input_audio",
        "usd": "10.00",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "cached_audio",
        "usd": "0.30",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "output_audio",
        "usd": "20.00",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "input_text",
        "usd": "0.60",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "cached_text",
        "usd": "0.06",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "output_text",
        "usd": "2.40",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "input_image",
        "usd": "0.80",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "cached_image",
        "usd": "0.08",
        "unit": "millionTokens",
        "condition": ""
      }
    ],
    "sourceURL": "https://developers.openai.com/api/docs/pricing"
  },
  {
    "provider": "OpenAI",
    "modelID": "gpt-realtime",
    "category": "audio",
    "rates": [
      {
        "metric": "input_audio",
        "usd": "32.00",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "cached_audio",
        "usd": "0.40",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "output_audio",
        "usd": "64.00",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "input_text",
        "usd": "4.00",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "cached_text",
        "usd": "0.40",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "output_text",
        "usd": "16.00",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "input_image",
        "usd": "5.00",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "cached_image",
        "usd": "0.50",
        "unit": "millionTokens",
        "condition": ""
      }
    ],
    "sourceURL": "https://developers.openai.com/api/docs/pricing"
  },
  {
    "provider": "OpenAI",
    "modelID": "gpt-audio-1.5",
    "category": "audio",
    "rates": [
      {
        "metric": "input_audio",
        "usd": "32.00",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "output_audio",
        "usd": "64.00",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "input_text",
        "usd": "2.50",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "output_text",
        "usd": "10.00",
        "unit": "millionTokens",
        "condition": ""
      }
    ],
    "sourceURL": "https://developers.openai.com/api/docs/pricing"
  },
  {
    "provider": "OpenAI",
    "modelID": "gpt-audio-mini",
    "category": "audio",
    "rates": [
      {
        "metric": "input_audio",
        "usd": "10.00",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "output_audio",
        "usd": "20.00",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "input_text",
        "usd": "0.60",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "output_text",
        "usd": "2.40",
        "unit": "millionTokens",
        "condition": ""
      }
    ],
    "sourceURL": "https://developers.openai.com/api/docs/pricing"
  },
  {
    "provider": "OpenAI",
    "modelID": "gpt-audio",
    "category": "audio",
    "rates": [
      {
        "metric": "input_audio",
        "usd": "32.00",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "output_audio",
        "usd": "64.00",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "input_text",
        "usd": "2.50",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "output_text",
        "usd": "10.00",
        "unit": "millionTokens",
        "condition": ""
      }
    ],
    "sourceURL": "https://developers.openai.com/api/docs/pricing"
  },
  {
    "provider": "OpenAI",
    "modelID": "gpt-4o-mini-tts",
    "category": "audio",
    "rates": [
      {
        "metric": "output_audio",
        "usd": "12.00",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "input_text",
        "usd": "0.60",
        "unit": "millionTokens",
        "condition": ""
      }
    ],
    "sourceURL": "https://developers.openai.com/api/docs/pricing"
  },
  {
    "provider": "OpenAI",
    "modelID": "tts-1",
    "category": "audio",
    "rates": [
      {
        "metric": "input_text",
        "usd": "15.00",
        "unit": "millionCharacters",
        "condition": ""
      }
    ],
    "sourceURL": "https://developers.openai.com/api/docs/pricing"
  },
  {
    "provider": "OpenAI",
    "modelID": "tts-1-hd",
    "category": "audio",
    "rates": [
      {
        "metric": "input_text",
        "usd": "30.00",
        "unit": "millionCharacters",
        "condition": ""
      }
    ],
    "sourceURL": "https://developers.openai.com/api/docs/pricing"
  },
  {
    "provider": "OpenAI",
    "modelID": "gpt-image-2",
    "category": "image",
    "rates": [
      {
        "metric": "input_image",
        "usd": "8.00",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "cached_image",
        "usd": "2.00",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "output_image",
        "usd": "30.00",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "input_text",
        "usd": "5.00",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "cached_text",
        "usd": "1.25",
        "unit": "millionTokens",
        "condition": ""
      }
    ],
    "sourceURL": "https://developers.openai.com/api/docs/pricing"
  },
  {
    "provider": "OpenAI",
    "modelID": "gpt-image-1.5",
    "category": "image",
    "rates": [
      {
        "metric": "input_image",
        "usd": "8.00",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "cached_image",
        "usd": "2.00",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "output_image",
        "usd": "32.00",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "input_text",
        "usd": "5.00",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "cached_text",
        "usd": "1.25",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "output_text",
        "usd": "10.00",
        "unit": "millionTokens",
        "condition": ""
      }
    ],
    "sourceURL": "https://developers.openai.com/api/docs/pricing"
  },
  {
    "provider": "OpenAI",
    "modelID": "gpt-image-1-mini",
    "category": "image",
    "rates": [
      {
        "metric": "input_image",
        "usd": "2.50",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "cached_image",
        "usd": "0.25",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "output_image",
        "usd": "8.00",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "input_text",
        "usd": "2.00",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "cached_text",
        "usd": "0.20",
        "unit": "millionTokens",
        "condition": ""
      }
    ],
    "sourceURL": "https://developers.openai.com/api/docs/pricing"
  },
  {
    "provider": "OpenAI",
    "modelID": "gpt-image-1",
    "category": "image",
    "rates": [
      {
        "metric": "input_image",
        "usd": "10.00",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "cached_image",
        "usd": "2.50",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "output_image",
        "usd": "40.00",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "input_text",
        "usd": "5.00",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "cached_text",
        "usd": "1.25",
        "unit": "millionTokens",
        "condition": ""
      }
    ],
    "sourceURL": "https://developers.openai.com/api/docs/pricing"
  },
  {
    "provider": "OpenAI",
    "modelID": "chatgpt-image-latest",
    "category": "image",
    "rates": [
      {
        "metric": "input_image",
        "usd": "8.00",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "cached_image",
        "usd": "2.00",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "output_image",
        "usd": "32.00",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "input_text",
        "usd": "5.00",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "cached_text",
        "usd": "1.25",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "output_text",
        "usd": "10.00",
        "unit": "millionTokens",
        "condition": ""
      }
    ],
    "sourceURL": "https://developers.openai.com/api/docs/pricing"
  },
  {
    "provider": "OpenAI",
    "modelID": "sora-2",
    "category": "video",
    "rates": [
      {
        "metric": "output_video",
        "usd": "0.10",
        "unit": "second",
        "condition": "720p"
      }
    ],
    "sourceURL": "https://developers.openai.com/api/docs/pricing"
  },
  {
    "provider": "OpenAI",
    "modelID": "sora-2-pro",
    "category": "video",
    "rates": [
      {
        "metric": "output_video",
        "usd": "0.30",
        "unit": "second",
        "condition": "720p"
      },
      {
        "metric": "output_video",
        "usd": "0.50",
        "unit": "second",
        "condition": "1024p"
      },
      {
        "metric": "output_video",
        "usd": "0.70",
        "unit": "second",
        "condition": "1080p"
      }
    ],
    "sourceURL": "https://developers.openai.com/api/docs/pricing"
  },
  {
    "provider": "OpenAI",
    "modelID": "gpt-realtime-translate",
    "category": "audio",
    "rates": [
      {
        "metric": "estimate",
        "usd": "0.034",
        "unit": "minute",
        "condition": ""
      }
    ],
    "sourceURL": "https://developers.openai.com/api/docs/pricing"
  },
  {
    "provider": "OpenAI",
    "modelID": "gpt-live-transcribe",
    "category": "audio",
    "rates": [
      {
        "metric": "estimate",
        "usd": "0.017",
        "unit": "minute",
        "condition": ""
      }
    ],
    "sourceURL": "https://developers.openai.com/api/docs/pricing"
  },
  {
    "provider": "OpenAI",
    "modelID": "gpt-realtime-whisper",
    "category": "audio",
    "rates": [
      {
        "metric": "estimate",
        "usd": "0.017",
        "unit": "minute",
        "condition": ""
      }
    ],
    "sourceURL": "https://developers.openai.com/api/docs/pricing"
  },
  {
    "provider": "OpenAI",
    "modelID": "gpt-transcribe",
    "category": "audio",
    "rates": [
      {
        "metric": "estimate",
        "usd": "0.0045",
        "unit": "minute",
        "condition": ""
      }
    ],
    "sourceURL": "https://developers.openai.com/api/docs/pricing"
  },
  {
    "provider": "OpenAI",
    "modelID": "gpt-4o-transcribe",
    "category": "audio",
    "rates": [
      {
        "metric": "input_text",
        "usd": "2.50",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "output_text",
        "usd": "10.00",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "estimate",
        "usd": "0.006",
        "unit": "minute",
        "condition": ""
      }
    ],
    "sourceURL": "https://developers.openai.com/api/docs/pricing"
  },
  {
    "provider": "OpenAI",
    "modelID": "gpt-4o-mini-transcribe",
    "category": "audio",
    "rates": [
      {
        "metric": "input_text",
        "usd": "1.25",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "output_text",
        "usd": "5.00",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "estimate",
        "usd": "0.003",
        "unit": "minute",
        "condition": ""
      }
    ],
    "sourceURL": "https://developers.openai.com/api/docs/pricing"
  },
  {
    "provider": "OpenAI",
    "modelID": "gpt-4o-transcribe-diarize",
    "category": "audio",
    "rates": [
      {
        "metric": "input_text",
        "usd": "2.50",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "output_text",
        "usd": "10.00",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "estimate",
        "usd": "0.006",
        "unit": "minute",
        "condition": ""
      }
    ],
    "sourceURL": "https://developers.openai.com/api/docs/pricing"
  },
  {
    "provider": "OpenAI",
    "modelID": "text-embedding-3-small",
    "category": "embedding",
    "rates": [
      {
        "metric": "input_text",
        "usd": "0.02",
        "unit": "millionTokens",
        "condition": ""
      }
    ],
    "sourceURL": "https://developers.openai.com/api/docs/pricing"
  },
  {
    "provider": "OpenAI",
    "modelID": "text-embedding-3-large",
    "category": "embedding",
    "rates": [
      {
        "metric": "input_text",
        "usd": "0.13",
        "unit": "millionTokens",
        "condition": ""
      }
    ],
    "sourceURL": "https://developers.openai.com/api/docs/pricing"
  },
  {
    "provider": "OpenAI",
    "modelID": "text-embedding-ada-002",
    "category": "embedding",
    "rates": [
      {
        "metric": "input_text",
        "usd": "0.10",
        "unit": "millionTokens",
        "condition": ""
      }
    ],
    "sourceURL": "https://developers.openai.com/api/docs/pricing"
  },
  {
    "provider": "Google",
    "modelID": "gemini-2.5-flash-native-audio-preview-12-2025",
    "category": "audio",
    "rates": [
      {
        "metric": "input_text",
        "usd": "0.5",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "output_text",
        "usd": "2",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "input_audio",
        "usd": "3",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "output_audio",
        "usd": "12",
        "unit": "millionTokens",
        "condition": ""
      }
    ],
    "sourceURL": "https://ai.google.dev/gemini-api/docs/pricing"
  },
  {
    "provider": "Google",
    "modelID": "gemini-3.1-flash-live-preview",
    "category": "audio",
    "rates": [
      {
        "metric": "input_text",
        "usd": "0.75",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "output_text",
        "usd": "4.5",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "input_audio",
        "usd": "3",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "output_audio",
        "usd": "12",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "input_image",
        "usd": "1",
        "unit": "millionTokens",
        "condition": ""
      }
    ],
    "sourceURL": "https://ai.google.dev/gemini-api/docs/pricing"
  },
  {
    "provider": "Google",
    "modelID": "gemini-2.5-flash-preview-tts",
    "category": "audio",
    "rates": [
      {
        "metric": "input_text",
        "usd": "0.5",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "output_audio",
        "usd": "10",
        "unit": "millionTokens",
        "condition": ""
      }
    ],
    "sourceURL": "https://ai.google.dev/gemini-api/docs/pricing"
  },
  {
    "provider": "Google",
    "modelID": "gemini-2.5-pro-preview-tts",
    "category": "audio",
    "rates": [
      {
        "metric": "input_text",
        "usd": "1",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "output_audio",
        "usd": "20",
        "unit": "millionTokens",
        "condition": ""
      }
    ],
    "sourceURL": "https://ai.google.dev/gemini-api/docs/pricing"
  },
  {
    "provider": "Google",
    "modelID": "gemini-3.1-flash-tts-preview",
    "category": "audio",
    "rates": [
      {
        "metric": "input_text",
        "usd": "1",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "output_audio",
        "usd": "20",
        "unit": "millionTokens",
        "condition": ""
      }
    ],
    "sourceURL": "https://ai.google.dev/gemini-api/docs/pricing"
  },
  {
    "provider": "Google",
    "modelID": "gemini-3.5-live-translate-preview",
    "category": "audio",
    "rates": [
      {
        "metric": "input_audio",
        "usd": "3.5",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "output_audio",
        "usd": "21",
        "unit": "millionTokens",
        "condition": ""
      }
    ],
    "sourceURL": "https://ai.google.dev/gemini-api/docs/pricing"
  },
  {
    "provider": "Google",
    "modelID": "gemini-3.5-transcribe-live",
    "category": "audio",
    "rates": [
      {
        "metric": "output_text",
        "usd": "21",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "input_audio",
        "usd": "3.5",
        "unit": "millionTokens",
        "condition": ""
      }
    ],
    "sourceURL": "https://ai.google.dev/gemini-api/docs/pricing"
  },
  {
    "provider": "Google",
    "modelID": "gemini-3.5-transcribe",
    "category": "audio",
    "rates": [
      {
        "metric": "output_text",
        "usd": "12",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "input_audio",
        "usd": "2",
        "unit": "millionTokens",
        "condition": ""
      }
    ],
    "sourceURL": "https://ai.google.dev/gemini-api/docs/pricing"
  },
  {
    "provider": "Google",
    "modelID": "gemini-2.5-flash-image",
    "category": "image",
    "rates": [
      {
        "metric": "input_text",
        "usd": "0.3",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "input_image",
        "usd": "0.3",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "output_text",
        "usd": "2.5",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "output_image",
        "usd": "30",
        "unit": "millionTokens",
        "condition": ""
      }
    ],
    "sourceURL": "https://ai.google.dev/gemini-api/docs/pricing"
  },
  {
    "provider": "Google",
    "modelID": "gemini-3.1-flash-image",
    "category": "image",
    "rates": [
      {
        "metric": "input_text",
        "usd": "0.5",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "input_image",
        "usd": "0.5",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "output_text",
        "usd": "3",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "output_image",
        "usd": "60",
        "unit": "millionTokens",
        "condition": ""
      }
    ],
    "sourceURL": "https://ai.google.dev/gemini-api/docs/pricing"
  },
  {
    "provider": "Google",
    "modelID": "gemini-3.1-flash-lite-image",
    "category": "image",
    "rates": [
      {
        "metric": "input_text",
        "usd": "0.25",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "input_image",
        "usd": "0.25",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "output_text",
        "usd": "1.5",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "output_image",
        "usd": "30",
        "unit": "millionTokens",
        "condition": ""
      }
    ],
    "sourceURL": "https://ai.google.dev/gemini-api/docs/pricing"
  },
  {
    "provider": "Google",
    "modelID": "gemini-3-pro-image",
    "category": "image",
    "rates": [
      {
        "metric": "input_text",
        "usd": "2",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "input_image",
        "usd": "2",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "output_text",
        "usd": "12",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "output_image",
        "usd": "120",
        "unit": "millionTokens",
        "condition": ""
      }
    ],
    "sourceURL": "https://ai.google.dev/gemini-api/docs/pricing"
  },
  {
    "provider": "Google",
    "modelID": "gemini-omni-1.1-flash",
    "category": "video",
    "rates": [
      {
        "metric": "input",
        "usd": "1.5",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "output_text",
        "usd": "9",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "output_video",
        "usd": "17.5",
        "unit": "millionTokens",
        "condition": "720p"
      }
    ],
    "sourceURL": "https://ai.google.dev/gemini-api/docs/pricing"
  },
  {
    "provider": "Google",
    "modelID": "gemini-omni-flash-preview",
    "category": "video",
    "rates": [
      {
        "metric": "input",
        "usd": "1.5",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "output_text",
        "usd": "9",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "output_video",
        "usd": "17.5",
        "unit": "millionTokens",
        "condition": "720p"
      }
    ],
    "sourceURL": "https://ai.google.dev/gemini-api/docs/pricing"
  },
  {
    "provider": "Google",
    "modelID": "veo-3.1-generate-preview",
    "category": "video",
    "rates": [
      {
        "metric": "output_video",
        "usd": "0.4",
        "unit": "second",
        "condition": "720p / 1080p"
      },
      {
        "metric": "output_video",
        "usd": "0.6",
        "unit": "second",
        "condition": "4K"
      }
    ],
    "sourceURL": "https://ai.google.dev/gemini-api/docs/pricing"
  },
  {
    "provider": "Google",
    "modelID": "veo-3.1-fast-generate-preview",
    "category": "video",
    "rates": [
      {
        "metric": "output_video",
        "usd": "0.1",
        "unit": "second",
        "condition": "720p"
      },
      {
        "metric": "output_video",
        "usd": "0.12",
        "unit": "second",
        "condition": "1080p"
      },
      {
        "metric": "output_video",
        "usd": "0.3",
        "unit": "second",
        "condition": "4K"
      }
    ],
    "sourceURL": "https://ai.google.dev/gemini-api/docs/pricing"
  },
  {
    "provider": "Google",
    "modelID": "veo-3.1-lite-generate-preview",
    "category": "video",
    "rates": [
      {
        "metric": "output_video",
        "usd": "0.05",
        "unit": "second",
        "condition": "720p"
      },
      {
        "metric": "output_video",
        "usd": "0.08",
        "unit": "second",
        "condition": "1080p"
      }
    ],
    "sourceURL": "https://ai.google.dev/gemini-api/docs/pricing"
  },
  {
    "provider": "Google",
    "modelID": "lyria-3.5",
    "category": "audio",
    "rates": [
      {
        "metric": "output_audio",
        "usd": "0.08",
        "unit": "song",
        "condition": ""
      }
    ],
    "sourceURL": "https://ai.google.dev/gemini-api/docs/pricing"
  },
  {
    "provider": "Google",
    "modelID": "lyria-3-clip-preview",
    "category": "audio",
    "rates": [
      {
        "metric": "output_audio",
        "usd": "0.04",
        "unit": "song",
        "condition": ""
      }
    ],
    "sourceURL": "https://ai.google.dev/gemini-api/docs/pricing"
  },
  {
    "provider": "Google",
    "modelID": "lyria-3-pro-preview",
    "category": "audio",
    "rates": [
      {
        "metric": "output_audio",
        "usd": "0.08",
        "unit": "song",
        "condition": ""
      }
    ],
    "sourceURL": "https://ai.google.dev/gemini-api/docs/pricing"
  },
  {
    "provider": "Google",
    "modelID": "gemini-embedding-001",
    "category": "embedding",
    "rates": [
      {
        "metric": "input_text",
        "usd": "0.15",
        "unit": "millionTokens",
        "condition": ""
      }
    ],
    "sourceURL": "https://ai.google.dev/gemini-api/docs/pricing"
  },
  {
    "provider": "Google",
    "modelID": "gemini-embedding-2",
    "category": "embedding",
    "rates": [
      {
        "metric": "input_text",
        "usd": "0.2",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "input_image",
        "usd": "0.45",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "input_audio",
        "usd": "6.5",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "input_video",
        "usd": "12",
        "unit": "millionTokens",
        "condition": ""
      }
    ],
    "sourceURL": "https://ai.google.dev/gemini-api/docs/pricing"
  },
  {
    "provider": "Google",
    "modelID": "gemini-2.0-flash-exp",
    "category": "text",
    "rates": [],
    "sourceURL": "https://ai.google.dev/gemini-api/docs/changelog"
  },
  {
    "provider": "Google",
    "modelID": "gemini-2.0-flash-exp-image-generation",
    "category": "image",
    "rates": [],
    "sourceURL": "https://ai.google.dev/gemini-api/docs/changelog"
  },
  {
    "provider": "Google",
    "modelID": "gemini-2.0-flash-lite-preview",
    "category": "text",
    "rates": [],
    "sourceURL": "https://ai.google.dev/gemini-api/docs/changelog"
  },
  {
    "provider": "Google",
    "modelID": "gemini-2.0-flash-lite-preview-02-05",
    "category": "text",
    "rates": [],
    "sourceURL": "https://ai.google.dev/gemini-api/docs/changelog"
  },
  {
    "provider": "Google",
    "modelID": "gemini-2.0-flash-live-001",
    "category": "audio",
    "rates": [],
    "sourceURL": "https://ai.google.dev/gemini-api/docs/changelog"
  },
  {
    "provider": "Google",
    "modelID": "gemini-2.0-flash-preview-image-generation",
    "category": "image",
    "rates": [],
    "sourceURL": "https://ai.google.dev/gemini-api/docs/changelog"
  },
  {
    "provider": "Google",
    "modelID": "gemini-2.0-flash-thinking-exp",
    "category": "text",
    "rates": [],
    "sourceURL": "https://ai.google.dev/gemini-api/docs/changelog"
  },
  {
    "provider": "Google",
    "modelID": "gemini-2.0-flash-thinking-exp-01-21",
    "category": "text",
    "rates": [],
    "sourceURL": "https://ai.google.dev/gemini-api/docs/changelog"
  },
  {
    "provider": "Google",
    "modelID": "gemini-2.0-flash-thinking-exp-1219",
    "category": "text",
    "rates": [],
    "sourceURL": "https://ai.google.dev/gemini-api/docs/changelog"
  },
  {
    "provider": "Google",
    "modelID": "gemini-2.0-pro-exp",
    "category": "text",
    "rates": [],
    "sourceURL": "https://ai.google.dev/gemini-api/docs/changelog"
  },
  {
    "provider": "Google",
    "modelID": "gemini-2.0-pro-exp-02-05",
    "category": "text",
    "rates": [],
    "sourceURL": "https://ai.google.dev/gemini-api/docs/changelog"
  },
  {
    "provider": "Google",
    "modelID": "gemini-2.5-flash-exp-native-audio-thinking-dialog",
    "category": "audio",
    "rates": [],
    "sourceURL": "https://ai.google.dev/gemini-api/docs/changelog"
  },
  {
    "provider": "Google",
    "modelID": "gemini-2.5-flash-image-preview",
    "category": "image",
    "rates": [],
    "sourceURL": "https://ai.google.dev/gemini-api/docs/changelog"
  },
  {
    "provider": "Google",
    "modelID": "gemini-2.5-flash-lite-preview-06-17",
    "category": "text",
    "rates": [],
    "sourceURL": "https://ai.google.dev/gemini-api/docs/changelog"
  },
  {
    "provider": "Google",
    "modelID": "gemini-2.5-flash-lite-preview-09-2025",
    "category": "text",
    "rates": [],
    "sourceURL": "https://ai.google.dev/gemini-api/docs/changelog"
  },
  {
    "provider": "Google",
    "modelID": "gemini-2.5-flash-native-audio-preview-09-2025",
    "category": "audio",
    "rates": [],
    "sourceURL": "https://ai.google.dev/gemini-api/docs/changelog"
  },
  {
    "provider": "Google",
    "modelID": "gemini-2.5-flash-preview-04-17",
    "category": "text",
    "rates": [],
    "sourceURL": "https://ai.google.dev/gemini-api/docs/changelog"
  },
  {
    "provider": "Google",
    "modelID": "gemini-2.5-flash-preview-05-20",
    "category": "text",
    "rates": [],
    "sourceURL": "https://ai.google.dev/gemini-api/docs/changelog"
  },
  {
    "provider": "Google",
    "modelID": "gemini-2.5-flash-preview-09-2025",
    "category": "text",
    "rates": [],
    "sourceURL": "https://ai.google.dev/gemini-api/docs/changelog"
  },
  {
    "provider": "Google",
    "modelID": "gemini-2.5-flash-preview-native-audio-dialog",
    "category": "audio",
    "rates": [],
    "sourceURL": "https://ai.google.dev/gemini-api/docs/changelog"
  },
  {
    "provider": "Google",
    "modelID": "gemini-2.5-pro-exp-03-25",
    "category": "text",
    "rates": [],
    "sourceURL": "https://ai.google.dev/gemini-api/docs/changelog"
  },
  {
    "provider": "Google",
    "modelID": "gemini-2.5-pro-preview-03-25",
    "category": "text",
    "rates": [],
    "sourceURL": "https://ai.google.dev/gemini-api/docs/changelog"
  },
  {
    "provider": "Google",
    "modelID": "gemini-2.5-pro-preview-05-06",
    "category": "text",
    "rates": [],
    "sourceURL": "https://ai.google.dev/gemini-api/docs/changelog"
  },
  {
    "provider": "Google",
    "modelID": "gemini-2.5-pro-preview-06-05",
    "category": "text",
    "rates": [],
    "sourceURL": "https://ai.google.dev/gemini-api/docs/changelog"
  },
  {
    "provider": "Google",
    "modelID": "gemini-3-pro-image-preview",
    "category": "image",
    "rates": [],
    "sourceURL": "https://ai.google.dev/gemini-api/docs/changelog"
  },
  {
    "provider": "Google",
    "modelID": "gemini-3-pro-preview",
    "category": "text",
    "rates": [],
    "sourceURL": "https://ai.google.dev/gemini-api/docs/changelog"
  },
  {
    "provider": "Google",
    "modelID": "gemini-3.1-flash-image-preview",
    "category": "image",
    "rates": [],
    "sourceURL": "https://ai.google.dev/gemini-api/docs/changelog"
  },
  {
    "provider": "Google",
    "modelID": "gemini-3.1-flash-lite-preview",
    "category": "text",
    "rates": [],
    "sourceURL": "https://ai.google.dev/gemini-api/docs/changelog"
  },
  {
    "provider": "Google",
    "modelID": "gemini-embedding-2-preview",
    "category": "embedding",
    "rates": [],
    "sourceURL": "https://ai.google.dev/gemini-api/docs/changelog"
  },
  {
    "provider": "Google",
    "modelID": "gemini-embedding-exp",
    "category": "embedding",
    "rates": [],
    "sourceURL": "https://ai.google.dev/gemini-api/docs/changelog"
  },
  {
    "provider": "Google",
    "modelID": "gemini-embedding-exp-03-07",
    "category": "embedding",
    "rates": [],
    "sourceURL": "https://ai.google.dev/gemini-api/docs/changelog"
  },
  {
    "provider": "Google",
    "modelID": "gemini-flash-latest",
    "category": "text",
    "rates": [],
    "sourceURL": "https://ai.google.dev/gemini-api/docs/changelog"
  },
  {
    "provider": "Google",
    "modelID": "gemini-live-2.5-flash-preview",
    "category": "audio",
    "rates": [],
    "sourceURL": "https://ai.google.dev/gemini-api/docs/changelog"
  },
  {
    "provider": "Google",
    "modelID": "gemini-pro-latest",
    "category": "text",
    "rates": [],
    "sourceURL": "https://ai.google.dev/gemini-api/docs/changelog"
  },
  {
    "provider": "Google",
    "modelID": "gemini-robotics-er-1.5-preview",
    "category": "text",
    "rates": [],
    "sourceURL": "https://ai.google.dev/gemini-api/docs/changelog"
  },
  {
    "provider": "Google",
    "modelID": "gemini-robotics-er-2-streaming-preview",
    "category": "text",
    "rates": [],
    "sourceURL": "https://ai.google.dev/gemini-api/docs/changelog"
  },
  {
    "provider": "Google",
    "modelID": "imagen-3.0-generate-002",
    "category": "image",
    "rates": [
      {
        "metric": "output_image",
        "usd": "0.04",
        "unit": "image",
        "condition": "Agent Platform"
      }
    ],
    "sourceURL": "https://cloud.google.com/gemini-enterprise-agent-platform/generative-ai/pricing"
  },
  {
    "provider": "Google",
    "modelID": "imagen-4.0-fast-generate-001",
    "category": "image",
    "rates": [
      {
        "metric": "output_image",
        "usd": "0.02",
        "unit": "image",
        "condition": "Agent Platform"
      }
    ],
    "sourceURL": "https://cloud.google.com/gemini-enterprise-agent-platform/generative-ai/pricing"
  },
  {
    "provider": "Google",
    "modelID": "imagen-4.0-generate-001",
    "category": "image",
    "rates": [
      {
        "metric": "output_image",
        "usd": "0.04",
        "unit": "image",
        "condition": "Agent Platform"
      }
    ],
    "sourceURL": "https://cloud.google.com/gemini-enterprise-agent-platform/generative-ai/pricing"
  },
  {
    "provider": "Google",
    "modelID": "imagen-4.0-generate-preview-06-06",
    "category": "image",
    "rates": [],
    "sourceURL": "https://ai.google.dev/gemini-api/docs/changelog"
  },
  {
    "provider": "Google",
    "modelID": "imagen-4.0-ultra-generate-001",
    "category": "image",
    "rates": [
      {
        "metric": "output_image",
        "usd": "0.06",
        "unit": "image",
        "condition": "Agent Platform"
      }
    ],
    "sourceURL": "https://cloud.google.com/gemini-enterprise-agent-platform/generative-ai/pricing"
  },
  {
    "provider": "Google",
    "modelID": "imagen-4.0-ultra-generate-preview-06-06",
    "category": "image",
    "rates": [],
    "sourceURL": "https://ai.google.dev/gemini-api/docs/changelog"
  },
  {
    "provider": "Google",
    "modelID": "lyria-realtime-exp",
    "category": "audio",
    "rates": [],
    "sourceURL": "https://ai.google.dev/gemini-api/docs/changelog"
  },
  {
    "provider": "Google",
    "modelID": "veo-2.0-generate-001",
    "category": "video",
    "rates": [],
    "sourceURL": "https://ai.google.dev/gemini-api/docs/changelog"
  },
  {
    "provider": "Google",
    "modelID": "veo-3.0-fast-generate-001",
    "category": "video",
    "rates": [],
    "sourceURL": "https://ai.google.dev/gemini-api/docs/changelog"
  },
  {
    "provider": "Google",
    "modelID": "veo-3.0-fast-generate-preview",
    "category": "video",
    "rates": [],
    "sourceURL": "https://ai.google.dev/gemini-api/docs/changelog"
  },
  {
    "provider": "Google",
    "modelID": "veo-3.0-generate-001",
    "category": "video",
    "rates": [],
    "sourceURL": "https://ai.google.dev/gemini-api/docs/changelog"
  },
  {
    "provider": "Google",
    "modelID": "veo-3.0-generate-preview",
    "category": "video",
    "rates": [],
    "sourceURL": "https://ai.google.dev/gemini-api/docs/changelog"
  },
  {
    "provider": "OpenAI",
    "modelID": "gpt-5.3-codex-spark",
    "category": "text",
    "rates": [],
    "sourceURL": "https://developers.openai.com/api/docs/models"
  },
  {
    "provider": "OpenAI",
    "modelID": "gpt-5.4-cyber",
    "category": "text",
    "rates": [],
    "sourceURL": "https://developers.openai.com/api/docs/models"
  },
  {
    "provider": "OpenAI",
    "modelID": "gpt-daybreak-blue-latest",
    "category": "text",
    "rates": [],
    "sourceURL": "https://developers.openai.com/api/docs/models"
  },
  {
    "provider": "OpenAI",
    "modelID": "gpt-daybreak-red-latest",
    "category": "text",
    "rates": [],
    "sourceURL": "https://developers.openai.com/api/docs/models"
  },
  {
    "provider": "OpenAI",
    "modelID": "gpt-oss-20b",
    "category": "text",
    "rates": [],
    "sourceURL": "https://developers.openai.com/api/docs/models"
  },
  {
    "provider": "OpenAI",
    "modelID": "gpt-oss-120b",
    "category": "text",
    "rates": [],
    "sourceURL": "https://developers.openai.com/api/docs/models"
  },
  {
    "provider": "OpenAI",
    "modelID": "gpt-4o-audio-preview",
    "category": "audio",
    "rates": [
      {
        "metric": "input_text",
        "usd": "2.5",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "output_text",
        "usd": "10",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "input_audio",
        "usd": "40",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "output_audio",
        "usd": "80",
        "unit": "millionTokens",
        "condition": ""
      }
    ],
    "sourceURL": "https://developers.openai.com/api/docs/models/gpt-4o-audio-preview"
  },
  {
    "provider": "OpenAI",
    "modelID": "gpt-4o-realtime-preview",
    "category": "audio",
    "rates": [
      {
        "metric": "input_text",
        "usd": "5",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "cached_text",
        "usd": "2.5",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "output_text",
        "usd": "20",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "input_audio",
        "usd": "40",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "cached_audio",
        "usd": "2.5",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "output_audio",
        "usd": "80",
        "unit": "millionTokens",
        "condition": ""
      }
    ],
    "sourceURL": "https://developers.openai.com/api/docs/models/gpt-4o-realtime-preview"
  },
  {
    "provider": "OpenAI",
    "modelID": "gpt-4o-mini-audio-preview",
    "category": "audio",
    "rates": [
      {
        "metric": "input_text",
        "usd": "0.15",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "output_text",
        "usd": "0.6",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "input_audio",
        "usd": "10",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "output_audio",
        "usd": "20",
        "unit": "millionTokens",
        "condition": ""
      }
    ],
    "sourceURL": "https://developers.openai.com/api/docs/models/gpt-4o-mini-audio-preview"
  },
  {
    "provider": "OpenAI",
    "modelID": "gpt-4o-mini-realtime-preview",
    "category": "audio",
    "rates": [
      {
        "metric": "input_text",
        "usd": "0.6",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "cached_text",
        "usd": "0.3",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "output_text",
        "usd": "2.4",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "input_audio",
        "usd": "10",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "cached_audio",
        "usd": "0.3",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "output_audio",
        "usd": "20",
        "unit": "millionTokens",
        "condition": ""
      }
    ],
    "sourceURL": "https://developers.openai.com/api/docs/models/gpt-4o-mini-realtime-preview"
  },
  {
    "provider": "Anthropic",
    "modelID": "claude-mythos-preview",
    "category": "text",
    "rates": [
      {
        "metric": "input_text",
        "usd": "25",
        "unit": "millionTokens",
        "condition": ""
      },
      {
        "metric": "output_text",
        "usd": "125",
        "unit": "millionTokens",
        "condition": ""
      }
    ],
    "sourceURL": "https://www.anthropic.com/glasswing"
  }
]
"""#
}
