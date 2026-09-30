"""Trusted openat boundary for the Lean scoped temporary-file interpreter.

All descendants are opened without following symlinks. Writes replace a fresh
inode atomically; reads reject hard links. Never accepts executable source.
"""
import json
import os
import stat
import sys
import secrets


def execute(request):
    root, org, user, operation, parts = (request[k] for k in
        ("root", "org", "user", "operation", "parts"))
    # Defense in depth at the syscall boundary, in addition to Lean witnesses.
    if not parts or any(not p or p in (".", "..") or "/" in p or "\\" in p or "\0" in p for p in parts):
        raise ValueError("invalid relative path")
    if any(not s or any(not (c.isascii() and (c.isalnum() or c in "-_")) for c in s) for s in (org, user)):
        raise ValueError("invalid binding")
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    # root is server configuration, never notebook input. Only its parent may
    # be a system symlink (/tmp on macOS); the root itself may not be one.
    base, leaf = os.path.split(root.rstrip("/"))
    fd = os.open(base, os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in [leaf, org, user] + parts[:-1]:
            if operation == "write":
                try:
                    os.mkdir(part, 0o700, dir_fd=fd)
                except FileExistsError:
                    pass
            child = os.open(part, flags, dir_fd=fd)
            info = os.fstat(child)
            if info.st_uid != os.geteuid() or info.st_mode & 0o022:
                os.close(child)
                raise PermissionError("temporary directory has unsafe ownership/mode")
            os.close(fd)
            fd = child
        name = parts[-1]
        if operation == "read":
            source = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
            with os.fdopen(source, "rb") as stream:
                info = os.fstat(stream.fileno())
                if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
                    raise PermissionError("only single-link regular files may be read")
                contents = stream.read(16777217)
                if len(contents) > 16777216:
                    raise ValueError("temporary file exceeds size limit")
                return contents.hex()
        if operation == "write":
            contents = bytes.fromhex(request["contents"])
            if len(contents) > 16777216:
                raise ValueError("temporary file exceeds size limit")
            temp = ".lun-" + secrets.token_hex(16)
            target = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=fd)
            try:
                with os.fdopen(target, "wb") as stream:
                    stream.write(contents)
                os.replace(temp, name, src_dir_fd=fd, dst_dir_fd=fd)
            finally:
                try:
                    os.unlink(temp, dir_fd=fd)
                except FileNotFoundError:
                    pass
            return ""
        if operation == "delete":
            # unlinkat never dereferences the final component.
            os.unlink(name, dir_fd=fd)
            return ""
        raise ValueError("unsupported temporary operation")
    finally:
        os.close(fd)


def main():
    try:
        print(json.dumps({"contents": execute(json.load(sys.stdin))}))
    except Exception:
        # Never echo paths, file contents, environment, or Python tracebacks.
        print(json.dumps({"error": "scoped temporary-file operation refused"}))
        sys.exit(1)


if __name__ == "__main__":
    main()
