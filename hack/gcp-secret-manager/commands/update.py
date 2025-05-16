# Ignore dynamic imports
# pylint: disable=E0401, C0413

import click
from google.api_core.exceptions import NotFound, PermissionDenied
from google.cloud import secretmanager
from util import (
    PROJECT_ID,
    create_payload,
    get_secret_name,
    validate_secret_source,
    validate_collection,
    validate_secret_name,
)


@click.command("update")
@click.option(
    "-c",
    "--collection",
    required=True,
    help="The collection the secret belongs to.",
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
def update(collection: str, secret: str, from_file: str, from_literal: str):
    """Update an existing secret."""

    validate_secret_source(from_file, from_literal)

    client = secretmanager.SecretManagerServiceClient()
    secret_name = client.secret_path(PROJECT_ID, get_secret_name(collection, secret))

    try:
        client.get_secret(name=secret_name)
        client.add_secret_version(
            parent=secret_name,
            payload={
                "data": create_payload(from_file, from_literal),
            },
        )
    except NotFound:
        raise click.ClickException(
            f"Secret '{secret}' not found in collection '{collection}'"
        )
    except PermissionDenied:
        raise click.UsageError(
            f"Access denied: You do not have permission to create secrets in collection '{collection}'"
        )
    except Exception as e:
        raise click.ClickException(f"Failed to create secret '{secret}': {e}")
