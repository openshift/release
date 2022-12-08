# (WIP) OpenShift CI Scenario Onboarding Process<!-- omit from toc -->

## Table of Contents<!-- omit from toc -->
- [Overview](#overview)
- [Why is this needed](#why-is-this-needed)
- [Onboarding Workflow Diagram (Coming Soon)](#onboarding-workflow-diagram-coming-soon)
- [Onboarding Phases](#onboarding-phases)
  - [1. Prerequistes](#1-prerequistes)
  - [2. Scenario Kick-off](#2-scenario-kick-off)
  - [3. Create Scenario Foundation](#3-create-scenario-foundation)
  - [4. Orchestrate](#4-orchestrate)
  - [5. Execute](#5-execute)
  - [6. Report (Coming Soon)](#6-report-coming-soon)
  - [7. Document](#7-document)
  - [8. Production](#8-production)
  - [9. Maintenance \& Expansion](#9-maintenance--expansion)
  - [10. Celebrate \& Share](#10-celebrate--share)

## Overview
This Onboarding guide is meant to describe a repeatable process that can be followed to create test scenarios for OpenShift integrated products using OpenShift CI. The goal is that we can onboard & expand new scenarios that are easy to understand, maintain and debug.

We must deeply understand the need for each specific scenario that we put through this process and update this process when needed. This is not meant to be followed blindly so that we can onboard scenarios faster. It is meant to teach a generic way to onboard scenarios that is proven to work. Its expected that new scenarios will present new problems and we must develop better solutions that what is proposed. We need to hear your painpoints and feedback throughout every step of this process. **Please communicate over the [#forum-qe-cspi-ocp-ci](https://coreos.slack.com/archives/C047Y0DPEJU) slack channel**

## Why is this needed
There are many products that we've built on top of OpenShift. We need to make sure that all of these products are working with the latest OpenShift bits. In order to effectively test, debug, and maintain all of these products tests and show the results in a consumable report we need to have some structure in place. 

If this onboarding process did not exist we'd be scrambling to put together reports efficiently, find automation bugs, fix automation bugs, find testing gaps, update test scenarios frequently.

## Onboarding Workflow Diagram (Coming Soon)
[Interop Onboarding Workflow Diagram](https://miro.com/app/board/uXjVP4mv2uw=/)

## Onboarding Phases
### 1. Prerequistes
In order for onboarding to run smoothly and avoid becoming blocked for long stretches we will be upholding a high standard for achieving the prerequisites needed for this model. We predict that accomplishing these prerequistes will take longer than the onboarding itself.

The result of working through your prerequisites will be the completion of the Prerequisite JIRA ticket assigned to you. All information proving that this scenario is ready to be onboarded will need to be provided and approved by both parties.

See the [Prerequisites Guide](PREREQUISITES_GUIDE.md) for a detailed explanation of what is needed and how to achieve it.

### 2. Scenario Kick-off
See the [Kick-off Guide](KICK-OFF_GUIDE.md) for the process to follow when officially starting the cross-team collaboration for a scenario.

### 3. Create Scenario Foundation
Here we will start our interaction with OpenShift CI. We do this by adding the necessary files to the [openshift/release](https://github.com/openshift/release) repo.

See the [Scenario Foundation Guide](SCENARIO_FOUNDATION_GUIDE.md) for detailed information to help you get your scenario off the ground.

### 4. Orchestrate
We define Orchestrate as anything that is needed to install and configure your product on OpenShift so that it is ready to be tested.

See the [Orchestrate Install Guide](ORCHESTRATE_INSTALL_GUIDE.md) for detailed information meant to help you organize the installation of your product.

### 5. Execute
Execute is defined as the phase where you setup the environment needed for your tests and the step you take to run them.

See the [Test Execution Guide](TEST_EXECUTION_GUIDE.md) for detailed information meant to help you organize your test execution.

### 6. Report (Coming Soon)
See the [Reporting Guide](REPORTING_GUIDE.md) for detailed information meant to help you configure your scenarios reporting.
### 7. Document
We've been creating a lot in the config and step-registry directory. In order for this work to be understood by someone other than us we need to document the scenario itself.

See the [Documentation Guide](DOCUMENTATION_GUIDE.md) for detailed information meant to help you create structured documentation for your scenario.

### 8. Production
See the [Production Guide](PRODUCTION_GUIDE.md) for detailed information meant to help you ensure that your scenario is ready for production.

### 9. Maintenance & Expansion
See the [Maintenance & Expansion Guide](MAINTENANCE_EXPANSION_GUIDE.md) for detailed information meant to help you maintain and expand your scenarios testable versions in a consistant and easy fashion.

### 10. Celebrate & Share
See the [Celebrate & Share](CELEBRATE_SHARE_GUIDE.md) for fun information meant to help you communicate your success with others so that we can all benefit from what you've created! :)