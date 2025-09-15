# Ignore dynamic imports
# pylint: disable=E0401, C0413

import click
from google.api_core.exceptions import NotFound, PermissionDenied
from google.cloud import secretmanager
from google.cloud.secretmanager import SecretPayload
from util import (
    PROJECT_ID,
    create_payload,
    get_secret_name,
    get_secrets_from_index,
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
    secret_name = get_secret_name(collection, secret)
    full_secret_path = client.secret_path(PROJECT_ID, secret_name)

    # Check if secret exists in both index and GSM
    index_secrets = get_secrets_from_index(client, collection)
    secret_in_index = secret in index_secrets

    try:
        client.get_secret(request={"name": full_secret_path})
        secret_in_gsm = True
    except NotFound:
        secret_in_gsm = False

    # Simple existence checks - tell user to delete/recreate if inconsistent
    if not secret_in_index and not secret_in_gsm:
        raise click.ClickException(
            f"Secret '{secret}' does not exist in collection '{collection}'."
        )

    if secret_in_index and not secret_in_gsm:
        raise click.ClickException(
            f"Secret '{secret}' is in inconsistent state. "
            f"Run 'delete -c {collection} -s {secret}', then 'create' to fix."
        )

    if not secret_in_index and secret_in_gsm:
        raise click.ClickException(
            f"Secret '{secret}' is in inconsistent state (GSM only). "
            f"Run 'delete -c {collection} -s {secret}', then 'create' to fix."
        )

    # Secret exists in both places - proceed with update
    try:
        client.add_secret_version(
            parent=full_secret_path,
            payload=SecretPayload(data=create_payload(from_file, from_literal)),
        )
        click.echo(f"Secret '{secret}' updated successfully.")
    except PermissionDenied:
        raise click.ClickException(
            f"You don't have permission to update secrets in collection '{collection}'"
        )
    except Exception as e:
        raise click.ClickException(f"Failed to update secret '{secret}': {e}.")
