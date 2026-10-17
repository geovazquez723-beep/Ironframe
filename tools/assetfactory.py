#!/usr/bin/env python3
"""Ironframe asset factory helper (spec -> generation args -> manifest -> catalog).

Generation itself runs through the Roblox Studio MCP `generate_mesh` tool (driven by Claude Code);
this script owns everything deterministic around it so a new batch is just a new spec file:

  assetfactory.py validate  assets/specs/batch_002.json
  assetfactory.py plan      assets/specs/batch_002.json [--only ID ...]   # prints generate_mesh arguments
  assetfactory.py record    assets/specs/batch_002.json ID --file attempt.json
  assetfactory.py catalog   assets/specs/batch_002.json                   # writes assets/catalog/<batch>.md
  assetfactory.py set       SPEC ID --status S --persistence '{json}'    # update status / persistence
  assetfactory.py loader    SPEC                                          # Luau that rebuilds staging from cloud model ids

Specs are immutable inputs. Status, retry counts and measured metadata live in
assets/manifests/<batch>.json. Only values reported by Studio are recorded; nothing is estimated.
"""
import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
STATUSES = {"PENDING", "GENERATING", "GENERATED", "FAILED", "ACCEPTED", "REJECTED", "NEEDS_REVIEW"}
REQUIRED = ("id", "category", "name", "prompt", "size", "maxTriangles", "intendedUse")


