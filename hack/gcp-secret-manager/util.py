# Ignore dynamic imports
# pylint: disable=E0401, C0413

import re
from typing import Dict, List, Set

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
    """
    Ensures that the user is authenticated with Google Cloud.

    Raises:
        click.ClickException: If application default credentials are not found.
    """
    try:
        _, _ = default()
    except DefaultCredentialsError as e:
        raise click.ClickException(
            "Credentials for authenticating into google cloud not found. Run the `login` command to authenticate."
        ) from e


def validate_collection(_ctx, _param, value):
    if not re.fullmatch("[a-z0-9-]*", value):
        raise click.BadParameter(
            "May only contain lowercase letters, numbers or dashes."
        )
    return value


def validate_secret_name(_ctx, _param, value):
    if not re.fullmatch("[A-Za-z0-9-]+", value):
        raise click.BadParameter("May only contain letters, numbers or dashes.")
    return value


def get_secret_name(collection: str, name: str) -> str:
    """
    Returns a normalized secret name by combining the collection and secret name.

    Args:
        collection (str): The name of the secret collection.
        name (str): The base name of the secret.

    Returns:
        str: A string in the format "{collection}__{name}".
    """
    return f"{collection}__{name}"


def validate_secret_source(from_file: str, from_literal: str):
    """
    Validates that only one of --from-file or --from-literal is provided.

    Args:
        from_file (str): Path to the file containing secret data.
        from_literal (str): Secret data provided as a string.

    Raises:
        click.BadOptionUsage: If both or neither of the options are provided.
    """
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
    """
    Creates a secret payload from either a literal string or a file.

    Args:
        from_file (str): Path to the file containing the secret data.
        from_literal (str): Secret data provided as a string literal.

    Returns:
        bytes: The secret data as bytes.

    Raises:
        click.UsageError: If reading the file fails.
    """
    if from_literal != "":
        return from_literal.encode("UTF-8")

    try:
        with open(from_file, "rb") as f:
            return f.read()
    except Exception as e:
        raise click.UsageError(f"Failed to read file '{from_file}': {e}")


def get_group_collections() -> Dict[str, List[str]]:
    """
    Returns a dictionary mapping each group to its associated secret collections.

    Returns:
        Dict[str,list[str]]: A dictionary where each key is a group name and
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


def get_collections() -> Set[str]:
    """
    Returns a set of all existing collections.

    Returns:
        Set[str]: A set containing all secret collections.
    """
    colls_dict = get_group_collections()
    colls_set = set()

    for _, collections in colls_dict.items():
        for c in collections:
            colls_set.add(c)

    return colls_set


def check_if_collection_exists(collection: str) -> bool:
    """
    Verifies that the collection exists in the configuration file
    in the release repository (source of truth).

    Args:
        collection (str): Name of the collection to check.

    Returns:
        bool: True if collection is one of the defined collections
        in the configuration file, False otherwise.
    """
    s = get_collections()
    return collection in s
