#!/bin/bash

###### fix: Backups created only once tests (OCPQE-17901) ######

function test_backups_created_only_once () {
  TEST_PASSED=true
  export KUBECONFIG="${SHARED_DIR}/hs-mc.kubeconfig"

  echo "Getting schedule configuration"
  SCHEDULE_OUTPUT=$(oc get schedule -n openshift-adp-operator | tail -3)
  echo "Confirming that hourly, daily and weekly backups are available, enabled and with correct cron expression"
  echo "$SCHEDULE_OUTPUT" | while read -r line; do
    SCHEDULE_NAME=$(echo "$line" | awk '{print $1}')
    SCHEDULE_ENABLED=$(echo "$line" | awk '{print $2}')
    SCHEDULE_CRON=$(echo "$line" | awk '{print $3 " " $4 " " $5 " " $6 " " $7}')
    if ! [[ "$SCHEDULE_NAME" =~ ^("daily-full-backup"|"hourly-full-backup"|"weekly-full-backup") ]]; then
      echo "Found unexpected name: '$SCHEDULE_NAME'. Expected one of: ['daily-full-backup'|'hourly-full-backup'|'weekly-full-backup']"
      TEST_PASSED=false
      break
    fi
    if [ "$SCHEDULE_ENABLED" != "Enabled" ]; then
      echo "Schedule '$SCHEDULE_NAME' should be set to 'Enabled'. Found: $SCHEDULE_ENABLED"
      TEST_PASSED=false
      break
    fi
    case $SCHEDULE_NAME in

      daily-full-backup)
        if [ "$SCHEDULE_CRON" != "0 1 * * *" ]; then
          echo "Schedule '$SCHEDULE_NAME' should be set to '0 1 * * *'. Found: $SCHEDULE_CRON"
          TEST_PASSED=false
          break
        fi
        ;;

      hourly-full-backup)
        if [ "$SCHEDULE_CRON" != "17 * * * *" ]; then
          echo "Schedule '$SCHEDULE_NAME' should be set to '17 * * * *'. Found: $SCHEDULE_CRON"
          TEST_PASSED=false
          break
        fi
        ;;

      weekly-full-backup)
        if [ "$SCHEDULE_CRON" != "0 2 * * 1" ]; then
          echo "Schedule '$SCHEDULE_NAME' should be set to '0 2 * * 1'. Found: $SCHEDULE_CRON"
          TEST_PASSED=false
          break
        fi
        ;;
    esac
  done

  update_results "OCPQE-17901" $TEST_PASSED
}