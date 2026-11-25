#!/bin/bash

for filename in $(pwd)/*.yaml; do
  python3 tools/update-cron-entries.py --backup no $filename
done


