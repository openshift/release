import re

import click
from google.auth import default
from google.auth.exceptions import DefaultCredentialsError

# Test Platform's project in GCP Secret Manager
PROJECT_ID = "openshift-ci-secrets"

# The YAML config which defines which groups have access to which secret collections.
CONFIG_PATH = "https://raw.githubusercontent.com/openshift/release/master/core-services/sync-rover-groups/_config.yaml"


def ensure_authentication():
    try:
        _, _ = default()
    except DefaultCredentialsError:
        raise click.ClickException(
            "Credentials for authenticating into google cloud not found. Run `secret-manager login` to authenticate."
        )


def validate_collection(collection: str):
    if not re.fullmatch("[a-z0-9-]+"):
        raise click.UsageError(
            f"Invalid collection name '{collection}'. May only contain lowercase letters, numbers or dashes."
        )


def validate_secret_name(name: str):
    if not re.fullmatch("[A-Za-z0-9-]+", name):
        raise click.UsageError(
            f"Invalid secret name '{name}'. May only contain lowercase letters, numbers or dashes."
        )


def get_secret_name(collection, name: str) -> str:
    return f"{collection}__{name}"


def validate(collection: str, name: str, from_file: str, from_literal: str):
    ensure_authentication()
    validate_collection(collection)
    validate_secret_name(name)

    if from_literal != "" and from_file != "":
        raise click.BadOptionUsage(
            option_name=from_file,
            message="--from-file and --from-literal cannot both be set at the same time",
        )

    if from_literal == "" and from_file == "":
        raise click.BadOptionUsage(
            option_name=from_file,
            message="You must provide either secret content or a path to file",
        )


def create_payload(from_file: str, from_literal: str) -> bytes:
    if from_literal != "":
        return from_literal.encode("UTF-8")

    try:
        with open(from_file, "rb") as f:
            return f.read()
    except Exception as e:
        raise click.UsageError(f"Failed to read file '{from_file}': {e}")
