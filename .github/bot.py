import os
import sys
import json
import requests

BOT_TOKEN = os.environ["BOT_TOKEN"]
CHAT_ID = os.environ["CHAT_ID"]
MAX_SIZE = 50 * 1024 * 1024   # Bot API 单文件上限
MAX_CAPTION = 1024            # Telegram caption 上限
MAX_ALBUM = 10                # Telegram 单个 album 上限


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
        raise SystemExit(f"[-] Too many files ({len(files)}), Telegram album max is {MAX_ALBUM}.")
    for path in files:
        if not os.path.isfile(path):
            raise SystemExit(f"[-] File not found: {path}")
        size = os.path.getsize(path)
        if size > MAX_SIZE:
            raise SystemExit(
                f"[-] {path} is {size / 1024**2:.1f}MB, exceeds Bot API 50MB limit. "
                f"Split the zip or switch back to Telethon/MTProto."
            )


def handle_response(resp):
    try:
        body = resp.json()
    except ValueError:
        raise SystemExit(f"[-] Non-JSON response ({resp.status_code}): {resp.text}")

    if not body.get("ok"):
        desc = body.get("description", resp.text)
        if "not a member" in desc or "chat not found" in desc:
            raise SystemExit(f"[-] Bot can't access channel. Check CHAT_ID. ({desc})")
        if "not enough rights" in desc or "CHAT_WRITE_FORBIDDEN" in desc:
            raise SystemExit(f"[-] Bot lacks 'Post Messages' permission. ({desc})")
        if "MEDIA_CAPTION_TOO_LONG" in desc:
            raise SystemExit(f"[-] Caption too long. ({desc})")
        raise SystemExit(f"[-] Telegram API error: {desc}")


def send_single(path, caption=None):
    """单文件：sendDocument"""
    url = f"https://api.telegram.org/bot{BOT_TOKEN}/sendDocument"
    data = {"chat_id": CHAT_ID, "parse_mode": "HTML"}
    if caption:
        data["caption"] = caption

    with open(path, "rb") as f:
        resp = requests.post(url, data=data, files={"document": f}, timeout=300)

    handle_response(resp)
    size = os.path.getsize(path)
    print(f"[+] Sent single: {path} ({size / 1024**2:.1f}MB)")


def send_album(files, caption=None):
    """多文件：sendMediaGroup，caption 挂在第一个文件上，其余不带"""
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
        data = {"chat_id": CHAT_ID, "media": json.dumps(media)}
        resp = requests.post(url, data=data, files=files_payload, timeout=600)
    finally:
        for fh in handles:
            fh.close()

    handle_response(resp)
    total = sum(os.path.getsize(p) for p in files)
    print(f"[+] Sent album: {len(files)} file(s), total {total / 1024**2:.1f}MB")
    for p in files:
        print(f"    - {p} ({os.path.getsize(p) / 1024**2:.1f}MB)")


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

    if len(args) == 1:
        send_single(args[0], caption)
    else:
        send_album(args, caption)


if __name__ == "__main__":
    main()