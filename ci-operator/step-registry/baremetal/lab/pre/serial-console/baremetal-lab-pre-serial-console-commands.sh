#!/bin/bash

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

# OVE automation requires setting serial console parameters to certain values
# See https://docs.google.com/presentation/d/1d3heMS5JAFmubJpW_8YuHa5r3AlCvj2tW0akQ6b8EQw/edit?usp=sharing
# ABI QE runs OVE automation on DELL bare metal servers
# shellcheck disable=SC2154
for bmhost in $(yq e -o=j -I=0 '.[]' "${SHARED_DIR}/hosts.yaml"); do

  vendor=$(echo "$bmhost" | jq -r '.vendor')

  if [[ "${vendor}" == "dell" ]]; then

    bmc_user=$(echo "$bmhost" | jq -r '.bmc_user')
    bmc_pass=$(echo "$bmhost" | jq -r '.bmc_pass')
    bmc_address=$(echo "$bmhost" | jq -r '.bmc_address')

    bios_attributes=$(curl -k -u "$bmc_user:$bmc_pass" https://$bmc_address/redfish/v1/Systems/System.Embedded.1/Bios | yq .Attributes)
    model=$(curl -k -u "$bmc_user:$bmc_pass" https://$bmc_address/redfish/v1/Systems/System.Embedded.1 | yq .Model)

    apply_settings="false"

    case "${model}" in
      "PowerEdge R740")
        if [[ $(echo "$bios_attributes" | jq -r '.SerialPortAddress') != "Serial1Com2Serial2Com1" ]] || [[ $(echo "$bios_attributes" | jq -r '.ExtSerialConnector') != "Serial2" ]]; then
          echo "Applying serial console settings to $bmc_address"
          curl -k -u "$bmc_user:$bmc_pass" -H "Content-Type: application/json" -X PATCH https://$bmc_address/redfish/v1/Systems/System.Embedded.1/Bios/Settings --data '{"Attributes":{"SerialPortAddress": "Serial1Com2Serial2Com1", "ExtSerialConnector": "Serial2"}}'
          apply_settings="true"
        fi
        ;;
      "PowerEdge R650")
        if [[ $(echo "$bios_attributes" | jq -r '.SerialPortAddress') != "Com1" ]]; then
          echo "Applying serial console settings to $bmc_address"
          curl -k -u "$bmc_user:$bmc_pass" -H "Content-Type: application/json" -X PATCH https://$bmc_address/redfish/v1/Systems/System.Embedded.1/Bios/Settings --data '{"Attributes":{"SerialPortAddress": "Com1"}}'
          apply_settings="true"
        fi
        ;;
      *)
        echo "Unsupported model"
    esac

    if [ "$apply_settings" = "true" ] ; then
        echo "Scheduling BIOS Settings job"
        curl -k -u "$bmc_user:$bmc_pass" -H "Content-Type: application/json" -X POST https://$bmc_address/redfish/v1/Managers/iDRAC.Embedded.1/Jobs --data '{"TargetSettingsURI":"/redfish/v1/Systems/System.Embedded.1/Bios/Settings"}'
    fi

  fi
done

