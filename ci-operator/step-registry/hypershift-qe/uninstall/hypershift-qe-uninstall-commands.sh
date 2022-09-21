#!/bin/bash

hypershift install render --format=yaml | oc delete -f -