#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Only the greatest stable Git version may update the mutable latest tag."""
import os
import re
import subprocess


def newest_stable(tags):
    versions = [tag for tag in tags if re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", tag)]
    return max(versions, key=lambda tag: tuple(map(int, tag.split('.'))), default=None)


if __name__ == '__main__':
    tags = subprocess.check_output(['git', 'tag', '--list'], text=True).splitlines()
    print('promote=' + str(os.environ['RELEASE_VERSION'] == newest_stable(tags)).lower())
