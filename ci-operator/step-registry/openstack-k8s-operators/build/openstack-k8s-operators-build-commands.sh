#!/usr/bin/env bash

set -ex

export ds_test_host='10.46.4.143' #titan134
ping -c 30 $ds_test_host
