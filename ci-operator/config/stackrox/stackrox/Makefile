.PHONY: check
check:
	@./config.py --check

.PHONY: check-ci
check-ci:
	@XDG_CACHE_HOME=/tmp \
	python3 -m venv /tmp/.venv && \
	. /tmp/.venv/bin/activate && \
	pip3 --require-virtualenv --no-input --disable-pip-version-check install PyYAML==6.0 dataclasses >/dev/null && \
	python3 ./config.py --check
