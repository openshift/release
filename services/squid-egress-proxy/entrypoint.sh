#!/bin/bash

cat <<EOF
This is squid version $(squid version).
To use this image, mount a squid configfile and start squid with
squid -N -f /path/to/squid.conf
EOF
