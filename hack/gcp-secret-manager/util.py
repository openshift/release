# Ignore dynamic imports
# pylint: disable=E0401, C0413

import os
import re
from typing import Dict, List, Set

import click
import requests
import yaml
from google.api_core.exceptions import PermissionDenied
from google.auth import default
from google.auth.exceptions import DefaultCredentialsError
from google.cloud import secretmanager
from google.cloud.secretmanager import SecretPayload

# Test Platform's project in GCP Secret Manager
PROJECT_ID = "openshift-ci-secrets"

# The YAML config which defines which groups have access to which secret collections.
CONFIG_PATH = "https://raw.githubusercontent.com/openshift/release/master/core-services/sync-rover-groups/_config.yaml"

# The string reserved for the index secret associated with each collection.
INDEX_SECRET_NAME = "__index"

# The string reserved for the service account secret associated with each collection.
UPDATER_SA_SECRET_NAME = "updater-service-account"


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
    if value == INDEX_SECRET_NAME:
        raise click.ClickException(
            f"The name '{INDEX_SECRET_NAME}' is reserved for internal use and cannot be used as a secret name."
        )
    if value == UPDATER_SA_SECRET_NAME:
        raise click.ClickException(
            f"The name '{UPDATER_SA_SECRET_NAME}' is reserved for internal use and cannot be used as a secret name."
        )
    if not re.fullmatch("[A-Za-z0-9-]+", value):
        raise click.BadParameter("May only contain letters, numbers or dashes.")
    # GCP limit for a secret name is 255 chars, 200 should be plenty.
    if len(value) > 200:
        raise click.BadParameter("Secret name must be max 200 characters.")
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
            message="You must provide secret data either as string input or a path to file. See `update --help` for more information.",
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
        # Resolve the path and check if it's readable
        resolved_path = os.path.realpath(from_file)
        if not os.path.isfile(resolved_path):
            raise click.UsageError(
                f"File '{from_file}' does not exist or is not a regular file."
            )

        with open(resolved_path, "rb") as f:
            return f.read()
    except (OSError, IOError) as e:
        raise click.UsageError(f"Failed to read file '{from_file}': {e}")
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
        response = requests.get(CONFIG_PATH, timeout=5)
        response.raise_for_status()
        data = yaml.safe_load(response.text)
    except yaml.YAMLError as e:
        raise click.ClickException(f"Failed to parse configuration: {e}")
    except requests.exceptions.RequestException:
        click.echo(
            "Failed to fetch configuration from GitHub. Falling back to local config in the release repository..."
        )
        script_dir = os.path.dirname(os.path.abspath(__file__))
        release_root = os.path.abspath(os.path.join(script_dir, "..", ".."))
        local_config_path = os.path.join(
            release_root, "core-services", "sync-rover-groups", "_config.yaml"
        )
        with open(local_config_path, "r", encoding="utf-8") as f:
            data = yaml.safe_load(f)

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
    collections_dict = get_group_collections()
    collections_set = set()

    for _, collections in collections_dict.items():
        collections_set.update(collections)  # More efficient than loop

    return collections_set


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
    collections_set = get_collections()
    return collection in collections_set


def get_secrets_from_index(
    client: secretmanager.SecretManagerServiceClient, collection: str
) -> List[str]:
    """
    Gets the secrets listed in the index secret of the collection.

    Args:
        client (secretmanager.SecretManagerServiceClient): Secret Manager client.
        collection (str): Name of the collection.

    Returns:
        List[str]: A list of secrets.
    """
    index_secret = client.secret_version_path(
        PROJECT_ID, get_secret_name(collection, INDEX_SECRET_NAME), "latest"
    )
    try:
        response = client.access_secret_version(request={"name": index_secret})
    except PermissionDenied:
        raise click.ClickException(
            f"You don't have permission to access secrets in collection '{collection}'."
        )
    except Exception as e:
        raise click.ClickException(
            f"Failed to list secrets for collection '{collection}': {e}"
        )

    secret_list = []
    try:
        secret_list = yaml.safe_load(response.payload.data.decode("UTF-8"))
    except yaml.YAMLError as e:
        raise click.ClickException(f"Failed to parse the index secret: {e}")

    return secret_list


def update_index_secret(
    client: secretmanager.SecretManagerServiceClient,
    collection: str,
    secret_names: List[str],
):
    """
    Updates the index secret for the collection with a new list of secrets.

    Args:
        client (secretmanager.SecretManagerServiceClient): Secret Manager client.
        collection (str): Name of the collection.
        secret_names (List[str]): A list of the new list of secrets to write into the index.
    """

    name = client.secret_path(
        PROJECT_ID, get_secret_name(collection, INDEX_SECRET_NAME)
    )
    payload = yaml.safe_dump(sorted(secret_names))
    try:
        client.add_secret_version(
            parent=name, payload=SecretPayload(data=payload.encode("utf-8"))
        )
    except Exception as e:
        raise click.ClickException(f"Error while updating index: '{e}'.")
