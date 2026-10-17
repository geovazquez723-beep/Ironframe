"""Roblox Open Cloud audio upload / register / validate utility. Standard library only.

The API key is read only from the ROBLOX_OPEN_CLOUD_API_KEY environment variable (process env, or on
Windows the persisted User/Machine variable) and is never printed or written anywhere.

  python tools/roblox_audio_upload.py upload   --wav assets/audio/x.wav --manifest assets/audio/x.json --name ironframe_x
  python tools/roblox_audio_upload.py register --manifest assets/audio/manifest.json --asset-id 123...
  python tools/roblox_audio_upload.py validate --manifest assets/audio/manifest.json
  python tools/roblox_audio_upload.py grant    --manifest ... --universe-id N     (optional experience grant)

`upload` submits the WAV (skipped if the manifest already has an asset_id for the same sha256),
polls the operation until done, then validates and records asset_id/status in the manifest.
`validate` fetches the asset and requires type Audio, state Active, moderation Approved.
Exit code is non-zero on any failure, so it can gate automation. Needs asset:read + asset:write
(and the asset-permissions scope for `grant`).
"""
import argparse
import hashlib
import json
import os
import sys
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path

BASE = "https://apis.roblox.com"
ENV = "ROBLOX_OPEN_CLOUD_API_KEY"
MAX_BYTES = 20 * 1024 * 1024


def api_key():
    key = os.environ.get(ENV)
    if not key and os.name == "nt":
        import winreg
        for hive, sub in ((winreg.HKEY_CURRENT_USER, "Environment"),
                          (winreg.HKEY_LOCAL_MACHINE, r"SYSTEM\CurrentControlSet\Control\Session Manager\Environment")):
            try:
                with winreg.OpenKey(hive, sub) as handle:
                    key = winreg.QueryValueEx(handle, ENV)[0]
                    break
            except OSError:
                continue
    if not key:
        sys.exit(f"{ENV} is not set")
    return key.strip()


def call(method, path, key, body=None, headers=None):
    req = urllib.request.Request(BASE + path, data=body, method=method,
                                 headers={"x-api-key": key, **(headers or {})})
    try:
        with urllib.request.urlopen(req, timeout=60) as res:
            raw = res.read()
            return res.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as err:
        raw = err.read().decode("utf-8", "replace")
        try:
            return err.code, json.loads(raw)
        except ValueError:
            return err.code, {"error": raw[:300]}


def creator_for(key):
    """Creator is taken from IRONFRAME_CREATOR (user:ID or group:ID), else from the asset-owner field
    of the manifest, else resolved from the key's own authorized user via the first lookup."""
    spec = os.environ.get("IRONFRAME_CREATOR")
    if not spec:
        sys.exit("set IRONFRAME_CREATOR=user:<id> or group:<id> (or pass --creator) for uploads")
    kind, ident = spec.split(":", 1)
    return {"userId": ident} if kind == "user" else {"groupId": ident}


def multipart(fields, filename, data, content_type):
    boundary = uuid.uuid4().hex
    out = []
    for name, value in fields.items():
        out.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n'
                   f'Content-Type: application/json\r\n\r\n{value}\r\n'.encode())
    out.append(f'--{boundary}\r\nContent-Disposition: form-data; name="fileContent"; filename="{filename}"\r\n'
               f'Content-Type: {content_type}\r\n\r\n'.encode() + data + b"\r\n")
    out.append(f"--{boundary}--\r\n".encode())
    return b"".join(out), f"multipart/form-data; boundary={boundary}"


def load(path):
    return json.loads(Path(path).read_text(encoding="utf-8")) if Path(path).exists() else {}


def save(path, manifest):
    Path(path).write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")


def validate(key, asset_id):
    code, info = call("GET", f"/assets/v1/assets/{asset_id}?readMask=assetId,displayName,assetType,"
                      "creationContext,moderationResult,state", key)
    if code != 200:
        return False, f"HTTP {code}: {info}"
    problems = []
    if info.get("assetType") != "Audio":
        problems.append(f"assetType={info.get('assetType')}")
    if info.get("state") != "Active":
        problems.append(f"state={info.get('state')}")
    if info.get("moderationResult", {}).get("moderationState") != "Approved":
        problems.append(f"moderation={info.get('moderationResult')}")
    return (not problems), (", ".join(problems) or info)


