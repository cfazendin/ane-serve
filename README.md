# ane-serve

**Apple's on-device AI, served over HTTP.** ane-serve runs on an Apple silicon Mac and makes the Mac's built-in models available to anything that can send an HTTP request. It serves Apple's Foundation Models language model for chat, Vision for reading text and tagging images, and Speech for transcription. The chat endpoint uses the OpenAI chat completions format, so OpenAI client libraries can talk to it by changing their base URL.

Requests are processed on the Mac, and nothing is sent to a cloud service. Responses also report what the hardware was doing while each request ran: system-wide Apple Neural Engine (ANE) bandwidth and CPU/GPU power, read from macOS's IOReport counters.

## What it does

| Endpoint | What you get |
| :--- | :--- |
| `POST /v1/chat/completions` | Chat with Apple's on-device model in OpenAI's request and response format, with streaming, conversation history, system prompts, and image input. |
| `POST /v1/vision/analyze` | The text in an image (with confidence and bounding boxes), classification tags, and a short caption. |
| `POST /v1/audio/transcribe` | English speech-to-text with timestamps, from an audio or video file. |
| `POST /v1/video/scan` | One report for a whole video: transcript, scene changes, on-screen text, a caption per scene, and a summary. |
| `GET /v1/models` | The model list, for clients that ask for it. The one model is `apple-foundation-model-ane`. |
| `GET /v1/health` | Whether the model, speech assets, and ffmpeg are ready, plus the host's hardware and current telemetry. |

The server is written in Swift with no third-party packages. `ffmpeg` is needed only for audio and video.

## Requirements

These apply to the Mac running the server. Clients only need to reach it over HTTP.

| Component | Requirement |
| :--- | :--- |
| Mac | Apple silicon with a Neural Engine: any M-series Mac (M1 or later, including Pro, Max, and Ultra) or MacBook Neo (A18 Pro). Intel Macs aren't supported. |
| macOS | 27.0 or later. The code uses Core AI and Foundation Models image attachments, which arrived in macOS 27, so older releases would need code changes, not just a lower deployment target. |
| Build tools | Xcode 27 or later, with the macOS 27 SDK and its Swift compiler. |
| Chat and captions | Apple Intelligence turned on, with the on-device model downloaded, in a supported language and region. Image analysis and video scans use the model for captions and summaries. |
| Transcription | Support for Apple's on-device English (United States) speech model. The server downloads it the first time it's needed, which takes internet access once. |
| Audio and video | `ffmpeg` and `ffprobe`, both included in Homebrew's `ffmpeg`. |
| Telemetry | Nothing to install: `libIOReport` ships with macOS and needs no `sudo`. Available readings vary by chip and OS version. |

