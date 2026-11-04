#!/usr/bin/env python3
"""芝士虎整 · 桌面端一键更新（macOS / Windows）。

用法：
    python3 tools/update_desktop.py --list-profiles
    python3 tools/update_desktop.py --check
    python3 tools/update_desktop.py --source /path/to/cheese-tiger-vX.Y.Z-update.zip --yes
    python3 tools/update_desktop.py --source /path/to/full.zip --deploy --restart --yes

说明：
  · 自动识别鼠须管、fcitx5（小企鹅）、元书（Cobra）、小狼毫，并扫描 Windows
    下其他含 tiger 方案的 Rime 用户目录（例如虎韵）；
  · 优先使用 Release 里的增量包（*-update.zip），没有则用完整包；
  · 不会覆盖用户数据：*.userdb、*.options.yaml、user.yaml、installation.yaml、
    reverse_freq.txt、custom_phrase.txt、build/、sync/、统计文件等；
  · 完整包里的 405MB 模型若目标目录已有同尺寸文件，会跳过复制；
  · 默认只复制文件；--deploy 执行部署，--restart 重启前端。

私有仓库：
  默认从 GitHub latest release 下载；私有仓库需要 GITHUB_TOKEN/GH_TOKEN，
  或直接用 --source 指定本地 zip / URL。
"""

import argparse
import hashlib
import json
import os
import platform
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path, PurePosixPath

REPO = "viui798/viui-tiger-sentense"
API = f"https://api.github.com/repos/{REPO}/releases"
MARKER = ".cheese-tiger-version"
BACKUP_DIR = ".cheese-tiger-backup"

RUNTIME_DIRS = ("lua/", "opencc/", "models/", "dicts/", "tiger_dicts/", "zuci/")
EXCLUDE_DIRS = ("tools/", "docs/", "sync/", "validation/", "手机精简版/", "build/")
EXCLUDE_NAMES = {
    "AGENTS.md", "README.md", "CHANGELOG.md", "LICENSE", "安装说明.txt",
    "安装与更新说明.txt", "RELEASE.json", "SHA256SUMS.txt",
    "SOURCE_BASELINE.md", "RIME_CORRECTNESS.md", "IOS_TEST_README.md",
}
USER_DATA_FILES = {"user.yaml", "installation.yaml", "reverse_freq.txt", "custom_phrase.txt"}
USER_DATA_SUFFIXES = (".userdb", ".options.yaml", ".log", ".md", ".zip", ".sha256")
USER_DATA_LUA = {"kc_count.txt", "kc_total.txt"}
BIG_MODEL = "models/sentence-fivegram-mobile.bin"


def posix(path):
    return str(path).replace(os.sep, "/")


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def read_sha256(path):
    text = Path(path).read_text(encoding="utf-8", errors="ignore").split()
    return text[0].lower() if text else None


def verify_hash(path, expected):
    if not expected:
        return True
    actual = sha256_file(path)
    if actual.lower() != expected.lower():
        print(f"  ✗ SHA256 不匹配：期望 {expected}，实际 {actual}")
        return False
    print("  ✓ SHA256 校验通过")
    return True


def make_opener(proxy):
    handlers = []
    if proxy:
        handlers.append(urllib.request.ProxyHandler({"http": proxy, "https": proxy}))
    return urllib.request.build_opener(*handlers) if handlers else urllib.request.build_opener()


def default_cache_dir():
    system = platform.system()
    if system == "Windows":
        base = os.environ.get("LOCALAPPDATA") or tempfile.gettempdir()
        return Path(base) / "cheese-tiger" / "cache"
    if system == "Darwin":
        return Path.home() / "Library" / "Caches" / "cheese-tiger"
    return Path.home() / ".cache" / "cheese-tiger"


def should_copy(rel, size=None, target=None):
    p = PurePosixPath(rel)
    if str(p).startswith(EXCLUDE_DIRS):
        return False
    if p.name in EXCLUDE_NAMES:
        return False
    if any(part.endswith(".userdb") for part in p.parts):
        return False
    if p.name in USER_DATA_FILES or p.name.endswith(USER_DATA_SUFFIXES):
        return False
    if p.parent == PurePosixPath("lua") and p.name.startswith("input_stats_") and p.suffix == ".lua":
        return False
    if p.parent == PurePosixPath("lua") and p.name in USER_DATA_LUA:
        return False
    if p.suffix == ".md":
        return False
    if str(p).startswith(RUNTIME_DIRS):
        if rel == BIG_MODEL and size and target:
            existing = target / BIG_MODEL
            if existing.exists() and existing.stat().st_size == size:
                return False
        return True
    return p.suffix in {".yaml", ".txt", ".json", ".lua"}


