#!/bin/bash

bin/hypershift install render --format=yaml | oc delete -f -