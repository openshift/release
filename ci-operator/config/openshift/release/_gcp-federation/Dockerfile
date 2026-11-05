FROM registry.access.redhat.com/ubi9/python-312@sha256:19e1e927138b40454858f297884c2c4e2f13f5ba95b3f55faea174d3cbb57067
USER 0
COPY ci-operator/config/openshift/release/_gcp-federation/requirements.txt /tmp/gcp-federation-requirements.txt
RUN python3 -m pip install --no-cache-dir -r /tmp/gcp-federation-requirements.txt && python3 -m pip check
USER 1001
