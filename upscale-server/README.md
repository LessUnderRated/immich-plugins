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

It prints its name, the ONNX Runtime provider (GPU or CPU) and its addresses. There is nothing to enter on the phone:
in the editor pick **Upscale**, set **Run on** to **My PC**, and the plugin finds the PC by itself. The first time,
the phone has to be on the same Wi-Fi as the PC (it finds it with a broadcast on UDP port 8765); the PC answers with
its Tailscale address too, so afterwards it is found from anywhere while Tailscale is on. **Find my PC** in the panel
searches again; only if it never finds it does the panel offer an address field.

Models download from Hugging Face the first time each is used (same files and checksums as the plugin) into
`~/.immich-upscale/models`.

Options: `--host` (listen only on one address), `--port` (default 8765, HTTP and discovery), `--tile` (tile size,
default 256; lower it if the GPU runs out of memory), `--data` (folder for the models).

There is no password: the server is only reachable from your own network and tailnet. Allow TCP and UDP port 8765 in
the PC's firewall for the LAN and Tailscale.

Results are PNG. Finished jobs the phone never collects are deleted after an hour.

## Protocol

| Request | Answer |
| --- | --- |
| UDP `IMMICH-UPSCALE?` to port 8765 | `{ service: "immich-upscale", name, port, addresses, version }` |
| `GET /health` | `{ ok, version, name, addresses, providers, models, busy }` |
| `POST /jobs?model=&width=&height=&denoise=` with the photo (PNG, JPEG or WebP) as the body | `{ id }` (`width`, `height`: output size) |
| `GET /jobs/<id>` | `{ state: queued \| running \| done \| failed \| cancelled, progress, message, error? }` |
| `GET /jobs/<id>/result` | the upscaled photo (PNG) |
| `DELETE /jobs/<id>` | cancels the job and deletes its files |

Jobs run one at a time.
