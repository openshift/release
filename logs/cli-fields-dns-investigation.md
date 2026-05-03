# CLI-Fields Job DNS Investigation

## Job Details
- **PR**: 78362 (openshift/release)
- **Job**: rehearse-78362-pull-ci-osac-project-osac-installer-main-e2e-metal-vmaas-compute-instance-cli-fields-golden
- **Failed Build ID**: 2050741764813230080
- **Date**: 2026-05-03 02:05:10Z

## Failure Symptoms

### Primary Error
```
E0503 02:05:10.631716       4 memcache.go:265] "Unhandled Error" err="couldn't get current server API group list: Get \"https://api.test-infra-cluster-d55276d8.redhat.com:6443/api?timeout=32s\": dial tcp: lookup api.test-infra-cluster-d55276d8.redhat.com on 127.0.0.1:53: connection refused to the server api.test-infra-cluster-d55276d8.redhat.com:6443 was refused - did you specify the right host or port?
```

### Must-Gather Evidence
```
--- Hub API reachable? ---
HUB API UNREACHABLE

--- Virt API reachable? ---
ok
```

### Important Observations
1. **Hub API (192.168.131.10:6443)** - UNREACHABLE via hostname `api.test-infra-cluster-d55276d8.redhat.com`
2. **Virt API (192.168.130.10:6443)** - REACHABLE (same should work via IP)
3. **VM Status** - Both VMs were running
4. **Test Phase** - Failure occurred during test setup, specifically when trying to query the cluster domain

## DNS Configuration Flow

### Step 1: assisted-ofcir-setup (01:25:02-01:25:27)
From `/tmp/review-release-78362/ci-operator/step-registry/assisted/ofcir/setup/assisted-ofcir-setup-commands.sh`:

**Lines 209-243**: Configures NetworkManager DNS servers
```yaml
- name: Extract DNS servers from /etc/resolv.conf
  ansible.builtin.shell: |
    awk '/^nameserver/ {print $2}' /etc/resolv.conf | paste -sd "," -
  register: dns_servers

- name: Configure NetworkManager to use those DNS servers
  ansible.builtin.ini_file:
    dest: /etc/NetworkManager/conf.d/dns-servers.conf
    section: 'global-dns-domain-*'
    option: servers
    value: "{{ dns_servers.stdout }}"

- name: Reload NetworkManager to pick up new DNS settings
  ansible.builtin.systemd:
    name: NetworkManager
    state: reloaded
```

**Analysis**: This reads the CURRENT nameservers (before dnsmasq) and locks NetworkManager to use them. This happens BEFORE golden-setup adds dnsmasq.

### Step 2: osac-project-golden-setup (01:25:36-02:04:54)
From `/tmp/review-release-78362/ci-operator/step-registry/osac-project/golden/setup/osac-project-golden-setup-commands.sh`:

**Lines 96-104**: Configures dnsmasq and updates resolv.conf
```bash
echo "$(date +%T) Configuring DNS for cluster hostnames..."
cat > /etc/dnsmasq.d/golden-clusters.conf <<DNSEOF
address=/test-infra-cluster-d55276d8.redhat.com/192.168.131.10
address=/test-infra-cluster-ad07fc71.redhat.com/192.168.130.10
DNSEOF
systemctl enable --now dnsmasq
echo "nameserver 127.0.0.1" > /etc/resolv.conf.golden
cat /etc/resolv.conf >> /etc/resolv.conf.golden
cp /etc/resolv.conf.golden /etc/resolv.conf
```

**Evidence from build log**:
```
01:53:17 Configuring DNS for cluster hostnames...
Created symlink /etc/systemd/system/multi-user.target.wants/dnsmasq.service → /usr/lib/systemd/system/dnsmasq.service.
01:53:17 Starting VMs...
```

**Analysis**: This successfully starts dnsmasq and prepends `nameserver 127.0.0.1` to resolv.conf. BUT NetworkManager is still active and configured to manage DNS.

## The Race Condition

### Timeline
1. **01:25:02** - assisted-ofcir-setup extracts current nameservers (WITHOUT 127.0.0.1) and configures NetworkManager
2. **01:25:27** - NetworkManager reloaded with DNS config (no 127.0.0.1)
3. **01:53:17** - golden-setup starts dnsmasq and manually edits /etc/resolv.conf to add `nameserver 127.0.0.1`
4. **02:05:10** - Test fails with "connection refused" when trying to reach hub API via hostname