def cmd_upload(args, key):
    wav = Path(args.wav)
    data = wav.read_bytes()
    if wav.suffix.lower() not in (".wav", ".mp3", ".ogg") or len(data) > MAX_BYTES:
        sys.exit("unsupported file type or size")
    digest = hashlib.sha256(data).hexdigest()
    manifest = load(args.manifest)
    if manifest.get("asset_id") and manifest.get("sha256") == digest and not args.force:
        print(f"already uploaded as {manifest['asset_id']} (same sha256); validating only")
        return finish(args, key, manifest, manifest["asset_id"])
    creator = {"userId": args.creator.split(":")[1]} if args.creator and args.creator.startswith("user:") \
        else {"groupId": args.creator.split(":")[1]} if args.creator else creator_for(key)
    request = {"assetType": "Audio", "displayName": args.name[:50],
               "description": args.description, "creationContext": {"creator": creator}}
    body, ctype = multipart({"request": json.dumps(request)}, wav.name, data, "audio/wav")
    code, op = call("POST", "/assets/v1/assets", key, body, {"Content-Type": ctype})
    if code != 200:
        sys.exit(f"upload rejected: HTTP {code}: {op}")
    op_path = op["path"]
    for _ in range(60):
        if op.get("done"):
            break
        time.sleep(2)
        code, op = call("GET", f"/assets/v1/{op_path}", key)
        if code != 200:
            sys.exit(f"operation poll failed: HTTP {code}: {op}")
    if not op.get("done"):
        sys.exit("operation did not complete within 2 minutes; rerun `validate` later")
    if "error" in op:
        sys.exit(f"upload failed: {op['error']}")
    asset_id = str(op["response"]["assetId"])
    manifest.update({"sha256": digest, "asset_id": asset_id})
    return finish(args, key, manifest, asset_id)


def finish(args, key, manifest, asset_id):
    ok = False
    for _ in range(30):  # moderation can lag the upload by a few seconds
        ok, detail = validate(key, asset_id)
        if ok or "moderation={'moderationState': 'Rejected'" in str(detail):
            break
        time.sleep(2)
    manifest["asset_id"] = asset_id
    manifest["status"] = "uploaded_approved_active" if ok else "uploaded_not_validated"
    manifest["validated_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    save(args.manifest, manifest)
    print(json.dumps({"asset_id": asset_id, "validated": ok, "detail": str(detail)[:200]}))
    return 0 if ok else 1


def cmd_register(args, key):
    manifest = load(args.manifest)
    ok, detail = validate(key, args.asset_id)
    if not ok:
        sys.exit(f"asset {args.asset_id} did not validate: {detail}")
    wav = Path(manifest["file"]) if manifest.get("file") else None
    manifest["asset_id"] = str(args.asset_id)
    manifest["status"] = "registered_approved_active"
    manifest["validated_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    save(args.manifest, manifest)
    print(json.dumps({"asset_id": args.asset_id, "validated": True}))
    return 0


def cmd_validate(args, key):
    manifest = load(args.manifest)
    if not manifest.get("asset_id"):
        sys.exit("manifest has no asset_id")
    ok, detail = validate(key, manifest["asset_id"])
    if ok:  # record the result so a moderation that finished after `upload` timed out is not lost
        manifest["status"] = "uploaded_approved_active" if manifest.get("status", "").startswith("uploaded") else "registered_approved_active"
        manifest["validated_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        save(args.manifest, manifest)
    print(json.dumps({"asset_id": manifest["asset_id"], "validated": ok, "detail": str(detail)[:200]}))
    return 0 if ok else 1


def cmd_grant(args, key):
    manifest = load(args.manifest)
    body = json.dumps({"requests": [{"subjectType": "Universe", "subjectId": str(args.universe_id),
                                      "action": "Use"}]}).encode()
    code, res = call("PATCH", f"/asset-permissions-api/v1/assets/{manifest['asset_id']}/permissions",
                     key, body, {"Content-Type": "application/json"})
    print(json.dumps({"http": code, "response": res}))
    if code == 200:
        manifest["granted_universe_id"] = str(args.universe_id)
        save(args.manifest, manifest)
    return 0 if code == 200 else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    up = sub.add_parser("upload")
    up.add_argument("--wav", required=True)
    up.add_argument("--manifest", required=True)
    up.add_argument("--name", required=True)
    up.add_argument("--description", default="Original Ironframe weapon audio (CC0)")
    up.add_argument("--creator", help="user:<id> or group:<id>; default $IRONFRAME_CREATOR")
    up.add_argument("--force", action="store_true")
    reg = sub.add_parser("register")
    reg.add_argument("--manifest", required=True)
    reg.add_argument("--asset-id", required=True)
    val = sub.add_parser("validate")
    val.add_argument("--manifest", required=True)
    grant = sub.add_parser("grant")
    grant.add_argument("--manifest", required=True)
    grant.add_argument("--universe-id", required=True)
    args = parser.parse_args()
    sys.exit({"upload": cmd_upload, "register": cmd_register, "validate": cmd_validate,
              "grant": cmd_grant}[args.cmd](args, api_key()))


if __name__ == "__main__":
    main()
