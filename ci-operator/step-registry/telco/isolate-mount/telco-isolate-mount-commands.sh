#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

cat > "${SHARED_DIR}/manifest_telco-isolate-mount-namespaces.yml" << EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  name: container-mount-namespace
spec:
  config:
    ignition:
      version: 3.1.0
    storage:
      files:
      - path: /usr/local/bin/extractExecStart
        filesystem: root
        mode: 493
        contents:
          source: data:text/plain;charset=utf8;base64,IyEvYmluL2Jhc2gKCmRlYnVnKCkgewogIGVjaG8gJEAgPiYyCn0KCnVzYWdlKCkgewogIGVjaG8gVXNhZ2U6ICQoYmFzZW5hbWUgJDApIFVOSVQgW2VudmZpbGUgW3Zhcm5hbWVdXQogIGVjaG8KICBlY2hvIEV4dHJhY3QgdGhlIGNvbnRlbnRzIG9mIHRoZSBmaXJzdCBFeGVjU3RhcnQgc3RhbnphIGZyb20gdGhlIGdpdmVuIHN5c3RlbWQgdW5pdCBhbmQgcmV0dXJuIGl0IHRvIHN0ZG91dAogIGVjaG8KICBlY2hvICJJZiAnZW52ZmlsZScgaXMgcHJvdmlkZWQsIHB1dCBpdCBpbiB0aGVyZSBpbnN0ZWFkLCBhcyBhbiBlbnZpcm9ubWVudCB2YXJpYWJsZSBuYW1lZCAndmFybmFtZSciCiAgZWNobyAiRGVmYXVsdCAndmFybmFtZScgaXMgRVhFQ1NUQVJUIGlmIG5vdCBzcGVjaWZpZWQiCiAgZXhpdCAxCn0KClVOSVQ9JDEKRU5WRklMRT0kMgpWQVJOQU1FPSQzCmlmIFtbIC16ICRVTklUIHx8ICRVTklUID09ICItLWhlbHAiIHx8ICRVTklUID09ICItaCIgXV07IHRoZW4KICB1c2FnZQpmaQpkZWJ1ZyAiRXh0cmFjdGluZyBFeGVjU3RhcnQgZnJvbSAkVU5JVCIKRklMRT0kKHN5c3RlbWN0bCBjYXQgJFVOSVQgfCBoZWFkIC1uIDEpCkZJTEU9JHtGSUxFI1wjIH0KaWYgW1sgISAtZiAkRklMRSBdXTsgdGhlbgogIGRlYnVnICJGYWlsZWQgdG8gZmluZCByb290IGZpbGUgZm9yIHVuaXQgJFVOSVQgKCRGSUxFKSIKICBleGl0CmZpCmRlYnVnICJTZXJ2aWNlIGRlZmluaXRpb24gaXMgaW4gJEZJTEUiCkVYRUNTVEFSVD0kKHNlZCAtbiAtZSAnL15FeGVjU3RhcnQ9LipcXCQvLC9bXlxcXSQvIHsgcy9eRXhlY1N0YXJ0PS8vOyBwIH0nIC1lICcvXkV4ZWNTdGFydD0uKlteXFxdJC8geyBzL15FeGVjU3RhcnQ9Ly87IHAgfScgJEZJTEUpCgppZiBbWyAkRU5WRklMRSBdXTsgdGhlbgogIFZBUk5BTUU9JHtWQVJOQU1FOi1FWEVDU1RBUlR9CiAgZWNobyAiJHtWQVJOQU1FfT0ke0VYRUNTVEFSVH0iID4gJEVOVkZJTEUKZWxzZQogIGVjaG8gJEVYRUNTVEFSVApmaQo=
      - path: /usr/local/bin/nsenterCmns
        filesystem: root
        mode: 493
        contents:
          source: data:text/plain;charset=utf8;base64,IyEvYmluL2Jhc2gKbnNlbnRlciAtLW1vdW50PS9ydW4vY29udGFpbmVyLW1vdW50LW5hbWVzcGFjZS9tbnQgIiRAIgo=
    systemd:
      units:
      - name: container-mount-namespace.service
        enabled: true
        contents: |
          [Unit]
          Description=Manages a mount namespace that both kubelet and crio can use to share their container-specific mounts
          
          [Service]
          Type=oneshot
          RemainAfterExit=yes
          RuntimeDirectory=container-mount-namespace
          Environment=RUNTIME_DIRECTORY=%t/container-mount-namespace
          Environment=BIND_POINT=%t/container-mount-namespace/mnt
          ExecStartPre=bash -c "findmnt ${RUNTIME_DIRECTORY} || mount --make-unbindable --bind ${RUNTIME_DIRECTORY} ${RUNTIME_DIRECTORY}"
          ExecStartPre=touch ${BIND_POINT}
          ExecStart=unshare --mount=${BIND_POINT} --propagation slave mount --make-rshared /
          ExecStop=umount -R ${RUNTIME_DIRECTORY}
      - name: crio.service
        dropins:
        - name: 20-container-mount-namespace.conf
          contents: |
            [Unit]
            Wants=container-mount-namespace.service
            After=container-mount-namespace.service
            
            [Service]
            ExecStartPre=/usr/local/bin/extractExecStart %n /%t/%N-execstart.env ORIG_EXECSTART
            EnvironmentFile=-/%t/%N-execstart.env
            ExecStart=
            ExecStart=bash -c "nsenter --mount=%t/container-mount-namespace/mnt \
                ${ORIG_EXECSTART}"
      - name: kubelet.service
        dropins:
        - name: 20-container-mount-namespace.conf
          contents: |
            [Unit]
            Wants=container-mount-namespace.service
            After=container-mount-namespace.service
            
            [Service]
            ExecStartPre=/usr/local/bin/extractExecStart %n /%t/%N-execstart.env ORIG_EXECSTART
            EnvironmentFile=-/%t/%N-execstart.env
            ExecStart=
            ExecStart=bash -c "nsenter --mount=%t/container-mount-namespace/mnt \
                ${ORIG_EXECSTART}"
EOF
