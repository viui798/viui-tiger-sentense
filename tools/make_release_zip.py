#!/usr/bin/env python3
"""生成 GitHub Release 用的完整包（解压即可用的 Rime 用户目录内容）。

用法：
    python3 tools/make_release_zip.py <tag|ref> <输出 zip 路径>

例：
    python3 tools/make_release_zip.py v0.2.3 ../cheese-tiger-v0.2.3.zip

规则：
  · 文件清单以 git 中该 ref 为准，保证与 tag 内容一致；
  · 文件内容也从该 ref 读取（git show <ref>:<path>），保证可复现；
    唯一的例外是走 Git LFS 的大模型——git 里只有指针，必须从工作区取真实文件；
  · 排除开发资料（tools/ sync/ validation/）、上游原包身份文件、
    以及手机精简版/（那是附加内容，不进发行包）；
  · 不含任何用户数据——学习库、tiger_sentence.options.yaml、custom_phrase.txt
    等本来就不在仓库里；
  · 额外加入打包时生成的《安装说明.txt》；
  · 文件名写 UTF-8 标志位，Windows 与 macOS 解压都不会乱码；
  · 同时输出同名 .sha256 文件。

注意：模型 models/sentence-fivegram-mobile.bin 在 git 里是 LFS 指针，
      所以必须从工作区读取真实文件，不能用 git archive。
"""

import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
import zipfile

# 不进发行包的文件/目录
EXCLUDE_FILES = {
    ".gitignore",
    ".gitattributes",
    "RELEASE.json",
    "SHA256SUMS.txt",
    "SOURCE_BASELINE.md",
    "RIME_CORRECTNESS.md",
    "IOS_TEST_README.md",
}
EXCLUDE_DIRS = (
    "tools/",          # 开发/测试脚本（含本脚本）
    "sync/",           # 上游同步补丁
    "validation/",     # 上游校验日志
    "手机精简版/",      # 手机端附加内容，不进发行包
)

# 万象拼音词库已不再被虎单/虎词/虎整句使用（反查统一走五阶模型 +
# pinyin.qp.codes.txt 分页索引），保留在仓库便于回滚，但不进发行包。
EXCLUDE_SEGMENTS = (
    "wanxiang_pro",            # wanxiang_pro / _qp / _zrm / _mspy / _sogou
    "dicts/jichu.pro",         # 万象基础词库（约 61MB）
    "dicts/lianxiang.pro",     # 联想词库（约 13MB）
    "dicts/shici.pro",         # 诗词词库（约 22MB）
    "dicts/diming.pro",        # 地名词库
    "dicts/duoyin.pro",        # 多音兼容词库
    "dicts/zi.pro",            # 万象字表
    "dicts/cuoyin.pro",        # 错音错字
    "zuci/moegirl",            # 萌娘词库（仅万象使用）
    "zuci/ext",                # 扩展词库（仅万象使用）
)

INSTALL_NOTE = """芝士虎整 {version} 安装说明
{underline}

一、目录对应关系
  解压后文件夹里的内容，直接对应 Rime 的“用户文件夹”，例如
    鼠须管（macOS）：~/Library/Rime
    小狼毫（Windows）：%APPDATA%\\Rime
  不要把整个文件夹再套一层复制进去，复制的是它里面的文件。

二、安装
  1. 关闭输入法前端。
  2. 把本包内容复制进 Rime 用户文件夹（已有配置请先备份）。
  3. 在输入法菜单里执行“重新部署”，并完全退出重启前端
     （Lua 模块按进程缓存，不重启不会重新加载）。
  4. 从方案菜单切换到虎单、虎词或虎整句。

三、验收抽查
  - 方案菜单：应只有虎单、虎词、虎整句三个方案（旧版万象拼音已移除）。
  - 虎整句：输入 ujkf 看候选；方案菜单把按键纠错调到“强”，
    点一次“捡”后再输入 ujkf，应变成“捡”排在第一位。
  - Shift 大写：中文态按 Shift 再打字母，直接上屏大写（如 Shift+a → A）。
  - 顶字：虎单/虎词输入 rjk; 应输出“符；”（rjk 只有唯一候选时）。
  - 拼音反查：虎单/虎词/虎整句输入 `nihao 都应出现“你好”；切换打法用
    /flypy（小鹤，默认）/pinyin（全拼）/zrm（自然码）/mspy（微软）/sogou（搜狗）。
  - 混输：虎整句输入 je`jiyubeuegmmup，首选应为“他觊觎她的美貌”。
  - 短输入反查调频：反查 `jiyu 时用 Tab 选一个非首选词上屏；再次输入 `jiyu，
    该词应排第一（记录在用户目录 reverse_freq.txt，删除即清空）。
  - 自造词：单引号 + 编码造词（如 'uawl）；编码后加 / 删词。
  - 快符：;a；输入统计：//1。

四、说明
  - 本包不含个人数据。学习库、方案选项（tiger_sentence.options.yaml）、
    custom_phrase.txt、reverse_freq.txt、各前端皮肤配置都属于用户数据，升级时请自行保留。
  - 包内体积主要来自 models/sentence-fivegram-mobile.bin（约 387MB），
    虎整句与拼音反查都需要它；请勿删除 models/。
  - 旧版万象反查词库自 v0.3.10 起不再随包发布，升级后无需再编译 wanxiang_pro 拼写索引；
    用户目录里残留的 wanxiang_pro*.yaml 与 dicts/*.pro.dict.yaml 可手动删除。
  - 更新内容见 CHANGELOG.md 与 docs/ 下的更新说明。
"""


