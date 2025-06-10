# Ignore dynamic imports
# pylint: disable=E0401, C0413

import click
from google.api_core.exceptions import NotFound, PermissionDenied
from google.cloud import secretmanager
from util import (
    PROJECT_ID,
    ensure_authentication,
    get_secret_name,
    get_secrets_from_index,
    update_index_secret,
    validate_collection,
    validate_secret_name,
)


@click.command("delete")
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
def delete(collection: str, secret: str):
    """Delete a secret from the specified collection."""

    ensure_authentication()
    client = secretmanager.SecretManagerServiceClient()

    index_secrets = get_secrets_from_index(client, collection)
    if secret not in index_secrets:
        raise click.ClickException(
            f"Secret '{secret}' not found in collection '{collection}'."
        )
    try:
        client.delete_secret(
            name=client.secret_path(PROJECT_ID, get_secret_name(collection, secret))
        )
        index_secrets.remove(secret)
        update_index_secret(client, collection, index_secrets)
        click.echo(f"Secret '{secret}' deleted from collection '{collection}'.")
    except NotFound:
        # Secret doesn't exist in GCP but is in index;
        # remove from index to fix inconsistent state.
        index_secrets.remove(secret)
        update_index_secret(client, collection, index_secrets)
    except Exception as e:
        raise click.ClickException(f"Failed to delete secret '{secret}': {e}")
