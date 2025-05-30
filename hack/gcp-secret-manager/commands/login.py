# Ignore dynamic imports
# pylint: disable=E0401, C0413

import subprocess

import click


@click.command()
def login():
    """Authenticate to Google Cloud."""

    try:
        subprocess.run(["gcloud", "auth", "application-default", "login"], check=True)
    except subprocess.CalledProcessError:
        click.echo("Failed to login.", err=True)
