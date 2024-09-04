#!/usr/bin/env bash

TMP_FILE=$(mktemp)

cat <<EOF > "$TMP_FILE"
import jenkins
import time
import sys
import tenacity

def read_file_strip(filename: str) -> str:
    with open(filename, "r") as f:
        return f.read().strip()

class JenkinsAutomation:
    def __init__(self, endpoint: str, token: str):
        self.endpoint = endpoint
        self.token = token
        self.server = jenkins.Jenkins(endpoint)

    def start_and_block(self, name: str, pull_number: int) -> int:
        print(f"Starting job {name} with pull_number {pull_number}")
        queue_item = self._start(name, pull_number)
        print(f"Blocking until queue item {queue_item} is started")
        ret_val = self._block(queue_item)
        print(f"Queue item {queue_item} is started")
        return ret_val

    def _start(self, name: str, pull_number: int) -> int:
        params = {"pullnumber": pull_number}
        return self.server.build_job(name, params, self.token)

    @tenacity.retry(wait=tenacity.wait_fixed(5),
                    stop=tenacity.stop_after_delay(5 * 60 * 60))
    def _block(self, queue_item_id: int) -> int:
        queue_item = self.server.get_queue_item(queue_item_id)
        if not queue_item["blocked"]:
            return queue_item["executable"]["number"]
        else:
            raise Exception("Blocked")

    def wait_done(self, name: str, job_number: int) -> dict:
        output = ""
        while True:
            build_info = self.server.get_build_info(name, job_number)
            if not build_info["inProgress"]:
                break
            new_output = self.server.get_build_console_output(name, job_number)
            print(new_output[len(output):])
            output = new_output
            time.sleep(5)
        return build_info

def main():
    url = read_file_strip("/tmp/url")
    endpoint = f"https://{url}"
    token = read_file_strip("/tmp/token")
    name = "Lab140_DPU_Operator_Test"
    server = JenkinsAutomation(endpoint, token)
    job_number = server.start_and_block(name, 141)
    build_info = server.wait_done(name, job_number)
    sys.exit(build_info["result"] == "SUCCESS")

if __name__ == "__main__":
    main()
EOF
python "$TMP_FILE"