def load(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def manifest_path(spec):
    return ROOT / "assets" / "manifests" / f"{spec['batch']}.json"


def load_manifest(spec):
    path = manifest_path(spec)
    if path.exists():
        return json.loads(path.read_text(encoding="utf-8"))
    return {"batch": spec["batch"], "specVersion": spec["specVersion"], "assets": {}}


def save_manifest(spec, manifest):
    path = manifest_path(spec)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")


def validate(spec):
    errors, seen = [], set()
    for asset in spec["assets"]:
        for key in REQUIRED:
            if key not in asset:
                errors.append(f"{asset.get('id', '?')}: missing {key}")
        if asset.get("id") in seen:
            errors.append(f"duplicate id {asset['id']}")
        seen.add(asset.get("id"))
        if not 12 <= asset.get("maxTriangles", 0) <= 20000:
            errors.append(f"{asset.get('id')}: maxTriangles outside 12..20000")
        if set(asset.get("size", {})) != {"x", "y", "z"}:
            errors.append(f"{asset.get('id')}: size needs x,y,z")
        if asset.get("segmentation") == "explicit" and not 1 <= len(asset.get("partNames", [])) <= 8:
            errors.append(f"{asset.get('id')}: explicit segmentation needs 1..8 partNames")
    return errors


def generation_args(spec, asset):
    args = {
        "textPrompt": f"{asset['prompt']}. {spec['style']}",
        "size": asset["size"],
        "maxTriangles": asset["maxTriangles"],
        "segmentation": asset.get("segmentation", "auto"),
    }
    if args["segmentation"] == "explicit":
        args["partNames"] = ", ".join(asset["partNames"])
    return args


def cmd_validate(spec, _args):
    errors = validate(spec)
    for error in errors:
        print("ERROR", error)
    print(f"{len(spec['assets'])} assets, {len(errors)} errors")
    return 1 if errors else 0


def cmd_plan(spec, args):
    wanted = set(args.only or [])
    out = {a["id"]: generation_args(spec, a) for a in spec["assets"] if not wanted or a["id"] in wanted}
    print(json.dumps(out, indent=2))
    return 0


def cmd_record(spec, args):
    manifest = load_manifest(spec)
    attempt = json.loads(Path(args.file).read_text(encoding="utf-8"))
    attempt.setdefault("recordedAt", datetime.now(timezone.utc).isoformat(timespec="seconds"))
    entry = manifest["assets"].setdefault(args.id, {"status": "PENDING", "retryCount": 0, "attempts": []})
    entry["attempts"].append(attempt)
    entry["retryCount"] = max(0, len(entry["attempts"]) - 1)
    status = attempt.get("status")
    if status:
        if status not in STATUSES:
            print(f"unknown status {status}")
            return 1
        entry["status"] = status
    save_manifest(spec, manifest)
    print(f"recorded attempt {len(entry['attempts'])} for {args.id}: {entry['status']}")
    return 0


def cmd_set(spec, args):
    manifest = load_manifest(spec)
    entry = manifest["assets"].setdefault(args.id, {"status": "PENDING", "retryCount": 0, "attempts": []})
    if args.status:
        entry["status"] = args.status
    if args.persistence:
        entry["persistence"] = args.persistence
    save_manifest(spec, manifest)
    return 0


def cmd_catalog(spec, _args):
    manifest = load_manifest(spec)
    lines = [f"# {spec['batch']} catalog", "", "Generated from the spec and manifest by `tools/assetfactory.py catalog`. Values are only those Studio reported.", ""]
    counts = {}
    for asset in spec["assets"]:
        entry = manifest["assets"].get(asset["id"], {"status": "PENDING", "retryCount": 0, "attempts": []})
        counts[entry["status"]] = counts.get(entry["status"], 0) + 1
    lines.append("Summary: " + ", ".join(f"{k} {v}" for k, v in sorted(counts.items())))
    lines += ["", "| ID | Name | Status | Attempts | MeshParts | Bounding box (studs) | Persistence |", "| --- | --- | --- | --- | --- | --- | --- |"]
    for asset in spec["assets"]:
        entry = manifest["assets"].get(asset["id"], {"status": "PENDING", "attempts": []})
        last = (entry.get("attempts") or [{}])[-1]
        bbox = last.get("boundingBox")
        lines.append("| {} | {} | {} | {} | {} | {} | {} |".format(
            asset["id"], asset["name"], entry["status"], len(entry.get("attempts", [])),
            last.get("meshPartCount", "-"), "x".join(f"{v:.1f}" for v in bbox) if bbox else "-",
            entry.get("persistence", {}).get("state", "-")))
    lines.append("")
    for asset in spec["assets"]:
        entry = manifest["assets"].get(asset["id"])
        if not entry:
            continue
        lines.append(f"## {asset['id']} {asset['name']} - {entry['status']}")
        lines.append(f"Intended use: {asset['intendedUse']}. Rig note: {asset.get('rig', '-')}")
        for i, attempt in enumerate(entry["attempts"], 1):
            lines.append(f"- Attempt {i}: {attempt.get('status', '?')}; model `{attempt.get('modelPath', '-')}`; "
                         f"error: {attempt.get('error', 'none')}")
            if attempt.get("evaluation"):
                lines.append(f"  - Evaluation: {attempt['evaluation']}")
            for part in attempt.get("parts", []):
                lines.append(f"  - part `{part['name']}` size {part.get('size')} mesh `{part.get('meshId')}` texture `{part.get('textureId')}`")
        lines.append("")
    out = ROOT / "assets" / "catalog" / f"{spec['batch']}.md"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("wrote", out.relative_to(ROOT))
    return 0


def cmd_loader(spec, _args):
    """Emit a Luau snippet (run via execute_luau in any Studio place) that rebuilds the staging hierarchy
    from verified cloud model asset ids recorded in the manifest. This is the Git-tracked preservation path."""
    manifest = load_manifest(spec)
    rows = []
    for asset in spec["assets"]:
        entry = manifest["assets"].get(asset["id"], {})
        persistence = entry.get("persistence", {})
        if entry.get("status") in ("ACCEPTED", "NEEDS_REVIEW") and persistence.get("modelAssetId"):
            rows.append(f'    {{ id = "{asset["id"]}", name = "{asset["name"]}", asset = {persistence["modelAssetId"]}, status = "{entry["status"]}" }},')
    print(f"""local InsertService = game:GetService("InsertService")
local root = workspace:FindFirstChild("IronframeGeneratedAssets") or Instance.new("Folder")
root.Name = "IronframeGeneratedAssets"; root.Parent = workspace
local batch = Instance.new("Folder"); batch.Name = "{spec['batch']}"; batch.Parent = root
local ASSETS = {{
{chr(10).join(rows)}
}}
for index, a in ipairs(ASSETS) do
    local ok, loaded = pcall(InsertService.LoadAsset, InsertService, a.asset)
    if ok then
        local model = loaded:GetChildren()[1]
        model.Name = a.id .. "_" .. a.name
        model:SetAttribute("AssetId", a.id); model:SetAttribute("Status", a.status)
        model.Parent = batch
        model:PivotTo(CFrame.new(((index - 1) % 4) * 40 - 60, 10, 80 + math.floor((index - 1) / 4) * 40))
        loaded:Destroy()
    else
        warn("load failed", a.id, loaded)
    end
end""")
    return 0


def cmd_registry(spec, _args):
    """Write src/ReplicatedStorage/IronframeShared/AssetRegistry.luau (ACCEPTED assets only) so the game can
    load them at runtime from their cloud model asset ids. Re-run per batch; the hangar code never changes."""
    manifest = load_manifest(spec)
    path = ROOT / "src" / "ReplicatedStorage" / "IronframeShared" / "AssetRegistry.luau"
    existing = {}
    if path.exists():
        # merge batches: keep entries of other batches already in the file
        for line in path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line.startswith("{ id = "):
                existing[line.split('"')[1]] = line
    for asset in spec["assets"]:
        entry = manifest["assets"].get(asset["id"], {})
        persistence = entry.get("persistence", {})
        if entry.get("status") != "ACCEPTED" or not persistence.get("modelAssetId"):
            existing.pop(asset["id"], None)
            continue
        last = entry["attempts"][-1]
        bbox = ", ".join(f"{v:.2f}" for v in last["boundingBox"])
        existing[asset["id"]] = (f'{{ id = "{asset["id"]}", name = "{asset["name"]}", batch = "{spec["batch"]}", '
                                 f'modelAssetId = {persistence["modelAssetId"]}, bbox = Vector3.new({bbox}), meshParts = {last["meshPartCount"]} }},')
    body = "\n".join("    " + existing[k] for k in sorted(existing))
    path.write_text(f"""-- GENERATED by tools/assetfactory.py registry - do not edit by hand.
-- ACCEPTED AI-generated models, keyed by stable asset id. modelAssetId is a cloud model asset that
-- AssetLibrary loads at runtime (InsertService:LoadAsset); geometry/textures are NOT stored in Git.
local Registry = {{
{body}
}}

local byId = {{}}
for _, entry in ipairs(Registry) do
    byId[entry.id] = entry
end

return {{ list = Registry, byId = byId }}
""", encoding="utf-8")
    print("wrote", path.relative_to(ROOT), len(existing), "assets")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    for name in ("validate", "plan", "record", "catalog", "set", "loader", "registry"):
        p = sub.add_parser(name)
        p.add_argument("spec")
        if name == "plan":
            p.add_argument("--only", nargs="*")
        if name in ("record", "set"):
            p.add_argument("id")
        if name == "record":
            p.add_argument("--file", required=True)
        if name == "set":
            p.add_argument("--status", choices=sorted(STATUSES))
            p.add_argument("--persistence", type=json.loads)
    args = parser.parse_args()
    spec = load(args.spec)
    return {"validate": cmd_validate, "plan": cmd_plan, "record": cmd_record, "catalog": cmd_catalog, "set": cmd_set, "loader": cmd_loader, "registry": cmd_registry}[args.cmd](spec, args)


if __name__ == "__main__":
    sys.exit(main())
