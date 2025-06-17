# Ignore dynamic imports
# pylint: disable=E0401, C0413

import click
from google.api_core.exceptions import NotFound, PermissionDenied
from google.cloud import secretmanager
from util import (
    PROJECT_ID,
    create_payload,
    get_secret_name,
    get_secrets_from_index,
    update_index_secret,
    validate_collection,
    validate_secret_name,
    validate_secret_source,
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
    full_secret_path = client.secret_path(
        PROJECT_ID, get_secret_name(collection, secret)
    )

    ensure_index_consistency(client, collection, secret, full_secret_path)

    try:
        client.add_secret_version(
            parent=full_secret_path,
            payload={
                "data": create_payload(from_file, from_literal),
            },
        )
        click.echo(f"Secret '{secret}' updated successfully.")
    except PermissionDenied:
        raise click.UsageError(
            f"Access denied: You do not have permission to update secrets in collection '{collection}'"
        )
    except Exception as e:
        raise click.ClickException(f"Failed to update secret '{secret}': {e}")


def ensure_index_consistency(
    client: secretmanager.SecretManagerServiceClient,
    collection: str,
    secret: str,
    secret_path: str,
):
    """
    Ensures the secret exists both in GSM and the index, or handle inconsistencies.
    Raises ClickException if update is not possible.
    """
    index_secrets = get_secrets_from_index(client, collection)
    secret_in_index = secret in index_secrets

    try:
        client.get_secret(request={"name": secret_path})
        secret_in_gsm = True
    except NotFound:
        secret_in_gsm = False

    if not secret_in_index and secret_in_gsm:
        # Secret exists in GSM but index is stale -> fix index silently.
        index_secrets.append(secret)
        update_index_secret(client, collection, index_secrets)
    elif secret_in_index and not secret_in_gsm:
        # Index is stale —> remove entry from index, can't update a non-existent secret.
        index_secrets.remove(secret)
        update_index_secret(client, collection, index_secrets)
        raise click.ClickException(
            f"Secret '{secret}' does not exist in collection '{collection}'."
        )
    elif not secret_in_index and not secret_in_gsm:
        # Fully missing — consistent, just not created yet.
        raise click.ClickException(
            f"Secret '{secret}' does not exist in collection '{collection}'."
        )
