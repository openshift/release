# Ignore dynamic imports
# pylint: disable=E0401, C0413

import click
from google.api_core.exceptions import NotFound, PermissionDenied
from google.cloud import secretmanager
from util import (
    PROJECT_ID,
    ensure_authentication,
    get_secret_name,
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

    try:
        client = secretmanager.SecretManagerServiceClient()
        name = client.secret_path(PROJECT_ID, get_secret_name(collection, secret))
        client.delete_secret(name=name)
        click.echo(f"Secret '{secret}' deleted")
    except NotFound:
        raise click.UsageError(
            f"Secret '{secret}' not found in collection '{collection}' (project: {PROJECT_ID})."
        )
    except PermissionDenied:
        raise click.UsageError(
            f"Access denied: You do not have permission to delete secret '{secret}'."
        )
    except Exception as e:
        raise click.UsageError(f"Error deleting secret '{secret}': {e}")
