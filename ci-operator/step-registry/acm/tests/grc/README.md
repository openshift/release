<<<<<<< HEAD
<<<<<<< HEAD
# acm-tests-grc-create-ref<!-- omit from toc -->
=======
# acm-tests-grc-ref<!-- omit from toc -->
>>>>>>> 95a2a3367bd (Vboulos add step rigistry for grc (#37587))
=======
# acm-tests-grc-ref<!-- omit from toc -->
=======
# acm-tests-grc-create-ref<!-- omit from toc -->
>>>>>>> 6491b1ee3c5 (Test everything except Obs on 4.13)
>>>>>>> 233971a02ba (Test everything except Obs on 4.13)

## Table of Contents<!-- omit from toc -->
- [Purpose](#purpose)
- [Process](#process)
- [Requirements](#requirements)
  - [Infrastructure](#infrastructure)
<<<<<<< HEAD
<<<<<<< HEAD

## Purpose

To run the ACM tests for the GRC ACM component.
This ref is meant to be re-usable so long as the requirements are met.

## Process

- Sets dynamic variables based on the ephemeral hub cluster that needs to be provisioned prior to running this.
- Runs a [script from product QE's repo](https://github.com/stolostron/acmqe-autotest/blob/main/ci/containerimages/fetch-managed-clusters/fetch_clusters_commands.sh) that does some additional config and ultimately runs the python script [generate_managedclusters_data.py](https://github.com/stolostron/acmqe-autotest/blob/main/ci/containerimages/fetch-managed-clusters/generate_managedclusters_data.py).
=======
=======
>>>>>>> 233971a02ba (Test everything except Obs on 4.13)
  - [Environment Variables](#environment-variables)

## Purpose

To run the GRC interop tests defined in the step [acm-tests-grc-ref](../grc/README.md).


## Process

- This ref runs a [script from product QE's repo](https://github.com/stolostron/acmqe-grc-test/blob/release-2.7/execute_grc_interop_commands.sh) that does some additional config and ultimately runs the script ([run-docker-tests.sh](https://github.com/stolostron/acmqe-grc-test/blob/release-2.7/build/run-docker-tests.sh)) to kick off a cypress tests where we create and update GRC policies.
<<<<<<< HEAD
>>>>>>> 95a2a3367bd (Vboulos add step rigistry for grc (#37587))
=======
=======

## Purpose

To run the ACM tests for the GRC ACM component.
This ref is meant to be re-usable so long as the requirements are met.

## Process

- Sets dynamic variables based on the ephemeral hub cluster that needs to be provisioned prior to running this.
- Runs a [script from product QE's repo](https://github.com/stolostron/acmqe-autotest/blob/main/ci/containerimages/fetch-managed-clusters/fetch_clusters_commands.sh) that does some additional config and ultimately runs the python script [generate_managedclusters_data.py](https://github.com/stolostron/acmqe-autotest/blob/main/ci/containerimages/fetch-managed-clusters/generate_managedclusters_data.py).
>>>>>>> 6491b1ee3c5 (Test everything except Obs on 4.13)
>>>>>>> 233971a02ba (Test everything except Obs on 4.13)

## Requirements


### Infrastructure

<<<<<<< HEAD
<<<<<<< HEAD
- An existing OpenShift cluster to act as the target Hub to deploy managed clusters onto.
- "advanced-cluster-management" operator installed (see [`install-operators`](../../../step-registry/install-operators/README.md)).
- An existing managed cluster deployed by using the [clc-create ref](https://steps.ci.openshift.org/reference/acm-tests-clc-create).
- Stored knowledge of the managed cluster which can be gather by using the [fetch-managed-cluster ref](https://steps.ci.openshift.org/reference/acm-fetch-managed-clusters).
=======
=======
>>>>>>> 233971a02ba (Test everything except Obs on 4.13)
- A provisioned test cluster to target (hub).
- "advanced-cluster-management" operator installed (see [`install-operators`](../../../step-registry/install-operators/README.md)).
- MCH custom resource installed (see [acm-mch step](../mch/README.md))
- [acm-tests-clc-create-commands.sh](../tests/clc/acm-tests-clc-create-commands.sh) needs to successfully have run prior to this running. This is what creates the managed clusters that are being used to gather data from.
- [acm-tests-fetch-managed-clusters-commands.sh](../tests/fetch-managed-clusters/acm-tests-fetch-managed-clusters-commands.sh) needs to successfully have run prior to this running. This is what fetches the managed clusters info that are being used to gather data from.

### Environment Variables

- Please see [acm-tests-grc-ref.yaml](acm-tests-grc-ref.yaml) env section.
<<<<<<< HEAD
>>>>>>> 95a2a3367bd (Vboulos add step rigistry for grc (#37587))
=======
=======
- An existing OpenShift cluster to act as the target Hub to deploy managed clusters onto.
- "advanced-cluster-management" operator installed (see [`install-operators`](../../../step-registry/install-operators/README.md)).
- An existing managed cluster deployed by using the [clc-create ref](https://steps.ci.openshift.org/reference/acm-tests-clc-create).
- Stored knowledge of the managed cluster which can be gather by using the [fetch-managed-cluster ref](https://steps.ci.openshift.org/reference/acm-fetch-managed-clusters).
>>>>>>> 6491b1ee3c5 (Test everything except Obs on 4.13)
>>>>>>> 233971a02ba (Test everything except Obs on 4.13)
