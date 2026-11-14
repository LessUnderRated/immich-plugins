#!/usr/bin/env python3
"""Upscale server for the Immich Upscaler plugin.

Runs the plugin's upscaling models on this computer (GPU when available) so the phone only uploads the photo and
downloads the result. The phone finds it by itself: on the same Wi-Fi it answers a discovery broadcast (UDP port 8765)
with its LAN and Tailscale addresses, which the phone remembers and uses from anywhere on your tailnet.

    pip install -r requirements.txt
    python upscale_server.py                 # listens on 0.0.0.0:8765 (HTTP and discovery)

Protocol (no authentication: only reachable from your LAN and tailnet):

    UDP    "IMMICH-UPSCALE?" to port 8765 -> {"service": "immich-upscale", "name", "port", "addresses", "version"}
    GET    /health                     -> {"ok", "version", "name", "addresses", "providers", "models": [ids], "busy"}
    POST   /jobs?model=&width=&height=&denoise=   body: the photo (PNG / JPEG / WebP)
                                       -> {"id"}          (width/height: output size in pixels)
    GET    /jobs/<id>                  -> {"state": "queued|running|done|failed|cancelled", "progress", "message",
                                           "error"?, "width"?, "height"?}
    GET    /jobs/<id>/result           -> the upscaled photo (PNG)
    DELETE /jobs/<id>                  -> cancels the job / deletes its result
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import math
import multiprocessing
import queue
import shutil
import socket
import subprocess
import sys
import threading
import time
import urllib.request
import uuid
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

VERSION = "1.1.0"
HF = "https://huggingface.co/"

# Same models (and pins) as the phone plugin.
MODELS = {
    "general": dict(url=HF + "James040/realesrganfp16-onnx-5mb/resolve/main/model.onnx",
                    sha256="ce89b494b6adad237792c31d1012d28604bb22d6cd06b8b5903713d4ed636117", scale=4, fixed=0),
    "clearreality": dict(url=HF + "yuvraj108c/ComfyUI-Upscaler-Onnx/resolve/main/4x-ClearRealityV1.onnx",
                         sha256="58381c8df79457670dbb286d36921a044c506eacfe8826bbb6aefc644826f91a", scale=4, fixed=0),
    "realesrgan": dict(url=HF + "imgdesignart/realesrgan-x4-onnx/resolve/main/onnx/model_fp16.onnx",
                       sha256="ed7e4ad8b911499dd26742c4a49dca5e25d24e8b24d00295e19a3e64fa4b85bf", scale=4, fixed=0),
    "realplksr2": dict(url=HF + "darktable-org/upscale-realplksr-onnx/resolve/main/onnx/model_x2.onnx",
                       sha256="d7abb65092f3808d3aa255ffdab42b1d672883915d90adbdd321204168b9f293", scale=2, fixed=512),
    "realplksr4": dict(url=HF + "darktable-org/upscale-realplksr-onnx/resolve/main/onnx/model_x4.onnx",
                       sha256="8ce692652494e2e5c31e1f7c7ab61eb084e9a450cde727a374f5d6746cfe054b", scale=4, fixed=256),
    "apisr2": dict(url=HF + "Xenova/2x_APISR_RRDB_GAN_generator-onnx/resolve/main/onnx/model.onnx",
                   sha256="c0c1bd343db0da03de28c5eb82c1cadfd5c77f909c9351fffda047dd116a3a24", scale=2, fixed=0),
    "apisr4": dict(url=HF + "Xenova/4x_APISR_GRL_GAN_generator-onnx/resolve/main/onnx/model.onnx",
                   sha256="fcd4116ebbfadc958e443d07a87b97494a06b2e0f6db1c3811335ba7b21edcfb", scale=4, fixed=0),
    "animesharp": dict(url=HF + "tangalbert919/upscalers-onnx/resolve/main/4x-AnimeSharp_fp16.onnx",
                       sha256="27c01a32e1d8f2c35141890577a873a13b38ed1fffa4393e8f990f16e893847e", scale=4, fixed=0),
}

IDLE_SECONDS = 120
MAX_UPLOAD = 512 * 1024 * 1024
MAX_OUTPUT_PIXELS = 256 * 1024 * 1024
PAD = 16


class Cancelled(Exception):
    pass


# ---------------------------------------------------------------------------------------------------------- models


PREFERRED_PROVIDERS = ["CUDAExecutionProvider", "DmlExecutionProvider", "CoreMLExecutionProvider",
                       "CPUExecutionProvider"]


def _pick_providers(available: list[str]) -> list[str]:
    return [p for p in PREFERRED_PROVIDERS if p in available] or available


def _probe_providers() -> list[str]:
    code = "import onnxruntime as o; print(','.join(o.get_available_providers()))"
    try:
        out = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, timeout=120).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    return _pick_providers([p for p in out.strip().split(",") if p])


class ModelStore:
    def __init__(self, cache: Path, tile: int):
        import onnxruntime as ort

        if hasattr(ort, "preload_dlls"):
            try:
                ort.preload_dlls()
            except Exception:  # noqa: BLE001 - CPU still works without the GPU libraries
                pass
        self.ort = ort
        self.cache = cache
        self.tile = tile
        self.cache.mkdir(parents=True, exist_ok=True)
        self._lock = threading.Lock()
        self._session = None
        self.providers = _pick_providers(ort.get_available_providers())

    def path(self, model_id: str, progress) -> Path:
        spec = MODELS[model_id]
        dest = self.cache / f"{model_id}.onnx"
        if dest.is_file() and _sha256(dest) == spec["sha256"]:
            return dest
        part = dest.with_suffix(".part")
        progress(0.0, f"Downloading the {model_id} model on the PC…")
        with urllib.request.urlopen(spec["url"], timeout=60) as response, open(part, "wb") as out:
            total = int(response.headers.get("Content-Length") or 0)
            done = 0
            while chunk := response.read(1 << 20):
                out.write(chunk)
                done += len(chunk)
                if total:
                    progress(0.0, f"Downloading the {model_id} model on the PC… {done >> 20} of {total >> 20} MB")
        if _sha256(part) != spec["sha256"]:
            part.unlink(missing_ok=True)
            raise RuntimeError(f"The {model_id} download is not the expected file")
        part.replace(dest)
        return dest

    def session(self, model_id: str, progress):
        ort = self.ort
        with self._lock:
            if self._session and self._session[0] == model_id:
                return self._session[1]
            path = self.path(model_id, progress)
            progress(0.0, "Loading the model…")
            options = ort.SessionOptions()
            options.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
            session = ort.InferenceSession(str(path), options, providers=self.providers)
            self._session = (model_id, session)
            return session


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(1 << 20):
            digest.update(chunk)
    return digest.hexdigest()


# ---------------------------------------------------------------------------------------------------------- engine


def _run(session, tile, denoise: float):
    """tile: HxWx3 float32 0-1 -> model output HxWx3 float32."""
    import numpy as np

    feeds = {}
    for inp in session.get_inputs():
        dtype = np.float16 if "float16" in inp.type else np.float32
        if "denoise" in inp.name.lower():
            feeds[inp.name] = np.array([denoise], dtype=dtype)
        else:
            feeds[inp.name] = np.ascontiguousarray(tile.transpose(2, 0, 1)[None]).astype(dtype)
    out = session.run(None, feeds)[0][0]
    return out.astype(np.float32).transpose(1, 2, 0)


def _pass(session, spec, src, dw: int, dh: int, denoise: float, tile: int, report):
    """One model pass over src (HxWx3 float32) straight to a dh x dw x 3 uint8 image (each tile's output is resampled
    to the destination size, so any scale up to the model's works in one pass)."""
    import numpy as np
    from PIL import Image

    sh, sw = src.shape[:2]
    m = spec["scale"]
    fixed = spec["fixed"]
    core = fixed - 2 * PAD if fixed else tile
    out = np.zeros((dh, dw, 3), dtype=np.uint8)
    tiles_x = math.ceil(sw / core)
    tiles_y = math.ceil(sh / core)
    count = tiles_x * tiles_y
    started = time.time()
    index = 0
    for ty in range(tiles_y):
        for tx in range(tiles_x):
            x0, y0 = tx * core, ty * core
            x1, y1 = min(sw, x0 + core), min(sh, y0 + core)
            px0, py0 = max(0, x0 - PAD), max(0, y0 - PAD)
            px1, py1 = min(sw, x1 + PAD), min(sh, y1 + PAD)
            patch = src[py0:py1, px0:px1]
            if fixed:
                patch = np.pad(patch, ((0, fixed - patch.shape[0]), (0, fixed - patch.shape[1]), (0, 0)), mode="edge")
            result = _run(session, patch, denoise)
            # the core of this tile, at the model's scale
            cx0, cy0 = (x0 - px0) * m, (y0 - py0) * m
            core_img = result[cy0:cy0 + (y1 - y0) * m, cx0:cx0 + (x1 - x0) * m]
            dx0, dx1 = x0 * dw // sw, x1 * dw // sw
            dy0, dy1 = y0 * dh // sh, y1 * dh // sh
            if dx1 > dx0 and dy1 > dy0:
                img = Image.fromarray((np.clip(core_img, 0, 1) * 255 + 0.5).astype(np.uint8))
                if img.size != (dx1 - dx0, dy1 - dy0):
                    img = img.resize((dx1 - dx0, dy1 - dy0), Image.Resampling.BOX)
                out[dy0:dy1, dx0:dx1] = np.asarray(img)
            index += 1
            elapsed = time.time() - started
            eta = ""
            if 2 <= index < count:
                left = elapsed * (count - index) / index
                eta = f" · about {round(left / 60)} min left" if left >= 60 else f" · about {max(1, round(left))} s left"
            report(index / count, f"Tile {index} of {count}{eta}")
    return out


def upscale(store: ModelStore, model_id: str, image, dw: int, dh: int, denoise: float, report):
    import numpy as np
    from PIL import Image

    spec = MODELS[model_id]
    session = store.session(model_id, report)
    alpha = image.getchannel("A") if image.mode in ("RGBA", "LA") else None
    if alpha is not None and alpha.getextrema() == (255, 255):
        alpha = None
    current = np.asarray(image.convert("RGB"), dtype=np.float32) / 255.0
    sw, sh = image.size
    target = max(dw / sw, dh / sh)
    passes = 1
    reach = spec["scale"]
    while reach + 1e-9 < target:
        reach *= spec["scale"]
        passes += 1
    work = [(sw * sh) * (spec["scale"] ** (2 * i)) for i in range(passes)]
    total = sum(work)
    done = 0
    for p in range(passes):
        h, w = current.shape[:2]
        last = p == passes - 1
        tw, th = (dw, dh) if last else (w * spec["scale"], h * spec["scale"])
        base, span = done / total, work[p] / total
        label = f"Pass {p + 1} of {passes}: " if passes > 1 else ""
        result = _pass(session, spec, current, tw, th, denoise, store.tile,
                       lambda f, msg: report(base + span * f, label + msg))
        done += work[p]
        current = result if last else result.astype(np.float32) / 255.0
    out = Image.fromarray(current)
    if alpha is not None:
        out.putalpha(alpha.resize((dw, dh), Image.Resampling.BICUBIC))
    return out


# ---------------------------------------------------------------------------------------------------------- jobs


@dataclass
class Job:
    id: str
    model: str
    width: int
    height: int
    denoise: float
    source: Path
    state: str = "queued"
    progress: float = 0.0
    message: str = "Waiting on the PC…"
    error: str | None = None
    result: Path | None = None
    cancel: threading.Event = field(default_factory=threading.Event)
    finished_at: float | None = None

    def json(self):
        data = {"id": self.id, "state": self.state, "progress": round(self.progress, 4), "message": self.message}
        if self.error:
            data["error"] = self.error
        if self.state == "done":
            data.update(width=self.width, height=self.height)
        return data


@dataclass
class EngineConfig:
    cache: Path
    tile: int
    providers: list[str] = field(default_factory=list)


def _engine_main(config: EngineConfig, tasks, events, cancel):
    store = ModelStore(config.cache, config.tile)
    from PIL import Image

    while True:
        task = tasks.get()
        if task is None:
            return
        job_id, model, width, height, denoise, source, result = task
        cancel.clear()

        def report(fraction, message, job_id=job_id):
            if cancel.is_set():
                raise Cancelled()
            events.put(("progress", job_id, max(0.0, min(1.0, fraction)), message))

        try:
            with Image.open(source) as image:
                image.load()
                upscaled = upscale(store, model, image, width, height, denoise, report)
            report(1.0, "Encoding the result…")
            upscaled.save(result, format="PNG", compress_level=3)
            events.put(("done", job_id, None, None))
        except Cancelled:
            events.put(("cancelled", job_id, None, None))
        except Exception as error:  # noqa: BLE001 - reported to the phone
            events.put(("failed", job_id, None, str(error) or error.__class__.__name__))


class _Engine:
    def __init__(self, config: EngineConfig):
        context = multiprocessing.get_context("spawn")
        self.tasks = context.Queue()
        self.events = context.Queue()
        self.cancel = context.Event()
        self.process = context.Process(target=_engine_main, args=(config, self.tasks, self.events, self.cancel),
                                       daemon=True)
        self.process.start()

    def alive(self) -> bool:
        return self.process.is_alive()

    def run(self, job: Job, result: Path) -> tuple[str, str | None]:
        self.tasks.put((job.id, job.model, job.width, job.height, job.denoise, str(job.source), str(result)))
        while True:
            if job.cancel.is_set():
                self.cancel.set()
            try:
                kind, job_id, fraction, detail = self.events.get(timeout=0.5)
            except queue.Empty:
                if not self.process.is_alive():
                    return "crashed", None
                continue
            if job_id != job.id:
                continue
            if kind == "progress":
                job.progress = fraction
                job.message = detail
                continue
            return kind, detail

    def stop(self):
        if self.process.is_alive():
            self.tasks.put(None)
            self.process.join(timeout=10)
        if self.process.is_alive():
            self.process.terminate()
            self.process.join(timeout=5)


class Jobs:
    def __init__(self, store: EngineConfig, work_dir: Path, idle: float = IDLE_SECONDS):
        self.store = store
        self.work_dir = work_dir
        self.idle = idle
        self.jobs: dict[str, Job] = {}
        self.queue: queue.Queue[Job] = queue.Queue()
        self.lock = threading.Lock()
        threading.Thread(target=self._worker, daemon=True).start()
        threading.Thread(target=self._janitor, daemon=True).start()

    def add(self, job: Job):
        with self.lock:
            self.jobs[job.id] = job
        self.queue.put(job)

    def get(self, job_id: str) -> Job | None:
        with self.lock:
            return self.jobs.get(job_id)

    def remove(self, job_id: str):
        with self.lock:
            job = self.jobs.pop(job_id, None)
        if job:
            job.cancel.set()
            if job.state in ("queued", "running"):
                job.state = "cancelled"
            self._cleanup(job)

    @property
    def busy(self) -> bool:
        with self.lock:
            return any(j.state == "running" for j in self.jobs.values())

    def _cleanup(self, job: Job):
        for path in (job.source, job.result):
            if path:
                path.unlink(missing_ok=True)

    def _worker(self):
        engine: _Engine | None = None
        while True:
            try:
                job = self.queue.get(timeout=self.idle)
            except queue.Empty:
                if engine:
                    engine.stop()
                    engine = None
                continue
            if job.cancel.is_set():
                continue
            if engine is None or not engine.alive():
                engine = _Engine(self.store)
            job.state = "running"
            self.work_dir.mkdir(parents=True, exist_ok=True)
            result = self.work_dir / f"{job.id}-result.png"
            try:
                outcome, detail = engine.run(job, result)
            finally:
                job.source.unlink(missing_ok=True)
            if outcome == "done":
                job.result = result
                job.state = "done"
                job.progress = 1.0
                job.message = "Done"
            elif outcome == "cancelled":
                result.unlink(missing_ok=True)
                job.state = "cancelled"
                job.message = "Cancelled"
            else:
                result.unlink(missing_ok=True)
                job.state = "failed"
                job.error = detail or "The upscale worker stopped"
                job.message = "Failed"
                print(f"[job {job.id}] failed: {job.error}", file=sys.stderr)
            if outcome == "crashed":
                engine.stop()
                engine = None
            job.finished_at = time.time()

    def _janitor(self):
        # finished jobs the phone never fetched are dropped after an hour
        while True:
            time.sleep(300)
            now = time.time()
            with self.lock:
                stale = [j for j in self.jobs.values() if j.finished_at and now - j.finished_at > 3600]
            for job in stale:
                self.remove(job.id)


# ---------------------------------------------------------------------------------------------------------- http


def make_handler(jobs: Jobs, port: int):
    class Handler(BaseHTTPRequestHandler):
        server_version = f"ImmichUpscale/{VERSION}"

        def log_message(self, fmt, *args):
            if not self.path.startswith("/jobs/") or self.command != "GET":
                sys.stderr.write(f"{self.address_string()} {fmt % args}\n")

        def _json(self, status: int, data: dict):
            body = json.dumps(data).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            url = urlparse(self.path)
            parts = [p for p in url.path.split("/") if p]
            if parts == ["health"]:
                return self._json(200, {"ok": True, "version": VERSION, "name": socket.gethostname(),
                                        "addresses": _addresses(port), "providers": jobs.store.providers,
                                        "models": list(MODELS), "busy": jobs.busy})
            if len(parts) >= 2 and parts[0] == "jobs":
                job = jobs.get(parts[1])
                if job is None:
                    return self._json(404, {"error": "no such job"})
                if len(parts) == 2:
                    return self._json(200, job.json())
                if parts[2] == "result":
                    if job.state != "done" or job.result is None:
                        return self._json(409, {"error": f"job is {job.state}"})
                    size = job.result.stat().st_size
                    self.send_response(200)
                    self.send_header("Content-Type", "image/png")
                    self.send_header("Content-Length", str(size))
                    self.end_headers()
                    with open(job.result, "rb") as f:
                        shutil.copyfileobj(f, self.wfile, 1 << 20)
                    return
            self._json(404, {"error": "not found"})

        def do_POST(self):
            url = urlparse(self.path)
            if url.path.rstrip("/") != "/jobs":
                return self._json(404, {"error": "not found"})
            q = {k: v[0] for k, v in parse_qs(url.query).items()}
            model = q.get("model", "general")
            if model not in MODELS:
                return self._json(400, {"error": f"unknown model {model}"})
            try:
                width, height = int(q["width"]), int(q["height"])
                denoise = float(q.get("denoise", 0.5))
            except (KeyError, ValueError):
                return self._json(400, {"error": "width and height are required"})
            if width <= 0 or height <= 0 or width * height > MAX_OUTPUT_PIXELS:
                return self._json(400, {"error": "output size out of range"})
            length = int(self.headers.get("Content-Length") or 0)
            if length <= 0 or length > MAX_UPLOAD:
                return self._json(400, {"error": "missing or too large upload"})
            job_id = uuid.uuid4().hex
            jobs.work_dir.mkdir(parents=True, exist_ok=True)
            source = jobs.work_dir / f"{job_id}-source"
            with open(source, "wb") as out:
                left = length
                while left > 0:
                    chunk = self.rfile.read(min(1 << 20, left))
                    if not chunk:
                        break
                    out.write(chunk)
                    left -= len(chunk)
            if left > 0:
                source.unlink(missing_ok=True)
                return self._json(400, {"error": "upload cut short"})
            jobs.add(Job(job_id, model, width, height, denoise, source))
            self._json(200, {"id": job_id})

        def do_DELETE(self):
            parts = [p for p in urlparse(self.path).path.split("/") if p]
            if len(parts) == 2 and parts[0] == "jobs":
                jobs.remove(parts[1])
                return self._json(200, {"ok": True})
            self._json(404, {"error": "not found"})

    return Handler


def _addresses(port: int) -> list[str]:
    """This computer's reachable addresses as host:port, Tailscale first."""
    found = []
    try:
        ips = subprocess.run(["tailscale", "ip", "-4"], capture_output=True, text=True, timeout=5).stdout.split()
        found += [f"{ip}:{port}" for ip in ips]
    except (OSError, subprocess.SubprocessError):
        pass
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("10.255.255.255", 1))
            lan = s.getsockname()[0]
            if not lan.startswith("127.") and f"{lan}:{port}" not in found:
                found.append(f"{lan}:{port}")
    except OSError:
        pass
    return found


