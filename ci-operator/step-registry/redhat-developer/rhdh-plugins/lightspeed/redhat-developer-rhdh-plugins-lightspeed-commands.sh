#!/bin/bash

cd workspaces/lightspeed || exit

yarn
yarn tsc
yarn build:all
npx @janus-idp/cli@latest package package-dynamic-plugins --tag quay.io/rhdh-pai-qe/lightspeed:main