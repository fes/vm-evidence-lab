#!/usr/bin/env python3
"""Render the unattended-install seed ISOs for the Linux and Windows guests.

The seeds hold the evidence account password, so write them to a private
directory outside any source checkout. See docs/PROVISIONING.md.
"""
import argparse
import hashlib
import os
import secrets
import shutil
import stat
import subprocess
import sys
from pathlib import Path
from xml.sax.saxutils import escape

HERE = Path(__file__).resolve().parent
SEEDS = HERE / "seeds"
DEFAULT_TOOLS = Path("/Applications/Parallels Desktop.app/Contents/Resources/Tools")
CRYPT_ALPHABET = "./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
HASH_ROUNDS = 100000


def _b64(data: bytes, order: list[tuple[int, int, int]], tail: tuple[int, ...]) -> str:
    out = []
    for a, b, c in order:
        value = (data[a] << 16) | (data[b] << 8) | data[c]
        out.extend(CRYPT_ALPHABET[(value >> (6 * i)) & 0x3F] for i in range(4))
    value = 0
    for index in tail:
        value = (value << 8) | data[index]
    out.extend(CRYPT_ALPHABET[(value >> (6 * i)) & 0x3F] for i in range(3))
    return "".join(out[:-1])


def sha512_crypt(password: str, salt: str, rounds: int = HASH_ROUNDS) -> str:
    """Return a `$6$` crypt(3) hash, which cloud-init requires for identity.password."""
    key = password.encode()
    salt_bytes = salt.encode()[:16]
    digest_b = hashlib.sha512(key + salt_bytes + key).digest()
    a = hashlib.sha512()
    a.update(key + salt_bytes)
    length = len(key)
    while length > 64:
        a.update(digest_b)
        length -= 64
    a.update(digest_b[:length])
    bit = len(key)
    while bit:
        a.update(digest_b if bit & 1 else key)
        bit >>= 1
    digest_a = a.digest()
    dp = hashlib.sha512(key * len(key)).digest()
    p = (dp * (len(key) // 64 + 1))[: len(key)]
    ds = hashlib.sha512(salt_bytes * (16 + digest_a[0])).digest()
    s = (ds * (len(salt_bytes) // 64 + 1))[: len(salt_bytes)]
    current = digest_a
    for index in range(rounds):
        c = hashlib.sha512()
        c.update(p if index & 1 else current)
        if index % 3:
            c.update(s)
        if index % 7:
            c.update(p)
        c.update(current if index & 1 else p)
        current = c.digest()
    order = [
        (0, 21, 42), (22, 43, 1), (44, 2, 23), (3, 24, 45), (25, 46, 4),
        (47, 5, 26), (6, 27, 48), (28, 49, 7), (50, 8, 29), (9, 30, 51),
        (31, 52, 10), (53, 11, 32), (12, 33, 54), (34, 55, 13), (56, 14, 35),
        (15, 36, 57), (37, 58, 16), (59, 17, 38), (18, 39, 60), (40, 61, 19),
        (62, 20, 41),
    ]
    encoded = _b64(current, order, (63,))
    return f"$6$rounds={rounds}${salt_bytes.decode()}${encoded}"


def render(template: str, values: dict[str, str]) -> str:
    text = (SEEDS / template).read_text(encoding="utf-8")
    for key, value in values.items():
        text = text.replace(f"@{key}@", value)
    if any(f"@{key}@" in text for key in values) or "@EVIDENCE_" in text or "@SSH_" in text:
        raise SystemExit(f"unrendered placeholder in {template}")
    return text


def write_private(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    path.chmod(stat.S_IRUSR | stat.S_IWUSR)


def make_iso(source: Path, label: str, target: Path) -> None:
    target.unlink(missing_ok=True)
    subprocess.run(
        ["hdiutil", "makehybrid", "-iso", "-joliet", "-default-volume-name", label,
         "-o", str(target), str(source)],
        check=True, stdout=subprocess.DEVNULL,
    )
    target.chmod(stat.S_IRUSR | stat.S_IWUSR)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True, type=Path, help="private output directory")
    parser.add_argument("--public-key", required=True, type=Path, help="controller SSH .pub file")
    parser.add_argument("--password-file", required=True, type=Path,
                        help="file holding the evidence account password (0600)")
    parser.add_argument("--windows-edition", default="Windows 11 Pro",
                        help="/IMAGE/NAME of the edition inside the pinned ISO")
    parser.add_argument("--parallels-tools", type=Path, default=DEFAULT_TOOLS)
    args = parser.parse_args()

    mode = args.password_file.stat().st_mode
    if mode & (stat.S_IRWXG | stat.S_IRWXO):
        raise SystemExit(f"{args.password_file} must not be group/world accessible")
    password = args.password_file.read_text(encoding="utf-8").strip()
    if not password:
        raise SystemExit("password file is empty")
    public_key = " ".join(args.public_key.read_text(encoding="utf-8").split()[:2]) + " vm-evidence-lab"
    salt = "".join(secrets.choice(CRYPT_ALPHABET) for _ in range(16))

    out = args.out
    out.mkdir(parents=True, exist_ok=True)
    out.chmod(0o700)

    linux = out / "seed-linux"
    write_private(linux / "user-data", render("linux-user-data.template", {
        "EVIDENCE_PASSWORD_HASH": sha512_crypt(password, salt),
        "SSH_PUBLIC_KEY": public_key.rsplit(" ", 1)[0],
    }))
    write_private(linux / "meta-data", "instance-id: vm-evidence-linux\nlocal-hostname: evidence-linux\n")
    make_iso(linux, "CIDATA", out / "seed-linux.iso")

    windows = out / "seed-windows"
    windows.mkdir(parents=True, exist_ok=True)
    shutil.copy2(args.parallels_tools / "igt_arm64.exe", windows / "IGT_ARM64.exe")
    shutil.rmtree(windows / "prl_tg", ignore_errors=True)
    shutil.copytree(args.parallels_tools / "prl_tg", windows / "prl_tg")
    write_private(windows / "Autounattend.xml", render("windows-Autounattend.xml.template", {
        "EVIDENCE_PASSWORD_XML": escape(password),
        "WINDOWS_EDITION": escape(args.windows_edition),
    }))
    write_private(windows / "setup-evidence.ps1", render("windows-setup-evidence.ps1.template", {
        "SSH_PUBLIC_KEY": public_key.rsplit(" ", 1)[0],
    }))
    make_iso(windows, "WINSEED", out / "seed-windows.iso")

    print(f"Wrote {out}/seed-linux.iso and {out}/seed-windows.iso")
    return 0


if __name__ == "__main__":
    sys.exit(main())
