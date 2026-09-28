"""Read active journal file metadata without opening receipt contents."""

import json
import os
import re
import stat
import sys


SUFFIX = re.compile(r"\.(intent|confirmed|rejected)\.json\Z")


def main(directory):
    try:
        entries = {}
        with os.scandir(directory) as files:
            for file in files:
                if not SUFFIX.search(file.name):
                    continue
                info = file.stat(follow_symlinks=False)
                if not stat.S_ISREG(info.st_mode):
                    return 1
                entries[file.name] = [info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns]
        print(json.dumps(entries, separators=(",", ":")))
        return 0
    except FileNotFoundError:
        if not os.path.exists(directory):
            print("{}")
            return 0
        return 1
    except OSError:
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
