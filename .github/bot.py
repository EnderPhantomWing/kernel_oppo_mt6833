import os
import sys
import json
import requests

BOT_TOKEN = os.environ["BOT_TOKEN"]

# CHAT_ID 支持多个目标，格式：
#   -1002961023447:351,-1001111111111,-1002222222222:888
# 规则：
#   - 不带 ":" → 普通 chat（频道 / 普通群）
#   - 带 ":"   → forum 话题：chat_id:thread_id
# 分隔符：逗号 / 分号 / 空白 / 换行 均可；自动去重保序
CHAT_ID_RAW = os.environ.get("CHAT_ID", "").strip()

MAX_SIZE = 50 * 1024 * 1024   # Bot API 单文件上限
MAX_CAPTION = 1024            # Telegram caption 上限
MAX_ALBUM = 10                # Telegram 单个 album 上限


# ==============================
# 解析目标
# ==============================
def parse_targets(raw):
    """
    解析 CHAT_ID 环境变量，返回：
        [{"chat_id": "-100...", "thread_id": "351" | None}, ...]
    """
    if not raw:
        raise SystemExit("[-] CHAT_ID is empty or not set.")

    chunks = []
    normalized = raw.replace(";", ",").replace("\r", ",").replace("\n", ",")
    for part in normalized.split(","):
        p = part.strip()
        if p:
            chunks.append(p)

    result, seen = [], set()
    for p in chunks:
        if ":" in p:
            cid, tid = p.split(":", 1)
            cid, tid = cid.strip(), (tid.strip() or None)
        else:
            cid, tid = p, None

        if not cid:
            continue

        key = (cid, tid)
        if key in seen:
            continue
        seen.add(key)
        result.append({"chat_id": cid, "thread_id": tid})

    if not result:
        raise SystemExit("[-] No valid CHAT_ID found.")
    return result


TARGETS = parse_targets(CHAT_ID_RAW)


def target_label(target):
    if target.get("thread_id"):
        return f"{target['chat_id']}:{target['thread_id']}"
    return target["chat_id"]


# ==============================
# 工具
# ==============================
def truncate_caption(caption):
    if not caption:
        return None
    if len(caption) > MAX_CAPTION:
        print(f"[!] Caption {len(caption)} chars > {MAX_CAPTION}, truncating")
        return caption[: MAX_CAPTION - 3] + "..."
    return caption


def check_files(files):
    if not files:
        raise SystemExit("[-] No file paths provided.")
    if len(files) > MAX_ALBUM:
        raise SystemExit(
            f"[-] Too many files ({len(files)}), Telegram album max is {MAX_ALBUM}."
        )
    for path in files:
        if not os.path.isfile(path):
            raise SystemExit(f"[-] File not found: {path}")
        size = os.path.getsize(path)
        if size > MAX_SIZE:
            raise SystemExit(
                f"[-] {path} is {size / 1024**2:.1f}MB, "
                f"exceeds Bot API 50MB limit. "
                f"Split the zip or switch back to Telethon/MTProto."
            )


def handle_response(resp, target=None):
    ctx = f" target={target_label(target)}" if target else ""
    try:
        body = resp.json()
    except ValueError:
        raise SystemExit(f"[-] Non-JSON response ({resp.status_code}){ctx}: {resp.text}")

    if not body.get("ok"):
        desc = body.get("description", resp.text)
        if "not a member" in desc or "chat not found" in desc:
            raise SystemExit(f"[-] Bot can't access chat{ctx}. Check CHAT_ID. ({desc})")
        if "not enough rights" in desc or "CHAT_WRITE_FORBIDDEN" in desc:
            raise SystemExit(f"[-] Bot lacks 'Post Messages' permission{ctx}. ({desc})")
        if "message thread not found" in desc:
            raise SystemExit(f"[-] Topic (message_thread_id) not found{ctx}. ({desc})")
        if "MEDIA_CAPTION_TOO_LONG" in desc:
            raise SystemExit(f"[-] Caption too long{ctx}. ({desc})")
        raise SystemExit(f"[-] Telegram API error{ctx}: {desc}")


# ==============================
# 发送：单文件
# ==============================
def send_single(target, path, caption=None):
    url = f"https://api.telegram.org/bot{BOT_TOKEN}/sendDocument"
    data = {"chat_id": target["chat_id"], "parse_mode": "HTML"}
    if target.get("thread_id"):
        data["message_thread_id"] = target["thread_id"]
    if caption:
        data["caption"] = caption

    with open(path, "rb") as f:
        resp = requests.post(url, data=data, files={"document": f}, timeout=300)

    handle_response(resp, target)
    size = os.path.getsize(path)
    print(f"[+] Sent single -> {target_label(target)}: {path} ({size / 1024**2:.1f}MB)")


# ==============================
# 发送：多文件 album
# ==============================
def send_album(target, files, caption=None):
    media = []
    files_payload = {}
    handles = []

    try:
        for i, path in enumerate(files):
            item = {"type": "document", "media": f"attach://file{i}"}
            if i == 0 and caption:
                item["caption"] = caption
                item["parse_mode"] = "HTML"
            media.append(item)

            fh = open(path, "rb")
            handles.append(fh)
            files_payload[f"file{i}"] = (os.path.basename(path), fh)

        url = f"https://api.telegram.org/bot{BOT_TOKEN}/sendMediaGroup"
        data = {"chat_id": target["chat_id"], "media": json.dumps(media)}
        if target.get("thread_id"):
            data["message_thread_id"] = target["thread_id"]

        resp = requests.post(url, data=data, files=files_payload, timeout=600)
    finally:
        for fh in handles:
            fh.close()

    handle_response(resp, target)
    total = sum(os.path.getsize(p) for p in files)
    print(
        f"[+] Sent album -> {target_label(target)}: "
        f"{len(files)} file(s), total {total / 1024**2:.1f}MB"
    )
    for p in files:
        print(f"    - {p} ({os.path.getsize(p) / 1024**2:.1f}MB)")


# ==============================
# main
# ==============================
def main():
    args = sys.argv[1:]

    caption = None
    if "--caption" in args:
        i = args.index("--caption")
        if i + 1 >= len(args):
            raise SystemExit("[-] --caption requires a value")
        caption = args[i + 1]
        args = args[:i] + args[i + 2:]

    check_files(args)
    caption = truncate_caption(caption)

    print(f"[=] Target chats ({len(TARGETS)}):")
    for t in TARGETS:
        print(f"    - {target_label(t)}")

    ok, fail = [], []
    for t in TARGETS:
        try:
            if len(args) == 1:
                send_single(t, args[0], caption)
            else:
                send_album(t, args, caption)
            ok.append(t)
        except SystemExit as e:
            print(f"[-] {target_label(t)} failed: {e}")
            fail.append(t)
        except Exception as e:
            print(f"[-] {target_label(t)} failed: {e!r}")
            fail.append(t)

    print(f"[=] Summary: success={len(ok)}/{len(TARGETS)}")
    if fail:
        print(f"[!] Failed targets: {[target_label(t) for t in fail]}")
        if not ok:
            raise SystemExit("[-] All targets failed.")
        raise SystemExit(f"[-] Partial failure: {[target_label(t) for t in fail]}")

    print("[+] All targets sent successfully.")


if __name__ == "__main__":
    main()
