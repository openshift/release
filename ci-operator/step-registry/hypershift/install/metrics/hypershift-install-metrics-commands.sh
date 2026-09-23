#!/bin/bash

set -eux

bin/test-setup monitoring \
--remote-write-url="$(cat /etc/grafana-prom-push/url)" \
--remote-write-username-file=/etc/grafana-prom-push/username \
--remote-write-password-file=/etc/grafana-prom-push/password