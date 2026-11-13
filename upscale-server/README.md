# Upscale server

Runs the Upscaler plugin's models on your computer instead of the phone. The phone uploads the photo, the PC
upscales it (on the GPU when one is available) and the phone downloads the result into the editor, with progress and
Cancel as usual.

## Run it

Python 3.10 or newer:

```sh
cd upscale-server
pip install -r requirements.txt     # NVIDIA: pip install onnxruntime-gpu · Windows, any GPU: pip install onnxruntime-directml
python upscale_server.py
```

It prints the addresses to use and a token:

```
Immich upscale server 1.0.0
  ONNX Runtime providers: CUDAExecutionProvider, CPUExecutionProvider
  Enter one of these in the Upscale panel (Run on: My PC):
    100.101.102.103:8765  (Tailscale)
    192.168.1.20:8765  (LAN)
  Token: 3vQ…
```

On the phone (Tailscale connected), open a photo in the editor, pick **Upscale**, set **Run on** to **My PC**, enter
the address and the token, and tap **Test connection**. The settings are remembered.

Models download from Hugging Face the first time each is used (same files and checksums as the plugin) into
`~/.immich-upscale/models`. The token is kept in `~/.immich-upscale/token`.

Options: `--host` (listen only on one address, e.g. your Tailscale IP), `--port` (default 8765), `--tile` (tile size,
default 256; lower it if the GPU runs out of memory), `--data` (folder for models and the token), `--token`.

Results are PNG. Finished jobs the phone never collects are deleted after an hour.

## Protocol

Every request needs `X-Token: <token>`.

| Request | Answer |
| --- | --- |
| `GET /health` | `{ ok, version, providers, models, busy }` |
| `POST /jobs?model=&width=&height=&denoise=` with the photo (PNG, JPEG or WebP) as the body | `{ id }` (`width`, `height`: output size) |
| `GET /jobs/<id>` | `{ state: queued \| running \| done \| failed \| cancelled, progress, message, error? }` |
| `GET /jobs/<id>/result` | the upscaled photo (PNG) |
| `DELETE /jobs/<id>` | cancels the job and deletes its files |

Jobs run one at a time.
