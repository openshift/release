import click
from google.auth import default
from google.auth.exceptions import DefaultCredentialsError

# Test Platform's project in GCP Secret Manager
PROJECT_ID = "openshift-ci-secrets"

# CONFIG_PATH = "https://raw.githubusercontent.com/openshift/release/master/core-services/sync-rover-groups/_config.yaml"
CONFIG_PATH = "https://raw.githubusercontent.com/psalajova/release/refs/heads/sm-test/core-services/sync-rover-groups/_config.yaml"


def ensure_authentication():
    try:
        _, _ = default()
    except DefaultCredentialsError:
        raise click.ClickException(
            "Credentials for authenticating into google cloud not found. Run `secret-manager login` to authenticate."
        )
