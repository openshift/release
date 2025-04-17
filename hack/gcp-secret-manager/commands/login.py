import click
import subprocess


@click.command()
def login():
    """Login command to authenticate to google cloud."""

    try:
        subprocess.run(["gcloud", "auth", "application-default", "login"], check=True)
    except subprocess.CalledProcessError:
        click.echo("Failed to login.", err=True)
