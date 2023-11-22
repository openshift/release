import redfish
import sys
import time

bmc_address = sys.argv[1]
bmc_username = sys.argv[2]
bmc_password = sys.argv[3]
iso_path = sys.argv[4]
transfer_protocol_type = sys.argv[5]

def redfish_mount_remote(context):
    response = context.post(f"/redfish/v1/Managers/{manager}/VirtualMedia/{removable_disk}/Actions/VirtualMedia.InsertMedia",
                        body={"Image": iso_path, "TransferProtocolType": transfer_protocol_type,
                              "Inserted": True, **other_options})
    print(f"/redfish/v1/Managers/{manager}/VirtualMedia/{removable_disk}/Actions/VirtualMedia.InsertMedia")
    print({"Image": iso_path, "TransferProtocolType": transfer_protocol_type})
    imageIsMounted = False
    print(response.status)
    print(response.text)
    if response.status > 299:
        sys.exit(1)
    d = {}
    task = None
    if response.is_processing:
        while task is None or (task is not None and
                            (task.is_processing or not task.dict.get("TaskState") in ("Completed", "Exception"))):
            task = response.monitor(context)
            print("Task target: %s" % bmc_address)
            print("Task is_processing: %s" % task.is_processing)
            print("Task state: %s " % task.dict.get("TaskState"))
            print("Task status: %s" % task.status)
            retry_time = task.retry_after
            time.sleep(retry_time if retry_time else 5)
            if (task.dict.get("TaskState") in ("Completed")):
              imageIsMounted = True
        if task.status > 299:
            print()
            sys.exit(1)
        print()
    return imageIsMounted

context = redfish.redfish_client(bmc_address, username=bmc_username, password=bmc_password, max_retry=20)
context.login(auth=redfish.AuthMethod.BASIC)
response = context.get("/redfish/v1/Managers/")
manager = response.dict.get("Members")[0]["@odata.id"].split("/")[-1]
response = context.get(f"/redfish/v1/Managers/{manager}/VirtualMedia/")
removable_disk = list(filter((lambda x: x["@odata.id"].find("CD") != -1),
                             response.dict.get("Members")))[0]["@odata.id"].split("/")[-1]

### This is for AMI BMCs (currently only the arm64 servers) as they are affected by a bug that prevents the ISOs to be mounted/umounted
### correctly. The workaround is to reset the redfish internal redis database and make it populate again from the BMC.
if manager == "Self":
  print(f"Reset {bmc_address} BMC's redfish database...")
  try:
    response = context.post(f"/redfish/v1/Managers/{manager}/Actions/Oem/AMIManager.RedfishDBReset/",
                            body={"RedfishDBResetType": "ResetAll"})
    # Wait for the BMC to reset the database
    time.sleep(60)
  except Exception as e:
    print("Failed to reset the BMC's redfish database. Continuing anyway...")
  print("Reset BMC and wait for 5mins to be reachable again...")
  try:
    response = context.post(f"/redfish/v1/Managers/{manager}/Actions/Manager.Reset",
                            body={"ResetType": "ForceRestart"})
    # Wait for the BMC to reset
    time.sleep(300)
  except Exception as e:
    print("Failed to reset the BMC. Continuing anyway...")

print("Eject virtual media, if any...")
response = context.post(
    f"/redfish/v1/Managers/{manager}/VirtualMedia/{removable_disk}/Actions/VirtualMedia.EjectMedia", body={})
print(response.text)
time.sleep(30)
print("Insert new virtual media...")

other_options = {}
if transfer_protocol_type == "CIFS":
  other_options = {"UserName": "root", "Password": bmc_password}

retry_counter = 0
max_retries = 6
imageIsMounted = False

while retry_counter < max_retries and not imageIsMounted:
  imageIsMounted = redfish_mount_remote(context)
  retry_counter=retry_counter+1

print(f"Logging out of {bmc_address}")
context.logout()

if not imageIsMounted:
  print("Max retries, failing")
  sys.exit(1)