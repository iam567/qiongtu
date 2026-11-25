#!/usr/bin/env python3
"""穷图 AI 模拟服务器：按 8 家服务商的接口格式回一张"改过"的图，只用 Python 标准库。

    python3 tools/mock-ai/server.py            # 监听 0.0.0.0:8765

各家的 Base URL 见同目录 README.md。不发任何真实请求，不打印 Authorization / Key。
"""
import base64
import json
import os
import re
import struct
import sys
import threading
import time
import uuid
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

PORT = int(os.environ.get("MOCK_AI_PORT", "8765"))

# 下载地址和异步任务（千问、FLUX、自定义的 url 返回用）
FILES = {}
TASKS = {}
LOCK = threading.Lock()


# ---------- 图片处理 ----------

def png_chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)


def png_encode(w, h, rows, color_type):
    """rows: 每行不带滤波字节的原始像素（bytes）。"""
    raw = b"".join(b"\x00" + r for r in rows)
    ihdr = struct.pack(">IIBBBBB", w, h, 8, color_type, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + png_chunk(b"IHDR", ihdr) + png_chunk(b"IDAT", zlib.compress(raw, 6)) + png_chunk(b"IEND", b"")


def png_decode(data):
    """解 8 位、不隔行的灰度 / RGB / 灰度+透明 / RGBA PNG。返回 (w, h, 每像素字节数, color_type, 行列表)。"""
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not png")
    pos, idat, w = 8, [], None
    while pos < len(data):
        n = struct.unpack(">I", data[pos:pos + 4])[0]
        kind = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + n]
        if kind == b"IHDR":
            w, h, depth, ctype, _, _, interlace = struct.unpack(">IIBBBBB", body)
            if depth != 8 or interlace != 0 or ctype not in (0, 2, 4, 6):
                raise ValueError("unsupported png")
        elif kind == b"IDAT":
            idat.append(body)
        elif kind == b"IEND":
            break
        pos += 12 + n
    bpp = {0: 1, 2: 3, 4: 2, 6: 4}[ctype]
    raw = zlib.decompress(b"".join(idat))
    stride = w * bpp
    prev = bytearray(stride)
    rows = []
    i = 0
    for _ in range(h):
        f = raw[i]
        line = bytearray(raw[i + 1:i + 1 + stride])
        i += 1 + stride
        if f == 1:
            for x in range(bpp, stride):
                line[x] = (line[x] + line[x - bpp]) & 255
        elif f == 2:
            line = bytearray((a + b) & 255 for a, b in zip(line, prev))
        elif f == 3:
            for x in range(stride):
                left = line[x - bpp] if x >= bpp else 0
                line[x] = (line[x] + ((left + prev[x]) >> 1)) & 255
        elif f == 4:
            for x in range(stride):
                a = line[x - bpp] if x >= bpp else 0
                b = prev[x]
                c = prev[x - bpp] if x >= bpp else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pred = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                line[x] = (line[x] + pred) & 255
        rows.append(bytes(line))
        prev = line
    return w, h, bpp, ctype, rows


INVERT = bytes(255 - v for v in range(256))