Apple lists eligible Macs in its [Apple Intelligence requirements](https://support.apple.com/en-us/121115) and the [MacBook Neo specifications](https://www.apple.com/macbook-neo/specs/), and describes the speech model in its [Speech asset documentation](https://developer.apple.com/documentation/speech/assetinventory). Meeting these requirements doesn't mean every chip and endpoint combination has been tested.

## Quick start

```bash
brew install ffmpeg      # only needed for audio and video
swift build -c release
.build/release/ane-serve
```

The server listens on `127.0.0.1:8090`, so only this Mac can reach it. In another terminal, ask the model something:

```bash
curl http://127.0.0.1:8090/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model": "apple-foundation-model-ane",
       "messages": [{"role": "user", "content": "Explain what a neural engine does in two sentences."}]}'
```

The reply is an OpenAI-style completion, with the text in `choices[0].message.content`. The same request with the OpenAI Python SDK:

```python
from openai import OpenAI

client = OpenAI(base_url="http://127.0.0.1:8090/v1", api_key="unused")
reply = client.chat.completions.create(
    model="apple-foundation-model-ane",
    messages=[{"role": "user", "content": "Explain what a neural engine does in two sentences."}],
)
print(reply.choices[0].message.content)
```

Any `api_key` works until the server has a key of its own (see [Using it from other machines](#using-it-from-other-machines)). If something isn't working, `curl http://127.0.0.1:8090/v1/health` shows whether the language model, the speech assets, and ffmpeg are ready.

## Using it from other machines

Start the server with a key and listen on all interfaces:

```bash
ANE_API_KEY='replace-with-your-key' .build/release/ane-serve --host 0.0.0.0
```

Clients use the Mac's address instead of `127.0.0.1` and send the key as `Authorization: Bearer <key>` (which is what OpenAI clients do with `api_key`) or as `X-API-Key: <key>`. Without a key, the server refuses to listen anywhere but localhost. Requests from a web page (anything with an `Origin` header) need a key even on localhost.

The server speaks plain HTTP, so the key crosses the network unencrypted. Use it this way only on a network you trust, or reach the Mac through an SSH tunnel or a VPN.

| Option | Environment variable | Default | Purpose |
| :--- | :--- | :--- | :--- |
| `--host` | `HOST` | `127.0.0.1` | Interface to listen on. Anything other than localhost requires a key. |
| `--port` | `PORT` | `8090` | Port to listen on. |
| `--api-key` | `ANE_API_KEY` | none | The key clients must send. |
| `--media-root` | `ANE_MEDIA_ROOT` | none | The folder that `*_path` request fields may read. |

### Sending files

Image, audio, and video requests take the file either as base64 in the request (`image_base64`, `audio_base64`, `video_base64`) or as the path of a file already on the Mac (`image_path`, `audio_path`, `video_path`).

Path fields are off by default, because they would let any client read whatever the server's user account can. To turn them on, name the one folder they may read:

```bash
.build/release/ane-serve --media-root ~/Movies
```

Paths are resolved, including symlinks, and anything outside that folder is rejected.

From another machine, upload the file instead. This Python helper uses only the standard library:

```python
import base64
import json
from pathlib import Path
from urllib.request import Request, urlopen

SERVER = "http://192.168.1.50:8090"
KEY = "replace-with-your-key"

def post(endpoint, payload):
    request = Request(SERVER + endpoint, data=json.dumps(payload).encode(), method="POST",
                      headers={"Content-Type": "application/json", "Authorization": "Bearer " + KEY})
    with urlopen(request, timeout=600) as response:
        return json.load(response)

def encoded(path):
    return base64.b64encode(Path(path).read_bytes()).decode("ascii")

memo = post("/v1/audio/transcribe", {"audio_base64": encoded("memo.m4a"), "format": "m4a"})
print(memo["text"])

scan = post("/v1/video/scan", {"video_base64": encoded("demo.mp4")})
print(scan["executiveSummary"])
```

A request body can be at most 50 MB, and base64 adds about a third to a file's size. Copy anything bigger into the media root and use a path field.

### Limits

The key is checked before a request body is read. A client has 30 seconds to send its headers, and a body that stalls for 30 seconds is dropped. At most 64 connections are open at once. At most two video scans or transcriptions run at a time; the rest wait their turn.

## Chat

`POST /v1/chat/completions` (also available as `/v1/ane/prompt`) takes `messages`, or a single `prompt` string with an optional `system` string, and `apple-foundation-model-ane` as the model. Leading `system` and `developer` messages become the model's instructions, in order. User and assistant messages become real conversation turns, including images in earlier user turns, and consecutive messages from the same role are combined. A conversation must start and end with a user turn, with any system or developer messages first.

A streaming request with conversation history:

```bash
curl --no-buffer http://127.0.0.1:8090/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "apple-foundation-model-ane",
    "messages": [
      {"role": "system", "content": "Answer briefly."},
      {"role": "user", "content": "Remember the color blue."},
      {"role": "assistant", "content": "I will remember blue."},
      {"role": "user", "content": "Which color did I ask you to remember?"}
    ],
    "temperature": 0,
    "max_tokens": 32,
    "stream": true,
    "stream_options": {"include_usage": true}
  }'
```

| Parameter | Behavior |
| :--- | :--- |
| `stream` | `false` (default) returns one JSON completion; `true` sends `text/event-stream` chunks as the text is generated. |
| `temperature` | A number from `0` to `2`. `0` selects greedy sampling. Omit it to use Apple's default. |
| `max_tokens` | A positive integer limiting the response length. Omit it to use the available context. |
| `max_completion_tokens` | Alias for `max_tokens`. If both are given, they must agree. |
| `stream_options.include_usage` | With streaming, `true` adds a final usage chunk (with empty `choices`) before `[DONE]`. |

A stream sends an assistant-role chunk, the content deltas, a final chunk with `finish_reason` and `ane_telemetry`, and then `data: [DONE]`. Non-streaming replies include `usage` and `ane_telemetry`. Token counts come from the framework. `finish_reason` is `length` when the output reaches `max_tokens`, and `stop` otherwise.

**Images.** User content can be an array of text and image parts:

```json
{
  "role": "user",
  "content": [
    {"type": "text", "text": "Describe this scene."},
    {"type": "image_url", "image_url": {"url": "data:image/png;base64,<YOUR_BASE64_DATA>", "detail": "auto"}}
  ]
}
```

Up to four images are accepted across the conversation. You can instead attach one image to the last user turn with a top-level `image_base64`, `image_path`, or `image_url` (only one of them). `image_url` must be a base64 data URL; remote URLs are rejected, and a data URL's declared type must match the image. Accepted formats are JPEG, PNG, GIF, WebP, HEIC/HEIF, TIFF, BMP, and AVIF, as far as the Mac's ImageIO can decode them. Each image can be at most 20 MiB and 64 million pixels. Images are rotated upright and scaled to at most 4096 pixels on the longest side (512 for an `image_url` with `"detail": "low"`), and animated images use their first frame.

**Unsupported options.** Tool calling, structured JSON output, stop sequences, `seed`, and other options the model can't honor return an `unsupported_parameter` error instead of being ignored. Neutral values that many clients send by default are accepted: empty `tools`, `tool_choice: "none"` or `"auto"`, an empty `stop` list, `n: 1`, `response_format: {"type": "text"}`, `top_p: 1`, `presence_penalty: 0`, and `frequency_penalty: 0`. Unknown model IDs return `404`.

## Image analysis

`POST /v1/vision/analyze` reads the text in an image, tags what's in it, and writes a caption. This example needs the server started with `--media-root /Users/you/Pictures`:

```bash
curl http://127.0.0.1:8090/v1/vision/analyze \
  -H 'Content-Type: application/json' \
  -d '{"image_path": "/Users/you/Pictures/example.jpg", "detail": "medium"}'
```

Send `image_base64`, or an `image_url` data URL, to upload the image instead. The response has:

- `ocr_text` (one entry per line of text), `ocr_full_text`, and `ocr_blocks`, each block with its text, confidence, and normalized bounding box.
- `classifications`: tags with confidence scores.
- `vlm_description`: a caption written by the language model. It describes the image rather than repeating its text, which stays in the OCR fields.
- `elapsed_seconds` and `ane_telemetry`.

`detail` sets the caption length: `short`, `medium` (default), or `detailed`. `prompt` replaces the default caption request, and `temperature` and `max_tokens` work as they do in chat. Captions need the on-device language model, so when it's unavailable the request fails with an error rather than returning an empty caption.

## Transcription

`POST /v1/audio/transcribe` turns the speech in an audio or video file into text with timestamps. With the server started with `--media-root /Users/you/Movies`:

```bash
curl http://127.0.0.1:8090/v1/audio/transcribe \
  -H 'Content-Type: application/json' \
  -d '{"audio_path": "/Users/you/Movies/interview.m4a"}'
```

Give the file as `audio_path` or `video_path`, or upload it as `audio_base64` with its `format` (default `wav`; the same extensions as video uploads). `max_duration_sec` limits how much is transcribed from the start: 600 seconds by default, and at most 3600. The response has the full `text`, `segments` with `start_sec`, `end_sec`, and `text`, plus `audio_duration_seconds`, `elapsed_seconds`, `realtime_speedup_x`, and `ane_telemetry`.

Transcription is English (United States) only. The speech model downloads automatically on first use; to download it ahead of time, run `.build/release/ane-serve --prepare-speech`. If the download can't finish, transcription requests return `503` with instructions.

## Video scan

`POST /v1/video/scan` combines the other features into one report for a video:

- **Speech:** the full transcript and timestamped segments.
- **Scenes:** the points where the picture changes. Up to `max_vlm_scenes` of them get their on-screen text and a caption, kept in separate fields so both are easy to search.
- **Summary:** three bullets drawn from the transcript and the scene captions.
- **Timing and telemetry:** processing times, frame and scene counts, and ANE/CPU/GPU readings over the scan.

To try it, generate the 12-second demo clip (three title cards with system-generated narration) and start the server with the demo folder as its media root:

```bash
swift examples/video-scan/make-demo.swift /private/tmp/ane-serve-release-demo
.build/release/ane-serve --media-root /private/tmp/ane-serve-release-demo
```

Then, in a second terminal, scan the clip:

```bash
curl http://127.0.0.1:8090/v1/video/scan \
  -H 'Content-Type: application/json' \
  -d '{
    "video_path": "/private/tmp/ane-serve-release-demo/trail-guide.mp4",
    "max_duration_sec": 180,
    "frame_interval_sec": 1.0,
    "scene_threshold": 0.2,
    "max_vlm_scenes": 3
  }' \
  --output storyboard.json
```

On an Apple M5 Max (64 GB, macOS 27.2), with the model already warm, this scan took 5.81 seconds, or 2.07× real time. Trimmed to its main fields and first scene, the response looks like this:

```json
{
  "status": "complete",
  "analyzedDurationSec": 12,
  "totalProcessingTimeSec": 5.809327006340027,
  "transcriptSegments": [
    {"startTimeSec": 0, "endTimeSec": 1.56, "text": "Welcome to the Trail Guide."},
    {"startTimeSec": 1.56, "endTimeSec": 4.98, "text": "River Trail is marked in red, Lake Trail is marked in blue."},
    {"startTimeSec": 4.98, "endTimeSec": 7.2, "text": "Both trails meet at the visitor center."}
  ],
  "scenes": [
    {
      "sceneIndex": 1,
      "timestampSec": 0,
      "ocrText": ["RIVER TRAIL", "Follow the red route"],
      "vlmDescription": "A red background with white text that reads, \"RIVER TRAIL\" and \"Follow the red route\" is visible. A blue wavy line is also present at the bottom of the frame.",
      "captionStatus": "complete"
    }
  ],
  "aneAverageFabricBandwidthGBps": 38.91730216788237,
  "cpuAveragePowerWatts": 10.807619035057922
}
```

The full, unedited response is in [`examples/video-scan/response.json`](examples/video-scan/response.json), next to the [request](examples/video-scan/request.json) and its [provenance](examples/video-scan/provenance.json): capture time, hardware, the clip's SHA-256, and the live checks that ran. Its timings and power readings describe that one run, not other hardware or workloads.

| Field | Default | Meaning |
| :--- | :--- | :--- |
| `video_path` / `video_base64` | required | A file inside the media root, or the uploaded file as base64. Provide one. |
| `format` | `mp4` | Extension of a base64 upload: `3gp`, `aac`, `aif`, `aiff`, `avi`, `caf`, `flac`, `m4a`, `m4v`, `mkv`, `mov`, `mp3`, `mp4`, `mpeg`, `mpg`, `oga`, `ogg`, `opus`, `ts`, `wav`, or `webm`. |
| `max_duration_sec` | `180` | How much of the video to scan, from the start: more than 0 and at most 3600 seconds. |
| `frame_interval_sec` | `1.0` | Seconds between sampled frames, from 0.25 to 60. Duration divided by interval can be at most 3600 frames. |
| `scene_threshold` | `0.42` | How different a frame must look to start a new scene, from 0 to 2 (Vision feature-print distance). Lower values find more scenes. |
| `max_vlm_scenes` | `8` | How many scenes get OCR and a caption, from 0 to 32. They're spread evenly across the video. `0` skips both. |

`detectedSceneCount` counts every scene candidate, including the first frame, while `scenes` holds only the ones selected for OCR and captions. `requestedDurationSec` is the window you asked for, and `analyzedDurationSec` is the part actually scanned. `status` is `complete` or `partial`, with per-stage results in `stageStatus` and failures in `warnings`. A failed caption has an empty `vlmDescription` and `captionStatus: "failed"`, and a failed summary leaves `executiveSummary` empty; error text never stands in for generated text. Bad input or a failed extraction returns an HTTP error instead of a report. The summary sees the first 2,400 characters of the transcript and up to 10 scene captions, while the report keeps the whole transcript. For uploads, `videoPath` is the server's temporary copy, which is deleted after the request. ffmpeg opens only common audio and video containers; playlists, concat lists, and text formats are rejected, because they can make it read other files on the Mac.

### From the command line

The same scan runs without the server:

```bash
.build/release/ane-serve --scan-video /Users/you/Movies/demo.mp4 60 2
```

The numbers after the file are the maximum duration in seconds and the maximum number of captioned scenes (default `180` and `8`). The report is written next to the video as `demo.mp4.ane_storyboard.json`. The exit status is `0` for a complete scan, `2` for a partial one, and `1` for an error.

## Telemetry

At startup the server reads the host's chip, memory, GPU, ANE core count, and Core AI architecture. While it runs, it samples macOS's IOReport counters (groups such as `Energy Model` and `PMP0`) without `sudo`, and reports how they changed while each request ran:

| Reading | In `ane_telemetry` | In video reports | Meaning |
| :--- | :--- | :--- | :--- |
| ANE bandwidth, average | `ane_fabric_bw_gbps` | `aneAverageFabricBandwidthGBps` | Residency-weighted bandwidth histogram labels, summed across ANE channels, in GB/s. An estimate from histogram bins, not a byte counter. |
| ANE bandwidth, peak | `ane_peak_bw_gbps` | `anePeakFabricBandwidthGBps` | Each channel's highest occupied bin, summed across channels, in GB/s. This is an upper bound on the combined peak and never falls below the average. |
| ANE overdrive | `ane_vmax_overdrive_pct` | `aneOverdriveResidencyPercent` | Residency in the ANE's reported VMAX/VOVD voltage states, in percent. |
| GPU power | `gpu_power_watts` | `gpuAveragePowerWatts` | Average GPU power, in watts. |
| CPU power | `cpu_power_watts` | `cpuAveragePowerWatts` | Average CPU power, in watts. |

Chat, image, and transcription responses carry these readings in an `ane_telemetry` object, along with `status`, `unavailable_fields`, and `host_ane`, which names the host's Neural Engine. Video reports put them at the top level, with `telemetryStatus`. `GET /v1/health` reports the readings since startup or the previous health request.

These are system-wide readings between two snapshots, so other apps and overlapping requests count too. Readings the chip doesn't provide are `null`, while a measured zero stays `0`; the status is `available`, `partial`, or `unavailable`. A very short request may see no new histogram samples. On the M5 Max used for the example, the lowest ANE bandwidth bin is 2 GB/s per channel, so even an idle ANE reads above zero. Apple's frameworks decide which processor runs each operation, and these readings don't show that any particular work ran on the ANE.

## Errors

Errors share one envelope with `message`, `type`, `param` (or `null`), and `code`. For example, an out-of-range temperature returns HTTP `400`:

```json
{
  "error": {
    "message": "'temperature' must be between 0 and 2.",
    "type": "invalid_request_error",
    "param": "temperature",
    "code": "invalid_request"
  }
}
```

Validation failures use `400`, including a path outside the media root (`code: "invalid_path"`). Missing or invalid API keys use `401`. Browser-origin access without a configured key, and path fields on a server started without `--media-root`, use `403`. Unknown routes and models use `404`, a request that stalls while it's being sent uses `408`, size limits use `413`, model rate limits use `429`, an unavailable model or a full connection limit uses `503`, and model timeouts use `504`. Context overflow returns `400` with `code: "context_length_exceeded"`.

Validation and early model failures return normal HTTP errors before a stream starts. If generation fails after the stream has begun, the stream sends the same envelope as a `data:` event, followed by `[DONE]`. The HTTP status is already `200` by then, so streaming clients should watch for error events.

## Development

`swift test` runs the unit tests, which cover request validation, path rules, HTTP handling, and telemetry parsing.

`ChatEndpoint` serves a chat request on a `Network` connection by itself. Another Swift server can compile these sources (everything but `main.swift`, with `-I Sources/CIOReport`) and hand its chat requests to it, under its own model names.

The live release checks need a Mac that meets the requirements above:

```bash
swift build -c release
swift examples/video-scan/make-demo.swift /private/tmp/ane-serve-release-demo
python3 scripts/check-release.py
```

The script starts its own server on a free localhost port, with a temporary key and the demo folder as its media root, and stops it when it's done. It checks readiness, speech setup, authentication (including refusing an unauthenticated upload before its body is sent), invalid input and path restrictions, conversation recall, token limits, streaming text and image chat, image OCR and captions, video analysis, clipping, and upload cleanup. Raw responses go to `.build/release-check/results/`, and the example in `examples/video-scan/` came from this script. A first-time speech model download hasn't been measured, because the capture Mac already had the model.

## License

[MIT](LICENSE).
