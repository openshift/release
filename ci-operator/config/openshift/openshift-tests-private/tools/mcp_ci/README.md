Create upgrade CI jobs and Have a knowledge base.

# Preparation
    Read https://modelcontextprotocol.io/quickstart/server#set-up-your-environment to help you install uv
    $ cd ci-operator/config/openshift/openshift-tests-private/tools/mcp_ci
    $ uv venv
    $ source .venv/bin/activate
    $ uv sync
    $ sudo curl -o redhat-ca.pem https://certs.corp.redhat.com/certs/Current-IT-Root-CAs.pem
    $ update environment settings in ci-operator/config/openshift/openshift-tests-private/tools/mcp_ci/clients/.env


# There are two ways to work with the AI tool:

## Start A Dev Server
    $ uv run mcp dev servers/ci_server.py

### Create Prow jobs by MCP UI
    1. Go to MCP ui
    2. Click the `Connect` button in the left menu bar
    3. Click the `Tools` button in the middle-top menu bar
    4. Click `List Tools` button
    5. Click the tool `create_CPOU_upgrade_files`
    6. Enter target OCP version, for example `4.21`
    7. Click `Run Tool` button

## Using an interactive AI terminal

    $ cd ci-operator/config/openshift/openshift-tests-private/tools/mcp_ci
    $ source .venv/bin/activate
    $ python clients/client.py servers/ci_server.py

    Then we can interactive with the AI:
    1. Only create CPOU upgrade jobs: 
        \nQuery: please help create CPOU upgrade jobs for OCP 4.21 
    2. Create all jobs:
        \nQuery: please help create upgrade jobs for OCP 4.21 
    3. Work as a knowledge pool
        \nQuery: please introduce Redhat and Openshift

New upgrade config files will be created, then we just need to run `Make update` in the repo to prepare a PR.

*Note*: Chain upgrade is a little different from other upgrade types, 
        after running the AI tool, you still need to verify if there are missing files.

# make update
Before run make xxx, please remove .venv folder

