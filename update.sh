#!/usr/bin/env bash
# Download to disk, inspect, then run; never pipe remote content into a root shell.
set -Eeuo pipefail
set +x
exec python3 -I - "$@" <<'PY'
import argparse
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

REPO = "netwizd/nlzero-releases"
LATEST = "https://api.github.com/repos/" + REPO + "/releases/latest"
DOWNLOAD = "https://github.com/" + REPO + "/releases/download/"
MAX_ARTIFACT = 1 << 30
INSTALLING = False

VERSION = re.compile(r"(?:0|[1-9][0-9]{0,8})\.(?:0|[1-9][0-9]{0,8})\.(?:0|[1-9][0-9]{0,8})\Z")


def fail(message):
    raise RuntimeError(message)


def version(value):
    if not isinstance(value, str) or not VERSION.fullmatch(value):
        fail("Некорректная стабильная версия выпуска")
    return tuple(int(part) for part in value.split("."))


def safe_url(value, metadata=False):
    if not isinstance(value, str) or len(value) > 8192 or any(ord(c) < 33 for c in value):
        fail("Некорректный URL GitHub")
    parsed = urllib.parse.urlsplit(value)
    if parsed.scheme != "https" or parsed.username is not None or parsed.password is not None or parsed.fragment:
        fail("Разрешены только HTTPS-адреса GitHub без credentials")
    if parsed.port not in (None, 443):
        fail("Неожиданный порт GitHub")
    if metadata:
        if value != LATEST:
            fail("Неожиданный API URL")
    elif parsed.hostname == "github.com":
        if not parsed.path.startswith("/" + REPO + "/releases/download/"):
            fail("Неожиданный репозиторий скачивания")
    elif parsed.hostname not in ("release-assets.githubusercontent.com", "objects.githubusercontent.com"):
        fail("Перенаправление за пределы GitHub запрещено")
    return value


class Redirects(urllib.request.HTTPRedirectHandler):
    max_redirections = 5
    max_repeats = 2

    def redirect_request(self, request, response, code, message, headers, newurl):
        if request.full_url == LATEST:
            fail("API GitHub не должен перенаправлять запрос")
        safe_url(newurl)
        return super().redirect_request(request, response, code, message, headers, newurl)


def fetch(url, destination=None, limit=1 << 20, expected_size=None):
    safe_url(url, metadata=(url == LATEST))
    request = urllib.request.Request(url, headers={"User-Agent": "nlzero-customer-updater/1", "Accept": "application/vnd.github+json" if url == LATEST else "application/octet-stream"})
    if url == LATEST:
        request.add_header("X-GitHub-Api-Version", "2026-03-10")
    opener = urllib.request.build_opener(Redirects())
    deadline = time.monotonic() + (4 * 3600 if limit > (1 << 20) else 60)
    total = 0
    chunks = []
    with opener.open(request, timeout=30) as response:
        if response.status != 200:
            fail("GitHub вернул неожиданный HTTP-статус")
        length = response.headers.get("Content-Length")
        if length is not None and (not length.isdecimal() or int(length) > limit or (expected_size is not None and int(length) != expected_size)):
            fail("Размер ответа GitHub не соответствует ограничениям")
        with (open(destination, "xb") if destination is not None else contextlib.nullcontext()) as output:
            while True:
                if time.monotonic() > deadline:
                    fail("Истекло время скачивания")
                chunk = response.read1(min(256 << 10, limit - total + 1))
                if time.monotonic() > deadline:
                    fail("Истекло время скачивания")
                if not chunk:
                    break
                total += len(chunk)
                if total > limit:
                    fail("Ответ GitHub превышает допустимый размер")
                if output is not None:
                    output.write(chunk)
                else:
                    chunks.append(chunk)
    if total == 0 or (expected_size is not None and total != expected_size):
        fail("Скачивание неполное или размер ответа изменился")
    return b"".join(chunks)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            fail("Повторяющееся поле JSON")
        result[key] = value
    return result


def document(raw):
    return json.loads(raw, object_pairs_hook=unique_object)