### Theory: NetworkManager Overwrites resolv.conf

**Trigger Events** that could cause NetworkManager to regenerate /etc/resolv.conf:
- DHCP lease renewal
- Network interface state change
- NetworkManager restart
- Manual `nmcli connection up/down`

**What Happens**:
1. NetworkManager regenerates /etc/resolv.conf based on `/etc/NetworkManager/conf.d/dns-servers.conf`
2. This file contains the nameservers from Step 1 (BEFORE dnsmasq)
3. `nameserver 127.0.0.1` is NOT in the NetworkManager config
4. Result: resolv.conf no longer has 127.0.0.1 first
5. DNS queries for `test-infra-cluster-d55276d8.redhat.com` go to upstream DNS instead of dnsmasq
6. Upstream DNS doesn't know about this internal cluster
7. DNS resolution fails → "connection refused" when trying to connect to the resolved IP (or no IP at all)

### Evidence Supporting This Theory

**From must-gather**: The resolv.conf dump is MISSING from the must-gather output, even though the test script has code to print it (line 71-72 of osac-project-golden-test-commands.sh):

```bash
echo "--- resolv.conf (DNS config) ---"
cat /etc/resolv.conf 2>&1 || true
```

This section is present in the script but NOT in the output. This suggests the must-gather script was interrupted or failed before reaching this line.

**However**, we do see this error pattern:
- Hub API (needs DNS resolution via dnsmasq): UNREACHABLE
- Virt API (same setup, also needs DNS): Initially UNREACHABLE in "Virt cluster VMIs" section
- Direct IP checks: Would work if DNS was the only issue

### Alternative Theory: Port 6443 Not Listening

The error is "connection refused" not "no route to host" or "timeout". This means:
1. DNS resolution succeeded (got an IP address)
2. TCP connection reached the IP
3. No process is listening on port 6443

**Evidence**:
- `curl -sk --connect-timeout 5 https://192.168.131.10:6443/readyz` returned "HUB API UNREACHABLE"
- This is a DIRECT IP connection, no DNS involved
- The VM was running (`virsh list` shows both VMs as running)
- The API server inside the VM crashed or was not started

### Which Theory Is Correct?

Looking at the error more carefully:
```
dial tcp: lookup api.test-infra-cluster-d55276d8.redhat.com on 127.0.0.1:53: connection refused
```

Wait - this says "lookup ... on 127.0.0.1:53: connection refused". This means:
- DNS query WAS sent to 127.0.0.1:53 (dnsmasq)
- The connection to dnsmasq was REFUSED

So resolv.conf DOES have `nameserver 127.0.0.1`, but dnsmasq is NOT listening or crashed!

### Updated Theory: dnsmasq Crashed or Not Running

Let me check if dnsmasq was actually running:
- Setup log shows: `systemctl enable --now dnsmasq` succeeded (no error)
- No dnsmasq process status in must-gather (not captured)

The error "connection refused" to 127.0.0.1:53 means:
1. resolv.conf DOES have `nameserver 127.0.0.1` (DNS query went there)
2. dnsmasq is NOT listening on port 53
3. Possible causes:
   - dnsmasq failed to start
   - dnsmasq crashed after starting
   - Another process is using port 53
   - systemd-resolved is interfering

## Missing Data

