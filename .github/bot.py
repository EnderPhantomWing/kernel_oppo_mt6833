import os
import sys
import requests

BOT_TOKEN = os.environ["BOT_TOKEN"]
CHAT_ID = os.environ["CHAT_ID"]
MAX_SIZE = 50 * 1024 * 1024
MAX_CAPTION = 1024


def truncate_caption(caption):
    if not caption:
        return None
    if len(caption) > MAX_CAPTION:
        print(f"[!] Caption {len(caption)} chars > {MAX_CAPTION}, truncating")
        return caption[: MAX_CAPTION - 3] + "..."
    return caption


def send_file(path, caption=None):
    if not os.path.isfile(path):
        raise SystemExit(f"[-] File not found: {path}")
    size = os.path.getsize(path)
    if size > MAX_SIZE:
        raise SystemExit(
            f"[-] {path} is {size / 1024**2:.1f}MB, exceeds Bot API 50MB limit. "
            f"Split the zip or switch back to Telethon/MTProto."
        )

    url = f"https://api.telegram.org/bot{BOT_TOKEN}/sendDocument"
    data = {"chat_id": CHAT_ID, "parse_mode": "HTML"}
    if caption:
        data["caption"] = caption

    with open(path, "rb") as f:
        resp = requests.post(url, data=data, files={"document": f}, timeout=300)

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

    print(f"[+] Sent {path} ({size / 1024**2:.1f}MB)")


def main():
    args = sys.argv[1:]
    caption = None
    if "--caption" in args:
        i = args.index("--caption")
        if i + 1 >= len(args):
            raise SystemExit("[-] --caption requires a value")
        caption = args[i + 1]
        args = args[:i] + args[i + 2:]

    if not args:
        raise SystemExit("[-] No file paths provided.")

    caption = truncate_caption(caption)
    for idx, path in enumerate(args):
        send_file(path, caption if idx == 0 else None)


if __name__ == "__main__":
    main()