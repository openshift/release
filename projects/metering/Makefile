DIR:=$(shell dirname $(realpath $(lastword $(MAKEFILE_LIST))))

default: metering-project

metering-project:
	$(DIR)/setup-metering-project.sh
.PHONY: metering-project