The must-gather script should have captured but DIDN'T:
- `/etc/resolv.conf` content
- `systemctl status dnsmasq` output
- `ss -tuln | grep :53` (what's listening on port 53)
- `journalctl -u dnsmasq` logs

These sections are in the test script (lines 71-72) but were NOT printed in the output.

## Root Cause Hypothesis

**Most Likely**: dnsmasq failed to start or crashed, AND the must-gather was truncated/interrupted.

**Evidence**:
1. Error shows DNS query to 127.0.0.1:53 was refused (dnsmasq not listening)
2. resolv.conf dump is missing from must-gather (script interrupted?)
3. Setup showed dnsmasq enable+start but no verification it's running
4. Test failed very quickly (18s after test step started)

**Why dnsmasq might fail**:
- Port 53 already in use (systemd-resolved?)
- Configuration error in /etc/dnsmasq.d/golden-clusters.conf
- Permission issues
- SELinux denials

## Next Steps

1. **Add dnsmasq health check to golden-setup script** (after line 104):
   ```bash
   echo "$(date +%T) Verifying dnsmasq is running..."
   systemctl status dnsmasq || (journalctl -u dnsmasq -n 50 && exit 1)
   ss -tuln | grep :53 || (echo "ERROR: Nothing listening on port 53" && exit 1)
   dig @127.0.0.1 test-infra-cluster-d55276d8.redhat.com || (echo "ERROR: dnsmasq not responding" && exit 1)
   ```

2. **Stop systemd-resolved if present** (before starting dnsmasq):
   ```bash
   systemctl stop systemd-resolved || true
   systemctl disable systemd-resolved || true
   ```

3. **Add resolv.conf verification** (after line 104):
   ```bash
   echo "$(date +%T) Verifying resolv.conf..."
   cat /etc/resolv.conf
   grep "^nameserver 127.0.0.1" /etc/resolv.conf || (echo "ERROR: 127.0.0.1 not first nameserver" && exit 1)
   ```

4. **Make NetworkManager leave resolv.conf alone**:
   ```bash
   cat > /etc/NetworkManager/conf.d/no-dns.conf <<EOF
   [main]
   dns=none
   EOF
   systemctl reload NetworkManager
   ```

## Conclusion

The cli-fields test failed because:
1. resolv.conf was configured to use 127.0.0.1 (dnsmasq) by golden-setup
2. dnsmasq was NOT actually running/listening on port 53
3. DNS queries to 127.0.0.1:53 were refused
4. Without DNS resolution, the test couldn't connect to the hub cluster via hostname
5. The must-gather script successfully captured VM status but the "resolv.conf (DNS config)" section is mysteriously MISSING from the output

**Evidence Analysis**:

### The Smoking Gun
The error message contains the critical detail:
```
lookup api.test-infra-cluster-d55276d8.redhat.com on 127.0.0.1:53: connection refused
```

This means:
- resolv.conf DOES contain `nameserver 127.0.0.1` (the lookup went there)
- Port 53 on 127.0.0.1 is NOT listening (connection refused)
- Therefore: dnsmasq failed to start or crashed

### Missing Diagnostic Section
The test script (`osac-project-golden-test-commands.sh`) lines 71-72 should print:
```bash
echo "--- resolv.conf (DNS config) ---"
cat /etc/resolv.conf 2>&1 || true
```

This section appears in the script but is **completely absent** from the must-gather output. It should appear between "virsh dommemstat test-infra-cluster-ad07fc71-master-0" (line 147-160 of test log) and "Hub API reachable?" (line 162).

The fact that the script continued past this point (it printed "Hub API reachable?") means the command didn't cause the script to exit. The output was simply... not captured.

### Why dnsmasq Failed

Most likely causes:
1. **Port 53 already in use** - systemd-resolved or another DNS service
2. **Configuration error** - /etc/dnsmasq.d/golden-clusters.conf syntax error
3. **Permission/SELinux** - dnsmasq can't bind to port 53
4. **Service start race** - systemd said "started" but process crashed immediately

The setup log shows:
```
Created symlink /etc/systemd/system/multi-user.target.wants/dnsmasq.service → /usr/lib/systemd/system/dnsmasq.service.
```

But `systemctl enable --now dnsmasq` doesn't guarantee the service is running - it just asks systemd to start it. If it crashes immediately, systemd returns success.

**Confidence**: HIGH. The error message unambiguously states "lookup ... on 127.0.0.1:53: connection refused". This can only mean dnsmasq is not listening.

**Recommendation**: 
1. Add dnsmasq health check to golden-setup (see "Next Steps" section above)
2. Stop systemd-resolved before starting dnsmasq
3. Verify /etc/resolv.conf content after changes
4. Test DNS resolution with `dig @127.0.0.1` before proceeding

**User's Theory Assessment**: The user's theory about NetworkManager overwriting resolv.conf is PARTIALLY correct in design but NOT what happened here. The assisted-ofcir-setup DOES configure NetworkManager DNS before golden-setup adds dnsmasq, creating a risk that NetworkManager could regenerate resolv.conf. However, the actual error shows that DNS queries DID go to 127.0.0.1:53 (meaning resolv.conf was correct at test time), but dnsmasq wasn't there to answer.
