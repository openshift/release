Squid 4.8
====

This service is used to build a Squid 4.8 image for use with the
CI proxy as Squid 3.5 cannot do TLS 1.3 handshakes with Podman.

This may be a stopgap until we can provide a 4.x version as part of our
normal image process https://github.com/openshift/images/tree/master/egress/http-proxy