def git(*args):
    return subprocess.run(["git", "-c", "core.quotepath=false", *args],
                          capture_output=True, text=True, check=True).stdout


def lfs_paths(paths):
    """返回其中由 Git LFS 管理的路径（它们在 git 里只有指针）。"""
    if not paths:
        return set()
    proc = subprocess.run(["git", "-c", "core.quotepath=false",
                           "check-attr", "-z", "filter", "--", *paths],
                          capture_output=True, check=True)
    fields = proc.stdout.decode("utf-8", "surrogateescape").split("\0")
    found = set()
    for i in range(0, len(fields) - 2, 3):
        if fields[i + 1] == "filter" and fields[i + 2] == "lfs":
            found.add(fields[i])
    return found


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    ref, out_zip = sys.argv[1], os.path.abspath(sys.argv[2])
    repo = git("rev-parse", "--show-toplevel").strip()
    os.chdir(repo)

    # 附注标签用 rev-parse 得到的是 tag 对象，这里统一取它指向的提交再比较
    ref_sha = git("rev-parse", f"{ref}^{{commit}}").strip()
    head_sha = git("rev-parse", "HEAD").strip()
    if ref_sha != head_sha:
        print(f"⚠ {ref} 与 HEAD 不是同一个提交；文件内容将从工作区读取，请自行确认。")

    version = ref
    if not ref.startswith("v"):
        try:  # 传的是 HEAD / commit 时，尽量取出对应的 tag 名当版本号
            version = git("describe", "--tags", "--exact-match", ref).strip()
        except subprocess.CalledProcessError:
            described = git("describe", "--tags", "--always", ref).strip()
            version = described if described.startswith("v") else "v" + described
    files = [f for f in git("ls-tree", "-r", "--name-only", ref).splitlines() if f]
    kept = [f for f in files
            if f not in EXCLUDE_FILES and not f.startswith(EXCLUDE_DIRS)
            and not any(segment in f for segment in EXCLUDE_SEGMENTS)]
    dropped = sorted(set(files) - set(kept))

    lfs = lfs_paths(kept)
    stage = tempfile.mkdtemp(prefix="cheese-tiger-release-")
    root = os.path.join(stage, f"芝士虎整-{version}")
    for rel in kept:
        dst = os.path.join(root, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        if rel in lfs:
            src = os.path.join(repo, rel)
            if not os.path.exists(src):
                sys.exit(f"✗ 工作区缺少 LFS 文件：{rel}（需要先 git lfs pull）")
            if os.path.getsize(src) < 1024:
                sys.exit(f"✗ {rel} 看起来还是 LFS 指针，不是真实文件")
            shutil.copy2(src, dst)
            print(f"  LFS 文件取自工作区：{rel}（{os.path.getsize(src)} 字节）")
        else:
            data = subprocess.run(["git", "show", f"{ref}:{rel}"],
                                  capture_output=True, check=True).stdout
            with open(dst, "wb") as fh:
                fh.write(data)

    note = INSTALL_NOTE.format(version=version, underline="=" * (len(version) + 13))
    with open(os.path.join(root, "安装说明.txt"), "w", encoding="utf-8") as fh:
        fh.write(note)

    entries = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        filenames.sort()
        rel_dir = os.path.relpath(dirpath, stage).replace(os.sep, "/")
        entries.append((rel_dir + "/", None))
        for name in filenames:
            full = os.path.join(dirpath, name)
            entries.append((os.path.relpath(full, stage).replace(os.sep, "/"), full))

    os.makedirs(os.path.dirname(out_zip) or ".", exist_ok=True)
    with zipfile.ZipFile(out_zip, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        for name, path in entries:
            if path is None:
                info = zipfile.ZipInfo(name)
                info.external_attr = (0o40755 << 16) | 0x10
                archive.writestr(info, b"")
            else:
                archive.write(path, name)

    digest = hashlib.sha256()
    with open(out_zip, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            digest.update(chunk)
    sha = digest.hexdigest()
    with open(out_zip + ".sha256", "w", encoding="utf-8") as fh:
        fh.write(f"{sha}  {os.path.basename(out_zip)}\n")

    shutil.rmtree(stage, ignore_errors=True)
    print(f"版本: {version}")
    print(f"打包 {len(kept) + 1} 个文件（含生成的《安装说明.txt》）")
    print(f"排除 {len(dropped)} 个：")
    for rel in dropped:
        print(f"  - {rel}")
    print(f"输出: {out_zip}")
    print(f"SHA256: {sha}")


if __name__ == "__main__":
    main()
