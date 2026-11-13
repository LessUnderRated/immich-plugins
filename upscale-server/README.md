# Upscale server

Runs the Upscaler plugin's models on your computer (the plugin has no on-phone engine). The phone uploads the photo, the PC
upscales it (on the GPU when one is available) and the phone downloads the result into the editor, with progress and
Cancel as usual.

## Run it

Python 3.10 or newer:

```sh
cd upscale-server
pip install -r requirements.txt     # NVIDIA: pip install onnxruntime-gpu · Windows, any GPU: pip install onnxruntime-directml
python upscale_server.py
```

It prints its name, the ONNX Runtime provider (GPU or CPU) and its addresses (Tailscale first).

On the phone, open **Settings > Plugins > Upscaler**, enter the PC's Tailscale address (or its Tailscale name) and tap
**Test connection**. On the same Wi-Fi, **Find on this Wi-Fi** fills it in (it also learns the Tailscale address). Then
in the editor pick **Upscale**: model, output size, **Upscale**.

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
