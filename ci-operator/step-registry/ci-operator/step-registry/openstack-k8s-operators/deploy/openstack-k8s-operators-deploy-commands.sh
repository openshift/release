#!/usr/bin/env bash

set -ex
export ds_test_host='10.46.4.143'
ping -c 3 $ds_test_host