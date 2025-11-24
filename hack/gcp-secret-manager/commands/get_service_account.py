# Ignore dynamic imports
# pylint: disable=E0401, C0413

import json

import click
from google.api_core.exceptions import NotFound, PermissionDenied
from google.cloud import secretmanager
from util import (
    PROJECT_ID,
    UPDATER_SA_SECRET_NAME,
    ensure_authentication,
    get_secret_name,
    validate_collection,
)


@click.command(name="get-sa")
@click.option(
    "-c",
    "--collection",
    required=True,
    help="Name of the secret collection.",
    type=str,
    callback=validate_collection,
)
def get_service_account(collection: str):
    """Retrieve the service account associated with a secret collection."""

    ensure_authentication()
    client = secretmanager.SecretManagerServiceClient()
    secret_id = get_secret_name(collection, UPDATER_SA_SECRET_NAME)
    name = client.secret_version_path(PROJECT_ID, secret_id, "latest")

    try:
        response = client.access_secret_version(request={"name": name})
    except PermissionDenied:
        raise click.ClickException(
            f"You don't have permission to access service account credentials for collection '{collection}'"
        )
    except NotFound:
        raise click.ClickException(
            f"Service account credentials not found for collection '{collection}'"
        )
    except Exception as e:
        raise click.ClickException(
            f"Failed to access service account credentials for collection '{collection}': {e}"
        ) from e

    payload = response.payload.data.decode("UTF-8")

    try:
        parsed = json.loads(payload)
        click.echo(json.dumps(parsed, indent=2))
    except json.JSONDecodeError:
        click.echo(payload)
