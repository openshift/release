FROM fedora:31

RUN dnf update -y \
	&& dnf install -y \
		git \
		findutils \
		ShellCheck \
	&& dnf clean all