def looks_like_rime_dir(path):
    return any((path / name).exists() for name in
               ("tiger_sentence.schema.yaml", "tiger.schema.yaml", "default.custom.yaml", "rime.lua"))


def find_windows_profiles():
    found = []
    bases = [Path(os.environ.get("APPDATA", ""))] if os.environ.get("APPDATA") else []
    local = os.environ.get("LOCALAPPDATA")
    if local:
        bases.append(Path(local))
    for base in bases:
        if not base.is_dir():
            continue
        for root, dirs, files in os.walk(base):
            depth = len(Path(root).relative_to(base).parts)
            if depth > 4:
                dirs[:] = []
                continue
            p = Path(root)
            if looks_like_rime_dir(p):
                found.append(p)
            # 不深入明显非 Rime 的目录
            dirs[:] = [d for d in dirs if d not in {"Cache", "Code Cache", "GPUCache", "logs"}]
    return found


def detect_profiles():
    profiles = []
    home = Path.home()
    seen = set()

    def add(label, path, kind):
        path = path.expanduser()
        if path.is_dir() and looks_like_rime_dir(path) and path not in seen:
            seen.add(path)
            profiles.append({"label": label, "path": path, "kind": kind})

    system = platform.system()
    if system == "Darwin":
        add("鼠须管", home / "Library/Rime", "squirrel")
        add("小企鹅", home / ".local/share/fcitx5/rime", "fcitx5")
        add("元书", home / "Library/Application Support/com.ihsiao.inputmethod.Cobra/RimeUserData", "cobra")
    elif system == "Windows":
        appdata_env = os.environ.get("APPDATA")
        if appdata_env:
            add("小狼毫", Path(appdata_env) / "Rime", "weasel")
        for p in find_windows_profiles():
            add(p.name or "Rime", p, "unknown")
    return profiles


def read_local_version(path):
    marker = path / MARKER
    if marker.exists():
        return marker.read_text(encoding="utf-8").strip().lstrip("v") or None
    changelog = path / "CHANGELOG.md"
    if changelog.exists():
        for line in changelog.read_text(encoding="utf-8", errors="ignore").splitlines():
            if line.startswith("## v"):
                return line[3:].split("（")[0].strip().lstrip("v")
    return None


