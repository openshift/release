# Ignore dynamic imports
# pylint: disable=E0401, C0413

import os
import subprocess

import click


@click.command()
def login():
    """Authenticate to Google Cloud."""

    try:
        proc = subprocess.Popen(
            ["gcloud", "auth", "application-default", "login"],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )

        for line in proc.stdout:
            stripped = line.strip()
            if stripped.startswith("http"):
                click.echo(
                    f"A URL to authenticate has been opened in your browser:\n\n    {stripped}\n"
                )

        proc.wait()
        if proc.returncode != 0:
            raise subprocess.CalledProcessError(proc.returncode, "gcloud")

        creds_path = os.environ.get("CLOUDSDK_CONFIG", "~/.config/gcloud")
        creds_file = os.path.join(creds_path, "application_default_credentials.json")

        click.echo(
            f"Login successful. Credentials are stored locally ({creds_file}) for this CLI only"
            " and will persist while you use the CLI."
            "\nTo reset the CLI environment and log out, run this script with the `clean` command."
        )
    except subprocess.CalledProcessError:
        click.echo("\nLogin failed.", err=True)