def _discovery(host: str, port: int, listen_port: int):
    """Answers the plugin's discovery broadcast ("IMMICH-UPSCALE?") on UDP [listen_port] with HTTP [port]."""
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind((host, listen_port))
    except OSError as error:
        print(f"  Discovery is off (UDP {listen_port}: {error}); the phone needs the address once.", file=sys.stderr)
        return
    while True:
        try:
            data, sender = sock.recvfrom(1024)
            if data.strip().startswith(b"IMMICH-UPSCALE?"):
                reply = {"service": "immich-upscale", "name": socket.gethostname(), "port": port,
                         "addresses": _addresses(port), "version": VERSION}
                sock.sendto(json.dumps(reply).encode(), sender)
        except OSError:
            time.sleep(1)


def main():
    parser = argparse.ArgumentParser(description="Upscale server for the Immich Upscaler plugin")
    parser.add_argument("--host", default="0.0.0.0", help="address to listen on (default: all; e.g. your Tailscale IP)")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--discovery-port", type=int, help="UDP port for discovery (default: --port)")
    parser.add_argument("--data", default=str(Path.home() / ".immich-upscale"), help="models and work files")
    parser.add_argument("--tile", type=int, default=256, help="tile size for models that take any size")
    parser.add_argument("--idle", type=float, default=IDLE_SECONDS,
                        help="seconds without jobs before the models are unloaded (default 120)")
    args = parser.parse_args()

    data = Path(args.data)
    data.mkdir(parents=True, exist_ok=True)
    work = data / "work"
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True, exist_ok=True)

    store = EngineConfig(data / "models", args.tile, _probe_providers())
    jobs = Jobs(store, work, args.idle)
    server = ThreadingHTTPServer((args.host, args.port), make_handler(jobs, args.port))
    threading.Thread(target=_discovery, args=(args.host, args.port, args.discovery_port or args.port),
                     daemon=True).start()
    print(f"Immich upscale server {VERSION} on {socket.gethostname()}")
    print(f"  ONNX Runtime providers: {', '.join(store.providers)}")
    print(f"  Addresses: {', '.join(_addresses(args.port)) or f'port {args.port}'}")
    print("  On the phone: Settings > Plugins > Upscaler, enter the Tailscale address above, Test connection.")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
