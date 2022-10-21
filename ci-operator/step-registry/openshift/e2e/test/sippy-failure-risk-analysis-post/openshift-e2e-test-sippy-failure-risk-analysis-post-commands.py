#!/bin/env python
import os
import subprocess

result = subprocess.run(['ls', '-l', os.getenv('SHARED_DIR', '/')], stdout=subprocess.PIPE)
print(result.stdout)
