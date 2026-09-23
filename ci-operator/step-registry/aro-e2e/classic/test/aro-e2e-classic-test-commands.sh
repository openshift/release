#!/bin/bash

oc version
oc --insecure-skip-tls-verify get nodes -o wide