def latest_release(raw, installed_version=None):
    data = document(raw)
    if not isinstance(data, dict) or data.get("draft") is not False or data.get("prerelease") is not False:
        fail("GitHub вернул неподходящий выпуск")
    tag = data.get("tag_name")
    if not isinstance(tag, str):
        fail("Отсутствует тег выпуска")
    candidate = tag[1:] if tag.startswith("v") else tag
    version(candidate)
    if data.get("html_url") != "https://github.com/" + REPO + "/releases/tag/" + tag:
        fail("Неожиданный адрес страницы выпуска")
    if installed_version is not None and version(candidate) <= version(installed_version):
        return candidate, {}
    assets = data.get("assets")
    if not isinstance(assets, list) or len(assets) > 100:
        fail("Некорректный список файлов выпуска")
    expected = {}
    for component in ("core", "agent"):
        expected["nlzero-" + component + "-" + candidate + "-linux-amd64.tar.gz"] = MAX_ARTIFACT
        expected["nlzero-" + component + "-" + candidate + ".manifest.json"] = 64 << 10
    selected = {}
    for asset in assets:
        if not isinstance(asset, dict):
            fail("Некорректный файл выпуска")
        name = asset.get("name")
        if not isinstance(name, str):
            fail("Некорректное имя файла выпуска")
        if name not in expected:
            continue
        size = asset.get("size")
        url = DOWNLOAD + tag + "/" + name
        if name in selected or type(size) is not int or not 0 < size <= expected[name] or asset.get("state") != "uploaded" or asset.get("browser_download_url") != url:
            fail("Некорректные метаданные component-файла")
        selected[name] = (url, size, expected[name])
    if set(selected) != set(expected):
        fail("В выпуске отсутствуют core/agent архивы или подписанные манифесты")
    return candidate, selected