def edit_png(data):
    """PNG：颜色反相（透明通道不动），左上角再盖一块橙色。"""
    w, h, bpp, ctype, rows = png_decode(data)
    color = 3 if ctype == 6 else (1 if ctype == 4 else bpp)
    block = max(8, min(w, h) // 8)
    orange = {1: b"\xb0", 3: b"\xff\xad\x42"}[color] + (b"\xff" if bpp > color else b"")
    out = []
    for y, row in enumerate(rows):
        r = bytearray(row)
        for c in range(color):
            r[c::bpp] = r[c::bpp].translate(INVERT)
        if y < block:
            r[:block * bpp] = orange * block
        out.append(bytes(r))
    return png_encode(w, h, out, ctype)


def jpeg_size(data):
    i = 2
    while i < len(data) - 9:
        if data[i] != 0xFF:
            i += 1
            continue
        marker = data[i + 1]
        if marker in (0xD8, 0x01) or 0xD0 <= marker <= 0xD7:
            i += 2
            continue
        n = struct.unpack(">H", data[i + 2:i + 4])[0]
        if marker in (0xC0, 0xC1, 0xC2):
            h, w = struct.unpack(">HH", data[i + 5:i + 9])
            return w, h
        i += 2 + n
    return None


def edit_jpeg(data):
    """JPEG：不解码，直接改量化表——色度表 ×3（颜色浓得很明显），亮度表的直流项 ×0.7（整体发灰）。"""
    data = bytearray(data)
    chroma_tables = set()
    i = 2
    dqts = []
    while i < len(data) - 4:
        if data[i] != 0xFF:
            break
        marker = data[i + 1]
        if marker == 0xDA:  # 扫描数据开始，后面不再有表
            break
        n = struct.unpack(">H", data[i + 2:i + 4])[0]
        if marker == 0xDB:
            dqts.append((i + 4, i + 2 + n))
        elif marker in (0xC0, 0xC1, 0xC2):
            comps = data[i + 9]
            for k in range(comps):
                cid, _, tq = data[i + 10 + k * 3:i + 13 + k * 3]
                if k > 0:
                    chroma_tables.add(tq)
        i += 2 + n
    for start, end in dqts:
        p = start
        while p < end:
            pq, tq = data[p] >> 4, data[p] & 15
            size = 2 if pq else 1
            for k in range(64):
                q = p + 1 + k * size
                v = struct.unpack(">H", data[q:q + 2])[0] if pq else data[q]
                if tq in chroma_tables:
                    v = v * 3
                elif k == 0:
                    v = max(1, int(v * 0.7))
                v = min(v, 65535 if pq else 255)
                if pq:
                    data[q:q + 2] = struct.pack(">H", v)
                else:
                    data[q] = v
            p += 1 + 64 * size
    return bytes(data)


def edit_image(data):
    """返回 (改过的图, mime, 宽, 高)。"""
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        out = edit_png(data)
        w, h = struct.unpack(">II", data[16:24])
        return out, "image/png", w, h
    if data[:2] == b"\xff\xd8":
        size = jpeg_size(data) or (1024, 1024)
        return edit_jpeg(data), "image/jpeg", size[0], size[1]
    raise ValueError("看不懂的图片格式")


def generate_png(w, h, transparent=False):
    """文生图：竖向渐变；要透明背景时画一个橙色圆，四周透明。"""
    w, h = max(16, min(w, 4096)), max(16, min(h, 4096))
    rows = []
    if transparent:
        cx, cy, r = w / 2, h / 2, min(w, h) * 0.4
        clear = b"\x00\x00\x00\x00"
        fill = b"\xff\xad\x42\xff"
        for y in range(h):
            dy = y + 0.5 - cy
            if abs(dy) >= r:
                rows.append(clear * w)
                continue
            half = int((r * r - dy * dy) ** 0.5)
            x0, x1 = int(cx - half), int(cx + half)
            rows.append(clear * x0 + fill * (x1 - x0) + clear * (w - x1))
        return png_encode(w, h, rows, 6)
    for y in range(h):
        t = y / max(h - 1, 1)
        px = bytes((int(255 * (1 - t) + 40 * t), int(173 * (1 - t) + 60 * t), int(66 * (1 - t) + 160 * t)))
        rows.append(px * w)
    return png_encode(w, h, rows, 2)


def ratio_size(ratio, long_side=1024):
    try:
        a, b = (int(v) for v in ratio.split(":"))
    except Exception:
        return 1024, 1024
    if a >= b:
        return long_side, max(16, long_side * b // a)
    return max(16, long_side * a // b), long_side


def parse_size(text, sep="x"):
    m = re.match(r"^\s*(\d+)\s*[%s]\s*(\d+)\s*$" % re.escape(sep), str(text or ""))
    return (int(m.group(1)), int(m.group(2))) if m else None


def from_data_uri(value):
    if not isinstance(value, str):
        return None
    if value.startswith("data:") and "," in value:
        value = value.split(",", 1)[1]
    try:
        return base64.b64decode(value, validate=False)
    except Exception:
        return None


# ---------- 请求处理 ----------

def parse_multipart(body, content_type):
    m = re.search(r'boundary="?([^";]+)"?', content_type)
    if not m:
        return {}, []
    boundary = b"--" + m.group(1).encode()
    fields, files = {}, []
    for part in body.split(boundary)[1:]:
        if part.startswith(b"--"):
            break
        part = part.lstrip(b"\r\n")
        head, _, value = part.partition(b"\r\n\r\n")
        if value.endswith(b"\r\n"):
            value = value[:-2]
        headers = head.decode("utf-8", "replace")
        name = re.search(r'name="([^"]*)"', headers)
        if not name:
            continue
        if "filename=" in headers:
            files.append((name.group(1), value))
        else:
            fields[name.group(1)] = value.decode("utf-8", "replace")
    return fields, files


class Handler(BaseHTTPRequestHandler):
    server_version = "XiuTuMockAI/1.0"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # 默认日志会带上请求行以外的东西，这里自己打
        pass

    def log(self, provider, prompt=""):
        p = (prompt or "").replace("\n", " ")
        # MOCK_AI_FULL=1 时打出完整指令（查拼接出来的指令对不对）
        if not os.environ.get("MOCK_AI_FULL"):
            p = p[:60]
        print(f"{time.strftime('%H:%M:%S')} {self.command} {self.path.split('?')[0]} [{provider}] {p}", flush=True)

    # 工具

    def host_url(self):
        return "http://" + (self.headers.get("Host") or f"127.0.0.1:{PORT}")

    def send_json(self, status, obj):
        data = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def send_bytes(self, data, mime):
        self.send_response(200)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n > 0 else b""

    def has_key(self):
        auth = self.headers.get("Authorization") or ""
        key = auth[7:] if auth.lower().startswith("bearer ") else ""
        key = key or self.headers.get("x-key") or self.headers.get("x-goog-api-key") or ""
        return key.strip() not in ("", "bad")

    def store(self, data, mime):
        fid = uuid.uuid4().hex
        with LOCK:
            FILES[fid] = (data, mime)
        ext = "png" if mime == "image/png" else "jpg"
        return f"{self.host_url()}/files/{fid}.{ext}"

    def provider(self):
        # /qwen-intl、/doubao-byteplus 这类带地域后缀的前缀也认（App 按地址里的 -intl / byteplus 判断海外价目）
        first = self.path.lstrip("/").split("/", 1)[0].split("?")[0].split("-")[0]
        known = ("openai", "gemini", "minimax", "grok", "qwen", "doubao", "flux", "custom")
        if first in known:
            return first
        # 没写服务商前缀时按路径猜
        if "/interactions" in self.path:
            return "gemini"
        if "/services/aigc/" in self.path:
            return "qwen"
        if "/image-generation-models" in self.path:
            return "grok"
        return "openai"

    def denied(self):
        self.send_json(401, {"error": {"message": "Incorrect API key provided.", "code": "invalid_api_key"}})

    def bad_param(self, provider, what):
        """测试连接发的空请求走这里：参数不对，但 Key 算是被接受了。"""
        if provider == "qwen":
            self.send_json(400, {"code": "InvalidParameter", "message": f"{what} is required", "request_id": uuid.uuid4().hex})
        elif provider == "flux":
            self.send_json(422, {"detail": [{"loc": ["body", what], "msg": "Field required", "type": "missing"}]})
        elif provider == "grok":
            self.send_json(400, {"code": "invalid_argument", "error": f"missing field `{what}`"})
        else:
            self.send_json(400, {"error": {"message": f"Missing required parameter: '{what}'.", "type": "invalid_request_error", "param": what, "code": "missing_required_parameter"}})

    # GET

    def do_GET(self):
        u = urlparse(self.path)
        path = u.path
        if path.startswith("/files/"):
            fid = path[len("/files/"):].split(".")[0]
            item = FILES.get(fid)
            self.log("download")
            if not item:
                return self.send_json(404, {"error": {"message": "file not found"}})
            return self.send_bytes(*item)
        provider = self.provider()
        if path.endswith("/get_result") and provider == "flux":
            return self.flux_poll(parse_qs(u.query).get("id", [""])[0])
        self.log(provider)
        if not self.has_key():
            return self.denied()
        if path.endswith("/models") and provider == "gemini":
            return self.send_json(200, {"models": [
                {"name": "models/gemini-nano-banana-2.1"}, {"name": "models/gemini-3-pro-image"},
                {"name": "models/gemini-3.1-flash-image"}, {"name": "models/gemini-3.1-flash-lite-image"},
                {"name": "models/gemini-2.5-flash-image"}, {"name": "models/gemini-3-pro"},
            ]})
        if path.endswith("/models"):
            ids = ["gpt-image-2.6-sunburst", "gpt-image-2.6-flare", "gpt-image-2.5-sunburst", "gpt-image-2.5-flare", "gpt-image-2", "gpt-5.2"]
            if provider == "custom":
                ids = ["mock-image-1", "mock-image-2"]
            return self.send_json(200, {"object": "list", "data": [{"id": i, "object": "model"} for i in ids]})
        if path.endswith("/image-generation-models"):
            return self.send_json(200, {"models": [{"id": "grok-imagine-image-2.0"}, {"id": "grok-imagine-image"}]})
        self.send_json(404, {"error": {"message": f"not found: {path}"}})

    # POST

    def do_POST(self):
        provider = self.provider()
        path = urlparse(self.path).path
        raw = self.body()
        ctype = self.headers.get("Content-Type") or ""
        if not self.has_key():
            self.log(provider)
            return self.denied()
        try:
            if "multipart/form-data" in ctype:
                return self.openai_multipart(provider, raw, ctype)
            body = json.loads(raw or b"{}")
            if path.endswith("/chat/completions"):
                return self.look(provider, body)
            if provider == "gemini" or path.endswith("/interactions"):
                return self.gemini(body)
            if provider == "qwen" or "/services/aigc/" in path:
                return self.qwen(body)
            if provider == "flux":
                return self.flux_submit(path.rsplit("/", 1)[-1], body)
            if provider == "doubao":
                return self.doubao(body)
            if provider == "grok":
                return self.grok(path, body)
            return self.openai_json(provider, path, body)
        except Exception as e:  # 模拟服务器自己出错
            self.log(provider, f"出错：{e}")
            return self.send_json(500, {"error": {"message": f"mock server error: {e}", "type": "server_error"}})

    def moderated(self, provider, prompt):
        """指令里写 #审核 就模拟一次内容审核拒绝。"""
        if "#审核" not in (prompt or ""):
            return False
        if provider == "qwen":
            self.send_json(400, {"code": "DataInspectionFailed", "message": "Input data may contain inappropriate content."})
        elif provider == "grok":
            self.send_json(400, {"code": "content_moderation", "error": "Generated image rejected by content moderation."})
        else:
            self.send_json(400, {"error": {"message": "Your request was rejected by the safety system.", "code": "moderation_blocked",
                                           "moderation_details": {"moderation_stage": "input", "categories": ["sexual"]}}})
        return True

    CROPS = [
        {"title": "左上安静", "how": "留白", "why": "大片留白里有一个重心", "box": [40, 60, 520, 470]},
        {"title": "中间特写", "how": "居中", "why": "细节清楚，背景干净", "box": [380, 350, 640, 680]},
        {"title": "横幅全景", "how": "三分法", "why": "视线从左走到右", "box": [0, 420, 1000, 960]},
        {"title": "竖幅", "how": "引导线", "why": "线条往上走", "box": [560, 40, 900, 720]},
        {"title": "方形", "how": "对称", "why": "左右平衡", "box": [200, 200, 800, 800]},
        {"title": "重复的框", "how": "对称", "why": "应该被去重", "box": [205, 205, 800, 800]},
    ]

    def look_text(self, prompt):
        """看图的回答：智能构图要 crops，找脸要 faces。"""
        if "faces" in prompt:
            data = {"faces": [{"box": [420, 180, 560, 360]}]}
            if "desc" in prompt:
                data["desc"] = "head upright, facing the camera, eyes open, calm expression, straight bangs"
        else:
            data = {"crops": self.CROPS}
        return "<think>先看看 {画面}</think>\n```json\n" + json.dumps(data, ensure_ascii=False) + "\n```"

    def look(self, provider, body):
        """看图回文字（智能构图）：夹一段思考和代码块，测 App 的解析。第一个型号假装没有，测换型号。"""
        parts = body["messages"][0]["content"]
        prompt = next(p["text"] for p in parts if p["type"] == "text")
        has_image = any(p["type"] == "image_url" and p["image_url"]["url"].startswith("data:image/jpeg;base64,") for p in parts)
        self.log(provider, f"[看图 {body.get('model')} 图={has_image}] " + prompt[:400])
        if body.get("model") == "gpt-6.1-terra":
            return self.send_json(404, {"error": {"message": "The model `gpt-6.1-terra` does not exist", "code": "model_not_found"}})
        self.send_json(200, {"choices": [{"message": {"role": "assistant", "content": self.look_text(prompt)}}],
                             "usage": {"prompt_tokens": 2310, "completion_tokens": 640, "total_tokens": 2950}})

    def openai_multipart(self, provider, raw, ctype):
        fields, files = parse_multipart(raw, ctype)
        prompt = fields.get("prompt", "")
        self.log(provider, prompt)
        if not prompt:
            return self.bad_param(provider, "prompt")
        if self.moderated(provider, prompt):
            return
        images = [v for k, v in files if k in ("image[]", "image")]
        if not images:
            return self.bad_param(provider, "image")
        out, mime, w, h = edit_image(images[0])
        item = {"b64_json": base64.b64encode(out).decode()}
        if provider == "custom":  # 自定义服务只给下载地址，顺便测下载这条路
            item = {"url": self.store(out, mime)}
        self.send_json(200, {"created": int(time.time()), "data": [item], "usage": {
            "input_tokens": 50 + 1000 * len(images), "input_tokens_details": {"text_tokens": 50, "image_tokens": 1000 * len(images)},
            "output_tokens": 4160, "total_tokens": 4210 + 1000 * len(images)}})

    def openai_json(self, provider, path, body):
        """OpenAI / 自定义 / MiniMax 的 JSON 请求：/images/generations 和 MiniMax 的 /images/edits。"""
        prompt = body.get("prompt", "")
        self.log(provider, prompt)
        if not prompt:
            return self.bad_param(provider, "prompt")
        if self.moderated(provider, prompt):
            return
        if path.endswith("/images/edits"):
            refs = [from_data_uri(i.get("image_url")) for i in body.get("images", []) if isinstance(i, dict)]
            refs = [r for r in refs if r]
            if not refs:
                return self.bad_param(provider, "images")
            out, mime, _, _ = edit_image(refs[0])
            n_in = len(refs)
        else:
            size = parse_size(body.get("size")) or (1024, 1024)
            out, mime = generate_png(size[0], size[1], body.get("background") == "transparent"), "image/png"
            n_in = 0
        item = {"url": self.store(out, mime)} if provider == "custom" else {"b64_json": base64.b64encode(out).decode()}
        self.send_json(200, {"created": int(time.time()), "data": [item], "usage": {
            "input_tokens": 40 + 900 * n_in, "input_tokens_details": {"text_tokens": 40, "image_tokens": 900 * n_in},
            "output_tokens": 3000}})

    def grok(self, path, body):
        prompt = body.get("prompt", "")
        self.log("grok", prompt + (f"  (resolution={body['resolution']})" if "resolution" in body else ""))
        if not prompt:
            return self.bad_param("grok", "prompt")
        if self.moderated("grok", prompt):
            return
        # 旧型号不认 2k：模拟一次 400，App 应该去掉 resolution 再发一次
        if "resolution" in body and body.get("model") == "grok-imagine-image":
            return self.send_json(400, {"code": "invalid_argument", "error": "resolution '2k' is not supported for model grok-imagine-image"})
        if path.endswith("/images/edits"):
            refs = [body["image"]] if "image" in body else body.get("images", [])
            refs = [from_data_uri(r.get("url")) for r in refs if isinstance(r, dict)]
            refs = [r for r in refs if r]
            if not refs:
                return self.bad_param("grok", "image")
            out, _, _, _ = edit_image(refs[0])
            n_in = len(refs)
        else:
            w, h = ratio_size(body.get("aspect_ratio", "1:1"))
            out, n_in = generate_png(w, h), 0
        price = 0.04 if body.get("model", "").startswith("grok-imagine-image-2") else 0.02
        self.send_json(200, {"data": [{"b64_json": base64.b64encode(out).decode(), "mime_type": "image/png"}], "usage": {
            "input_tokens": 30 + 800 * n_in, "input_tokens_details": {"image_tokens": 800 * n_in},
            "output_tokens": 1500, "output_tokens_details": {"image_tokens": 1500},
            "cost_in_usd_ticks": int(price * 10_000_000_000)}})

    def gemini(self, body):
        blocks = body.get("input", [])
        prompt = " ".join(b.get("text", "") for b in blocks if isinstance(b, dict) and b.get("type") == "text")
        self.log("gemini", prompt)
        if not blocks:
            return self.bad_param("gemini", "input")
        if self.moderated("gemini", prompt):
            return
        images = [from_data_uri(b.get("data")) for b in blocks if isinstance(b, dict) and b.get("type") == "image"]
        images = [i for i in images if i]
        model = body.get("model") or ""
        if images and "image" not in model and ("flash" in model or "lite" in model):
            # 能看图的文字型号：只回文字
            return self.send_json(200, {"id": uuid.uuid4().hex, "status": "completed", "steps": [
                {"type": "thought", "content": [{"type": "text", "text": "Looking at the photo."}]},
                {"type": "model_output", "content": [{"type": "text", "text": self.look_text(prompt)}]}],
                "usage": {"total_input_tokens": 2310, "total_output_tokens": 640, "total_thought_tokens": 120}})
        if not images:
            # 只有文字：照 Gemini 的习惯回一段话、不给图
            return self.send_json(200, {"id": uuid.uuid4().hex, "steps": [{"type": "model_output", "content": [
                {"type": "text", "text": "I can only edit images you send me."}]}],
                "usage": {"total_input_tokens": 12, "total_output_tokens": 9}})
        out, mime, _, _ = edit_image(images[0])
        self.send_json(200, {"id": uuid.uuid4().hex, "status": "completed", "steps": [
            {"type": "thought", "content": [{"type": "text", "text": "Thinking about the edit."}]},
            {"type": "model_output", "content": [
                {"type": "text", "text": "Here is the edited image."},
                {"type": "image", "mime_type": mime, "data": base64.b64encode(out).decode()},
            ]}],
            "usage": {
                "total_input_tokens": 20 + 1290 * len(images), "total_output_tokens": 1300, "total_thought_tokens": 120,
                "input_tokens_by_modality": [{"modality": "text", "tokens": 20}, {"modality": "image", "tokens": 1290 * len(images)}],
                "output_tokens_by_modality": [{"modality": "text", "tokens": 10}, {"modality": "image", "tokens": 1290}],
            }})

    def qwen(self, body):
        msgs = (body.get("input") or {}).get("messages") or []
        content = msgs[0].get("content", []) if msgs and isinstance(msgs[0], dict) else []
        prompt = " ".join(c.get("text", "") for c in content if isinstance(c, dict) and "text" in c)
        params = body.get("parameters") or {}
        self.log("qwen", prompt + (f"  (size={params['size']})" if "size" in params else ""))
        if not msgs:
            return self.bad_param("qwen", "input.messages")
        if self.moderated("qwen", prompt):
            return
        images = [from_data_uri(c.get("image")) for c in content if isinstance(c, dict) and "image" in c]
        images = [i for i in images if i]
        if images:
            out, mime, w, h = edit_image(images[0])
        else:
            w, h = parse_size(params.get("size"), "*") or (1024, 1024)
            out, mime = generate_png(w, h), "image/png"
        link = self.store(out, mime)
        self.send_json(200, {"request_id": uuid.uuid4().hex, "output": {"choices": [{"finish_reason": "stop", "message": {
            "role": "assistant", "content": [{"image": link}]}}]},
            "usage": {"output_image_count": 1, "input_image_count": len(images), "output_width": w, "output_height": h}})

    def doubao(self, body):
        prompt = body.get("prompt", "")
        self.log("doubao", prompt + f"  (size={body.get('size')})")
        if not prompt:
            return self.bad_param("doubao", "prompt")
        if self.moderated("doubao", prompt):
            return
        refs = body.get("image")
        refs = [refs] if isinstance(refs, str) else (refs or [])
        refs = [r for r in (from_data_uri(x) for x in refs) if r]
        if refs:
            out, _, w, h = edit_image(refs[0])
        else:
            w, h = parse_size(body.get("size")) or (2048, 2048)
            out = generate_png(w, h)
            w, h = struct.unpack(">II", out[16:24])
        self.send_json(200, {"model": body.get("model"), "created": int(time.time()),
                             "data": [{"b64_json": base64.b64encode(out).decode(), "size": f"{w}x{h}"}],
                             "usage": {"generated_images": 1, "input_images": len(refs), "output_tokens": w * h // 256, "total_tokens": w * h // 256}})

    def flux_submit(self, model, body):
        prompt = body.get("prompt", "")
        self.log("flux", f"{model}: {prompt}")
        if not prompt:
            return self.bad_param("flux", "prompt")
        imgs = body.get("images") or [body[k] for k in sorted(body) if k.startswith("input_image")]
        imgs = [i for i in (from_data_uri(x) for x in imgs) if i]
        if "#审核" in prompt:
            result = ("Request Moderated", None, None)
        elif imgs:
            out, mime, _, _ = edit_image(imgs[0])
            result = ("Ready", out, mime)
        else:
            w, h = ratio_size(body.get("aspect_ratio", "1:1"))
            result = ("Ready", generate_png(w, h), "image/png")
        tid = uuid.uuid4().hex
        with LOCK:
            TASKS[tid] = {"polls": 0, "result": result}
        prefix = self.path.split(model)[0].rstrip("/")
        self.send_json(200, {"id": tid, "polling_url": f"{self.host_url()}{prefix}/get_result?id={tid}", "cost": 4.0})

    def flux_poll(self, tid):
        self.log("flux", f"poll {tid[:8]}")
        if not self.has_key():
            return self.denied()
        with LOCK:
            task = TASKS.get(tid)
            if task:
                task["polls"] += 1
        if not task:
            return self.send_json(200, {"id": tid, "status": "Task not found"})
        if task["polls"] < 2:  # 第一次查询还在排队
            return self.send_json(200, {"id": tid, "status": "Pending", "progress": 0.4})
        status, out, mime = task["result"]
        if status != "Ready":
            return self.send_json(200, {"id": tid, "status": status, "details": {"Moderation Reasons": ["Derivative Works Filter"]}})
        return self.send_json(200, {"id": tid, "status": "Ready", "result": {"sample": self.store(out, mime)}, "cost": 4.5})


def main():
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print(f"穷图 AI 模拟服务器：http://0.0.0.0:{PORT}（模拟器里用 http://10.0.2.2:{PORT}）", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
