import re

import click
import requests
import yaml
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


def validate_collection(ctx, param, value):
    if not re.fullmatch("[a-z0-9-]*", value):
        raise click.BadParameter(
            "May only contain lowercase letters, numbers or dashes."
        )
    return value


def validate_secret_name(ctx, param, value):
    if not re.fullmatch("[A-Za-z0-9-]+", value):
        raise click.BadParameter("May only contain letters, numbers or dashes.")
    return value


def get_secret_name(collection, name: str) -> str:
    return f"{collection}__{name}"


def validate(from_file: str, from_literal: str):
    ensure_authentication()

    if from_literal != "" and from_file != "":
        raise click.BadOptionUsage(
            option_name=from_file,
            message="--from-file and --from-literal cannot both be set at the same time",
        )

    if from_literal == "" and from_file == "":
        raise click.BadOptionUsage(
            option_name=from_file,
            message="You must provide secret data either as string input or a path to file",
        )


def create_payload(from_file: str, from_literal: str) -> bytes:
    if from_literal != "":
        return from_literal.encode("UTF-8")

    try:
        with open(from_file, "rb") as f:
            return f.read()
    except Exception as e:
        raise click.UsageError(f"Failed to read file '{from_file}': {e}")


def get_secret_collections() -> dict[str, list[str]]:
    """
    Returns a dictionary mapping each group to its associated secret collections.

    Returns:
        dict[str,list[str]]: A dictionary where each key is a group name and
        each value is a list of secret collections associated with that group.
    """
    try:
        response = requests.get(CONFIG_PATH)
        data = yaml.safe_load(response.text)
    except Exception as e:
        raise click.ClickException(f"Failed to list collections: {e}")

    result = {}

    for group_name, group_data in data.get("groups", {}).items():
        collections = group_data.get("secret_collections", [])
        if collections:
            result[group_name] = sorted(collections)

    return result
