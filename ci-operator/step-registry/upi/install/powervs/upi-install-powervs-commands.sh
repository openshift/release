#!/bin/bash

# TODO: Deploy OCP on PowerVS
JENKINS_URL="$( cat /etc/credentials/JENKINS_URL )"; export export JENKINS_URL
JENKINS_USER="$( cat /etc/credentials/JENKINS_USER )"; export export JENKINS_USER
JENKINS_TOKEN="$( cat /etc/credentials/JENKINS_TOKEN )"; export export JENKINS_TOKEN