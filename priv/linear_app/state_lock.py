"""Host-local locks for issue ownership and comment journal transactions."""
import contextlib
import fcntl
import hashlib
import json
import os
import stat
import sys
import time


class StateLockError(Exception):
    """Fixed public lock error."""


@contextlib.contextmanager
def state_lock(service, account, timeout=10, root=None):
    # A fixed host-local identity, independent of TMPDIR/release/workflow paths.
    root = root or ("/private/tmp" if sys.platform == "darwin" else "/tmp")
    directory = os.path.join(root, "symphony-linear-" + str(os.getuid()))
    try:
        os.mkdir(directory, 0o700)
    except FileExistsError:
        pass
    info = os.lstat(directory)
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
        raise StateLockError("unsafe_lock_directory")
    identity = hashlib.sha256(json.dumps([service, account]).encode()).hexdigest()
    fd = os.open(os.path.join(directory, identity), os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600:
            raise StateLockError("unsafe_lock_file")
        deadline = time.monotonic() + timeout
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise StateLockError("binding_busy")
                time.sleep(0.02)
        yield
    finally:
        # Never unlink a lock file: waiters must continue using the same inode.
        os.close(fd)
