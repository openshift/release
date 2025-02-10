#!/bin/bash

cp "/secret/.awscreds" "$HOME/.aws/crdentials"
python3 /usr/local/cloud_governance/main.py
