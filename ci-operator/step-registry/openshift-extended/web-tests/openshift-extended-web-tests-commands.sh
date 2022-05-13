#!/bin/bash

pwd && ls -ltr
cd frontend || exit 0
./console-test-frontend.sh || exit 0