def trusted_path(path):
    path = Path(path)
    for item in (path, *path.parents):
        info = item.lstat()
        if stat.S_ISLNK(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
            fail("Небезопасный установленный доверенный путь: " + str(item))
    return path


def installed():
    current = Path("/opt/nlzero/current")
    if not current.is_symlink() or current.lstat().st_uid != 0:
        fail("Не обнаружена установленная система core")
    root = current.resolve(strict=True)
    if not re.fullmatch(r"/opt/nlzero/releases/[0-9a-f]{40}", str(root)):
        fail("Неожиданный путь установленного core")
    trusted_path(root)
    verifier = trusted_path(root / "bin/nlzero-release-verify")
    trust = trusted_path(Path("/etc/credstore/release-public-keys"))
    buildinfo = trusted_path(root / "BUILDINFO")
    if not verifier.is_file() or not os.access(verifier, os.X_OK) or not trust.is_file() or not buildinfo.is_file():
        fail("Не найдены установленный verifier, trust или BUILDINFO")
    values = metadata(buildinfo.read_text())
    version(values.get("version"))
    return values["version"], verifier, trust


def metadata(text):
    values = {}
    for line in text.splitlines():
        key, separator, value = line.partition("=")
        if not separator or key in values:
            fail("Некорректный BUILDINFO")
        values[key] = value
    return values


def create_workspace():
    state = trusted_path(Path("/var/lib/nlzero"))
    parent = state / "update-staging"
    if parent.exists() or parent.is_symlink():
        trusted_path(parent)
        if not parent.is_dir() or stat.S_IMODE(parent.stat().st_mode) != 0o700:
            fail("update-staging должен принадлежать root и иметь права 0700")
    else:
        parent.mkdir(mode=0o700)
        trusted_path(parent)
    return Path(tempfile.mkdtemp(prefix=".github-update.", dir=parent))


def verified_identity(manifest, component, candidate):
    # Read claims only to supply identity to the INSTALLED verifier, which checks
    # the signature and binds this exact component/version/commit to the archive.
    data = document(manifest.read_bytes())
    claims = data.get("payload") if isinstance(data, dict) else None
    if not isinstance(claims, dict) or claims.get("component") != component or claims.get("version") != candidate or claims.get("channel") != "stable":
        fail("Идентичность подписанного компонента не совпадает с выпуском")
    commit = claims.get("commit")
    if not isinstance(commit, str) or not re.fullmatch("[0-9a-f]{40}", commit):
        fail("Некорректный commit компонента")
    return commit


def reconstruct(workspace, candidate, verifier, trust):
    distribution = workspace / "distribution"
    payload = distribution / ".payload"
    payload.mkdir(parents=True, mode=0o755)
    commits = []
    for component in ("core", "agent"):
        archive = workspace / ("nlzero-" + component + "-" + candidate + "-linux-amd64.tar.gz")
        manifest = workspace / ("nlzero-" + component + "-" + candidate + ".manifest.json")
        commit = verified_identity(manifest, component, candidate)
        subprocess.run([str(verifier), "--trust", str(trust), "--manifest", str(manifest), "--artifact", str(archive), "--component", component, "--version", candidate, "--commit", commit, "--target", "linux/amd64"], check=True, timeout=900)
        commits.append(commit)
        # Same filesystem, private root-owned paths: avoid another archive copy.
        os.link(archive, payload / (component + ".tar.gz"))
        shutil.copyfile(manifest, payload / (component + ".manifest.json"))
    if commits[0] != commits[1]:
        fail("Core и agent относятся к разным commit")
    selected = {
        "deploy/customer-install.sh": ("install.sh", 0o755),
        "deploy/customer-update.sh": ("update.sh", 0o755),
        "HOW_TO_INSTALL.md": ("HOW_TO_INSTALL.md", 0o644),
        "LICENSE.ru.md": (".payload/LICENSE.ru.md", 0o644),
        "THIRD_PARTY_NOTICES.md": (".payload/THIRD_PARTY_NOTICES.md", 0o644),
        "bin/nlzero-release-verify": (".payload/nlzero-release-verify", 0o755),
        "BUILDINFO": (".payload/BUILDINFO", 0o644),
    }
    seen = set()
    with tarfile.open(payload / "core.tar.gz", "r:gz") as archive:
        for member in archive:
            relative = member.name.removeprefix("nlzero-linux-amd64/")
            if relative not in selected:
                continue
            if relative in seen or not member.isfile() or not 0 < member.size <= (64 << 20):
                fail("Некорректный файл в проверенном core")
            seen.add(relative)
            target, mode = selected[relative]
            with archive.extractfile(member) as source, open(distribution / target, "xb") as output:
                shutil.copyfileobj(source, output, 256 << 10)
            (distribution / target).chmod(mode)
    if seen != set(selected):
        fail("В подписанном core нет installer/updater или обязательных документов")
    info = metadata((payload / "BUILDINFO").read_text())
    if info.get("version") != candidate or info.get("commit") != commits[0]:
        fail("BUILDINFO не соответствует проверенным манифестам")
    (payload / "BUILDINFO").unlink()
    shutil.copyfile(trust, payload / "release-public-keys.json")
    (payload / "RELEASE").write_text("VERSION=" + candidate + "\nCOMMIT=" + commits[0] + "\n")
    checksums = []
    for path in sorted(distribution.rglob("*")):
        if path.is_file():
            with open(path, "rb") as source:
                digest = hashlib.file_digest(source, "sha256").hexdigest()
            checksums.append(digest + "  " + str(path.relative_to(distribution)) + "\n")
    (payload / "SHA256SUMS").write_text("".join(checksums))
    return distribution / "install.sh"


@contextlib.contextmanager
def update_locks():
    with contextlib.ExitStack() as stack:
        locks = []
        for name in ("/run/nlzero-github-update.lock", "/run/nlzero-install.lock"):
            fd = os.open(name, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
            lock = stack.enter_context(os.fdopen(fd, "w"))
            if not stat.S_ISREG(os.fstat(fd).st_mode) or os.fstat(fd).st_uid != 0 or os.fstat(fd).st_mode & 0o022:
                fail("Небезопасный файл блокировки обновления")
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                fail("Другая установка или обновление уже выполняется")
            locks.append(lock)
        yield locks


def interrupted(signum, frame):
    if INSTALLING:
        print("Обновление core выполняется; дождитесь завершения безопасной установки.", file=sys.stderr, flush=True)
        return
    fail("Обновление прервано до установки")


def main(arguments=None):
    global INSTALLING
    parser = argparse.ArgumentParser(description="Проверить GitHub и обновить установленный core nlzero")
    parser.add_argument("--check", action="store_true", help="только проверить выпуск; не скачивать архивы и не менять систему")
    args = parser.parse_args(arguments)
    if os.geteuid() != 0:
        fail("Запустите sudo ./update.sh [--check]")
    os.umask(0o077)
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    current, verifier, trust = installed()
    candidate, assets = latest_release(fetch(LATEST), current)
    comparison = version(candidate) > version(current)
    print("Установлена " + current + "; GitHub latest stable: " + candidate + ".", flush=True)
    if not comparison:
        print("Более новой версии нет. Система не изменена.")
        return 0
    if args.check:
        print("Доступно обновление. Запустите sudo ./update.sh для установки.")
        return 0
    workspace = None
    try:
        with update_locks() as locks:
            workspace = create_workspace()
            if shutil.disk_usage(workspace).free < max(2 << 30, sum(asset[1] for asset in assets.values()) * 3):
                fail("Недостаточно места для обновления в /var/lib/nlzero (нужно не менее 2 GiB плюс место для checkpoint)")
            for name, (url, size, limit) in assets.items():
                print("Скачивание " + name, flush=True)
                fetch(url, workspace / name, limit, size)
            installer = reconstruct(workspace, candidate, verifier, trust)
            # The authenticated installer takes this same lock and rechecks the
            # installed version/health/trust. The separate updater lock stays held.
            fcntl.flock(locks[1], fcntl.LOCK_UN)
            # Terminal Ctrl-C must not interrupt checkpoint/migrations. The
            # noninteractive authenticated installer has its own process session.
            INSTALLING = True
            try:
                subprocess.run([str(installer), "update"], check=True, start_new_session=True)
            finally:
                INSTALLING = False
            print("Component-архивы и подписанные манифесты для каталога/нод: https://github.com/" + REPO + "/releases/tag/" + candidate, flush=True)
            print("Импортируйте их в разделе «Релизы» и запустите preflight; временные загрузки будут удалены.", flush=True)
        return 0
    finally:
        if workspace is not None:
            shutil.rmtree(workspace)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, OSError, ValueError, subprocess.SubprocessError, tarfile.TarError, urllib.error.URLError) as error:
        print("Обновление остановлено: " + str(error), file=sys.stderr)
        sys.exit(1)
PY
