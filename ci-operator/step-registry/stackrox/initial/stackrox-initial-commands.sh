#!/bin/bash
exec .openshift-ci/dispatch.sh "${JOB_NAME##merge-}"
