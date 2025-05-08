#!/bin/bash


echo "waiting for $SLEEP_DURATION "

sleep "$SLEEP_DURATION" &
wait
