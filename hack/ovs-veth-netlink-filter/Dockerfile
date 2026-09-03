FROM registry.fedoraproject.org/fedora:43

RUN dnf -y install \
        bash \
        bpftool \
        clang \
        coreutils \
        findutils \
        libbpf-devel \
        procps-ng \
    && dnf clean all

COPY ovs_veth_filter.bpf.c find-portid.sh entrypoint.sh /opt/ovs-veth-filter/
RUN chmod 0755 /opt/ovs-veth-filter/find-portid.sh \
    /opt/ovs-veth-filter/entrypoint.sh

ENTRYPOINT ["/opt/ovs-veth-filter/entrypoint.sh"]
