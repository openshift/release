#!/usr/bin/env python3
import click
import subprocess

from google.cloud import secretmanager
from google.auth.exceptions import DefaultCredentialsError

# Test Platform's project in GCP Secret Manager
PROJECT_ID = "openshift-ci-secrets"

CONFIG_PATH = "https://raw.githubusercontent.com/openshift/release/master/core-services/sync-rover-groups/_config.yaml"


@click.group()
def cli():
    """CLI tool to manage secrets in Google Secret Manager."""
    pass


@click.command()
def login():
    """Login command to authenticate the user."""
    click.echo("Login process here...")
    try:
        subprocess.run(["gcloud", "auth", "application-default", "login"], check=True)
        click.echo("Login called...successfully?")
    except subprocess.CalledProcessError:
        click.echo("Failed to login.", err=True)


@click.command()
@click.option("-o", "--output", default="yaml")
@click.option("-c", "--collection", default="", help="xxx")
def list(output, collection):
    """List secrets from the specified collection, or, if no collection is provided, lists all secret collections."""

    if collection == "":
        click.echo("Please provide the collection.")

    try:
        client = secretmanager.SecretManagerServiceClient()
        response = client.list_secrets(
            request={secretmanager.ListSecretsRequest(parent=f"projects/{PROJECT_ID}")}
        )
        for secret in response:
            click.echo(secret)
    except DefaultCredentialsError:
        click.echo(
            "Credentials for authenticating into google cloud not found. Please run this script with the login command."
        )


@click.command()
@click.option("-c", "--collection", default="", help="Name of collection")
@click.option("-f", "--file", default="", help="Path to secret file")
def create(collection, file):
    """Create new secret in the specified collection."""
    pass


@click.command()
def get_serviceAccount():
    pass


@click.command()
def update():
    pass


@click.command()
def delete():
    pass


cli.add_command(login)
cli.add_command(list)
cli.add_command(create)
cli.add_command(get_serviceAccount)
cli.add_command(update)
cli.add_command(delete)

if __name__ == "__main__":
    cli()
