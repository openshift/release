# Ignore dynamic imports
# pylint: disable=E0401, C0413

import re
from typing import Dict

import click
from google.api_core.exceptions import NotFound, PermissionDenied
from google.cloud import secretmanager
from util import (
    PROJECT_ID,
    check_if_collection_exists,
    create_payload,
    get_secret_name,
    validate_collection,
    validate_secret_name,
    validate_secret_source,
)

# Metadata keys used when creating secrets:
# - JIRA_LABEL a label to associate the secret with a specific JIRA project.
JIRA_LABEL = "jira-project"

# - ROTATION_INSTRUCTIONS is an annotation that describes how the secret should be rotated.
ROTATION_INSTRUCTIONS = "rotation-instructions"

# - REQUEST_INFO is an annotation that describes how the secret was originally requested,
#   to help trace who to contact in case of problems.
REQUEST_INFO = "request-information"


@click.command("create")
@click.option(
    "-c",
    "--collection",
    required=True,
    help="The secret collection to store the secret.",
    type=str,
    callback=validate_collection,
)
@click.option(
    "-s",
    "--secret",
    required=True,
    help="Name of the secret.",
    type=str,
    callback=validate_secret_name,
)
@click.option(
    "-f",
    "--from-file",
    default="",
    help="Path to file with secret data.",
    type=click.Path(file_okay=True, dir_okay=False, readable=True),
)
@click.option(
    "-l", "--from-literal", default="", help="Secret data as string input.", type=str
)
def create(collection: str, secret: str, from_file: str, from_literal: str):
    """Create a new secret in the specified collection."""

    validate_secret_source(from_file, from_literal)
    if not check_if_collection_exists(collection):
        raise click.ClickException(
            f"Collection '{collection}' doesn't exist.  "
            "To create it, add it to the configuration file in the release repository. "
            "See: https://docs.ci.openshift.org/docs/how-tos/adding-a-new-secret-to-ci/"
        )
    client = secretmanager.SecretManagerServiceClient()
    check_if_secret_already_exists(collection, secret, client)

    click.echo(
        "To help us track ownership and manage secrets effectively, we need to collect a few pieces of info.\n"
        "If a field does not apply to your case, type 'none' to continue.\n"
    )
    labels = prompt_for_labels()
    annotations = prompt_for_annotations()

    try:
        gcp_secret = client.create_secret(
            request={
                "parent": f"projects/{PROJECT_ID}",
                "secret_id": get_secret_name(collection, secret),
                "secret": {
                    "replication": {"automatic": {}},
                    "labels": labels,
                    "annotations": annotations,
                },
            }
        )
        client.add_secret_version(
            parent=gcp_secret.name,
            payload={
                "data": create_payload(from_file, from_literal),
            },
        )
        click.echo(f"Secret '{secret}' created")
    except PermissionDenied:
        raise click.ClickException(
            f"Access denied: You do not have permission to create secrets in collection '{collection}'"
        )
    except Exception as e:
        raise click.ClickException(f"Failed to create secret '{secret}': {e}") from e


def check_if_secret_already_exists(
    collection: str, secret: str, client: secretmanager.SecretManagerServiceClient
):
    name = client.secret_path(PROJECT_ID, get_secret_name(collection, secret))
    try:
        client.get_secret(request={"name": name})
        raise click.ClickException(
            f"Secret '{secret}' already exists in collection '{collection}'."
        )
    except NotFound:
        return


def prompt_for_labels() -> Dict[str, str]:
    click.echo(
        "Enter team JIRA project associated with this secret (e.g. 'ART' for issues.redhat.com/browse/ART).\n"
        "Test Platform may open tickets in this project to help handle incidents requiring secret rotation."
    )
    while True:
        jira = click.prompt(
            text="Jira project (required)",
            type=str,
        ).strip()
        if is_valid_label_value(jira):
            return {JIRA_LABEL: jira.lower()}
        click.echo(
            "JIRA project label must be 1-63 characters, lowercase alphanumeric or hyphen, and not start or end with a hyphen."
        )


def is_valid_label_value(value: str) -> bool:
    if value.lower() == "none":
        return True
    return bool(re.fullmatch(r"[a-z]([-a-z0-9]*[a-z0-9])?", value)) and (
        1 <= len(value) <= 63
    )


def prompt_for_annotations() -> Dict[str, str]:
    annotations = {}

    click.echo(
        "\nProvide a short description of how this secret can/will be rotated.\n"
        "This can help future team members support token rotation requirements.\n"
        "Do not include sensitive information."
    )

    annotations[ROTATION_INSTRUCTIONS] = prompt_for_annotation(
        "Rotation info (required)"
    )

    click.echo(
        "\nProvide a short description of how this secret was originally requested\n"
        "(e.g. links to service now tickets, Jira tickets, documentation).\n"
        "This can help future team members know who to contact in case of problems.\n"
        "Do not include sensitive information."
    )
    annotations[REQUEST_INFO] = prompt_for_annotation("Request info (required)")
    check_annotations_size(annotations)
    return annotations


def prompt_for_annotation(msg: str) -> str:
    while True:
        value = click.prompt(text=msg, type=str).strip()
        if value and value.lower() == "n/a":
            return "N/A"
        if value:
            return value
        click.echo("Input cannot be empty. Please enter a value or 'N/A'.")


def check_annotations_size(annotations: Dict) -> bool:
    size = sum(
        len(key.encode("utf-8")) + len(value.encode("utf-8"))
        for key, value in annotations.items()
    )
    # The total size of annotation keys and values must be less than 16KiB.
    if size > (16 * 1024):
        raise click.ClickException(
            "Total annotations size exceeds the allowed limit (16KiB)."
        )
