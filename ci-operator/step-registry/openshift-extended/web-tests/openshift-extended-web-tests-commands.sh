#!/bin/bash

pwd && ls -ltr
cd frontend || exit 0
./console-test-frontend.sh || exit 0
echo "running python parse"
pwd && ls -ltr
python3 parse-xml.py
cat console-cypress.xml