def github_release(version, token):
    url = f"{API}/tags/{version}" if version else f"{API}/latest"
    headers = {"Accept": "application/vnd.github+json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


def pick_asset(release):
    assets = release.get("assets") or []
    updates = [a for a in assets if a.get("name", "").endswith("-update.zip")]
    if updates:
        return updates[0], True
    full = [a for a in assets if a.get("name", "").endswith(".zip") and "-update" not in a.get("name", "")]
    if full:
        return full[0], False
    raise SystemExit("✗ Release 里没有可用的 zip 资产")


def download(url, token, dest, opener=None, expected=None):
    headers = {"Accept": "application/octet-stream"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, headers=headers)
    open_fn = opener.open if opener else urllib.request.urlopen
    with open_fn(req, timeout=60) as resp, open(dest, "wb") as fh:
        total = resp.headers.get("Content-Length")
        total = int(total) if total else 0
        done = 0
        last = 0
        while True:
            chunk = resp.read(1024 * 1024)
            if not chunk:
                break
            fh.write(chunk)
            done += len(chunk)
            if total and done * 100 // total >= last + 5:
                last = done * 100 // total
                print(f"  下载 {last}%")
    if not verify_hash(dest, expected):
        try:
            os.unlink(dest)
        except OSError:
            pass
        return None
    return dest


def zip_prefix(zf):
    names = [n for n in zf.namelist() if not n.endswith("/")]
    if not names:
        return ""
    first = names[0]
    if first.startswith("update/"):
        return "update/"
    top = first.split("/")[0]
    return top + "/"


def apply_zip(zip_path, target, version, dry_run, expected=None):
    if not verify_hash(zip_path, expected):
        raise SystemExit("✗ 安装包 SHA256 校验失败，已停止")
    with zipfile.ZipFile(zip_path) as zf:
        prefix = zip_prefix(zf)
        delta = None
        delta_name = prefix + "DELTA.json"
        if delta_name in zf.namelist():
            delta = json.loads(zf.read(delta_name))
        if delta and delta.get("full_required"):
            raise SystemExit("✗ 该增量包要求完整包（模型有变更），请改用完整 zip")

        copied = skipped = 0
        backup_root = target / BACKUP_DIR / time.strftime("%Y%m%d-%H%M%S")
        for info in zf.infolist():
            if info.is_dir() or not info.filename.startswith(prefix):
                continue
            rel = info.filename[len(prefix):]
            if rel == "DELTA.json" or not should_copy(rel, info.file_size, target):
                skipped += 1
                continue
            if dry_run:
                print(f"  会更新 {rel}")
                copied += 1
                continue
            dst = target / rel
            if rel.endswith(".custom.yaml") and dst.exists():
                bak = backup_root / rel
                bak.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(dst, bak)
            dst.parent.mkdir(parents=True, exist_ok=True)
            with zf.open(info) as src, open(dst, "wb") as out:
                shutil.copyfileobj(src, out)
            copied += 1

        if delta:
            for rel in delta.get("deletions") or []:
                if not should_copy(rel):
                    continue
                dst = target / rel
                if dst.exists():
                    print(f"  删除 {rel}" if dry_run else f"  已删除 {rel}")
                    if not dry_run:
                        dst.unlink()

    if not dry_run:
        (target / MARKER).write_text(version + "\n", encoding="utf-8")
    print(f"  {'预演' if dry_run else '完成'}：更新 {copied} 个文件，跳过 {skipped} 个")


def run(cmd, dry_run):
    print("  $ " + " ".join(str(c) for c in cmd))
    if not dry_run:
        try:
            subprocess.run(cmd, check=False)
        except OSError as exc:
            print(f"  ⚠ {exc}")


def windows_registry_value(key, value):
    try:
        out = subprocess.run(["reg", "query", key, "/v", value],
                             capture_output=True, text=True, check=False).stdout
    except OSError:
        return None
    for line in out.splitlines():
        parts = line.split()
        if len(parts) >= 3 and parts[0].lower() == value.lower():
            return " ".join(parts[2:])
    return None


def windows_weasel():
    root = windows_registry_value(r"HKLM\SOFTWARE\WOW6432Node\Rime\Weasel", "WeaselRoot")
    server = windows_registry_value(r"HKLM\SOFTWARE\WOW6432Node\Rime\Weasel", "ServerExecutable")
    if root and server:
        server_path = Path(root) / server
        return server_path, server_path.with_name("WeaselDeployer.exe")
    local = os.environ.get("LOCALAPPDATA")
    if local:
        base = Path(local) / "Programs/Rime/weasel-x64"
        if (base / "WeaselServer.exe").exists():
            return base / "WeaselServer.exe", base / "WeaselDeployer.exe"
    return None, None


def deploy(profile, dry_run, restart):
    kind = profile["kind"]
    path = profile["path"]
    system = platform.system()
    if kind == "squirrel" and system == "Darwin":
        squirrel = Path("/Library/Input Methods/Squirrel.app/Contents/MacOS/Squirrel")
        if squirrel.exists():
            run([str(squirrel), "--reload"], dry_run)
        else:
            shared = "/Library/Input Methods/Squirrel.app/Contents/SharedSupport"
            deployer = "/Library/Input Methods/Squirrel.app/Contents/MacOS/rime_deployer"
            if Path(deployer).exists():
                run([deployer, "--build", str(path), shared], dry_run)
        return
    if kind == "fcitx5" and system == "Darwin":
        curl = Path("/Library/Input Methods/Fcitx5.app/Contents/bin/fcitx5-curl")
        if curl.exists():
            run([str(curl), "/config/addon/rime/deploy", "-X", "POST", "-d", "{}"], dry_run)
        elif restart:
            run(["killall", "Fcitx5"], dry_run)
            run(["open", "/Library/Input Methods/Fcitx5.app"], dry_run)
        else:
            print("  提示：未找到 fcitx5-curl，请手动重新部署")
        return
    if kind == "cobra" and system == "Darwin":
        if restart:
            run(["killall", "Cobra"], dry_run)
            run(["open", "/Library/Input Methods/Cobra.app"], dry_run)
        else:
            print("  提示：元书需要重新部署，或加 --restart")
        return
    if kind == "weasel" and system == "Windows":
        server, deployer = windows_weasel()
        if server and server.exists():
            run([str(server), "/q"], dry_run)
            if not dry_run:
                time.sleep(0.5)
        if deployer and deployer.exists():
            run([str(deployer), "/deploy"], dry_run)
        else:
            print("  提示：未找到 WeaselDeployer.exe，请手动重新部署")
        if server and server.exists():
            if not dry_run:
                time.sleep(0.5)
                subprocess.Popen([str(server)])
            print(f"  $ {server}")
        return
    print("  提示：未知前端，请手动重新部署")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", help="本地 zip 或下载 URL")
    parser.add_argument("--version", help="指定 tag（默认 latest）")
    parser.add_argument("--target", action="append", default=[], help="手动指定用户目录（可重复）")
    parser.add_argument("--check", action="store_true", help="只检查版本，不下载")
    parser.add_argument("--list-profiles", action="store_true", help="列出识别到的用户目录")
    parser.add_argument("--deploy", action="store_true", help="执行部署命令")
    parser.add_argument("--restart", action="store_true", help="重启前端（配合 --deploy）")
    parser.add_argument("--dry-run", action="store_true", help="只打印动作")
    parser.add_argument("--yes", action="store_true", help="不询问确认")
    parser.add_argument("--proxy", help="HTTP/SOCKS5 代理，例如 socks5://127.0.0.1:1080")
    parser.add_argument("--cache-dir", help="下载缓存目录")
    parser.add_argument("--no-cache", action="store_true", help="不使用缓存")
    args = parser.parse_args()

    profiles = []
    if args.target:
        for item in args.target:
            p = Path(item).expanduser()
            kind = "unknown"
            if p.is_dir() and looks_like_rime_dir(p):
                profiles.append({"label": p.name, "path": p, "kind": kind})
    else:
        profiles = detect_profiles()
    if not profiles:
        sys.exit("✗ 没有找到 Rime 用户目录；用 --target 手动指定")

    if args.list_profiles:
        for p in profiles:
            print(f"{p['label']:<8} {p['path']}  当前={read_local_version(p['path']) or '未知'}")
        return

    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    opener = make_opener(args.proxy)
    cache_dir = Path(args.cache_dir).expanduser() if args.cache_dir else default_cache_dir()
    if not args.no_cache:
        cache_dir.mkdir(parents=True, exist_ok=True)

    release = None
    asset = None
    version = args.version
    zip_path = None
    expected = None

    if not args.source:
        try:
            release = github_release(version, token)
        except Exception as exc:
            sys.exit(f"✗ 无法访问 GitHub Release：{exc}\n  私有仓库请设置 GITHUB_TOKEN/GH_TOKEN，或用 --source 指定 zip")
        asset, _ = pick_asset(release)
        version = (release.get("tag_name") or version).lstrip("v")

    if args.check:
        print("识别到的用户目录：")
        for p in profiles:
            print(f"  {p['label']:<8} 当前={read_local_version(p['path']) or '未知'}  {p['path']}")
        if release:
            print(f"远端最新：v{version}（{asset['name']}）")
        return

    if args.source:
        src = Path(args.source).expanduser()
        if src.exists():
            zip_path = str(src)
            sidecar = Path(str(src) + ".sha256")
            if sidecar.exists():
                expected = read_sha256(sidecar)
            else:
                print("⚠ 本地包旁边没有 .sha256，跳过哈希校验")
        else:
            name = Path(urllib.parse.urlparse(args.source).path).name or "download.zip"
            out = cache_dir / name
            print(f"下载 {args.source} ...")
            zip_path = download(args.source, token, str(out), opener)
            if not zip_path:
                sys.exit("✗ 下载或校验失败")
    else:
        assets = release.get("assets") or []
        sha_asset = next((a for a in assets if a.get("name") == asset["name"] + ".sha256"), None)
        if sha_asset:
            sha_path = cache_dir / sha_asset["name"]
            if not sha_path.exists():
                print(f"下载 {sha_asset['name']} ...")
                if not download(sha_asset["browser_download_url"], token, str(sha_path), opener):
                    sys.exit("✗ SHA256 文件下载失败")
            expected = read_sha256(sha_path)

        out = cache_dir / asset["name"]
        if not args.no_cache and out.exists():
            if expected and verify_hash(out, expected):
                print(f"复用缓存 {out}")
                zip_path = str(out)
            elif not expected and asset.get("size") and out.stat().st_size == asset["size"]:
                print(f"复用缓存 {out}（尺寸一致）")
                zip_path = str(out)
            else:
                out.unlink(missing_ok=True)
        if not zip_path:
            print(f"下载 {asset['name']} ...")
            zip_path = download(asset["browser_download_url"], token, str(out), opener, expected)
            if not zip_path:
                sys.exit("✗ 下载或校验失败")

    # 从包内推断版本
    if not version:
        with zipfile.ZipFile(zip_path) as zf:
            prefix = zip_prefix(zf)
            delta_name = prefix + "DELTA.json"
            if prefix.startswith("芝士虎整-v"):
                version = prefix[len("芝士虎整-v"):].strip("/")
            elif delta_name in zf.namelist():
                delta = json.loads(zf.read(delta_name))
                version = str(delta.get("to", "")).lstrip("v")
    version = (version or "unknown").lstrip("v")

    print(f"目标版本：v{version}")
    for p in profiles:
        print(f"  {p['label']:<8} {p['path']}（当前 {read_local_version(p['path']) or '未知'}）")
    if not args.yes and sys.stdin.isatty():
        if input("继续？[y/N] ").strip().lower() not in ("y", "yes"):
            return

    for p in profiles:
        print(f"\n[{p['label']}] {p['path']}")
        apply_zip(zip_path, p["path"], version, args.dry_run, expected)
        if args.deploy:
            deploy(p, args.dry_run, args.restart)


if __name__ == "__main__":
    main()
