# Ignore dynamic imports
# pylint: disable=E0401, C0413

import json

import click
from google.api_core.exceptions import NotFound, PermissionDenied
from google.cloud import secretmanager
from util import PROJECT_ID, ensure_authentication, validate_collection


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

    secret_id = f"{collection}__updater-service-account"
    name = f"projects/{PROJECT_ID}/secrets/{secret_id}/versions/latest"

    client = secretmanager.SecretManagerServiceClient()

    try:
        response = client.access_secret_version(request={"name": name})
    except NotFound:
        raise click.UsageError(
            f"Secret '{secret_id}' not found in project '{PROJECT_ID}'"
        )
    except PermissionDenied as e:
        raise click.ClickException(
            f"Error while accessing '{secret_id}' secret: {e.message}"
        )
    except Exception as e:
        raise click.ClickException(
            f"Error while accessing '{secret_id}' secret: {e}"
        ) from e

    payload = response.payload.data.decode("UTF-8")

    try:
        parsed = json.loads(payload)
        click.echo(json.dumps(parsed, indent=2))
    except json.JSONDecodeError:
        click.echo(payload)
