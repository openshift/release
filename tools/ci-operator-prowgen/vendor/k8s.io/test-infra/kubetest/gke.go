/*
Copyright 2017 The Kubernetes Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

// Package main / gke.go provides the Google Container Engine (GKE)
// kubetest deployer via newGKE().
//
// TODO(zmerlynn): Pull this out to a separate package?
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io/ioutil"
	"log"
	"os"
	"os/exec"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"k8s.io/test-infra/kubetest/util"
)

const (
	defaultPool   = "default"
	e2eAllow      = "tcp:22,tcp:80,tcp:8080,tcp:30000-32767,udp:30000-32767"
	defaultCreate = "container clusters create --quiet"
)

var (
	gkeAdditionalZones             = flag.String("gke-additional-zones", "", "(gke only) List of additional Google Compute Engine zones to use. Clusters are created symmetrically across zones by default, see --gke-shape for details.")
	gkeNodeLocations               = flag.String("gke-node-locations", "", "(gke only) List of Google Compute Engine zones to use.")
	gkeEnvironment                 = flag.String("gke-environment", "", "(gke only) Container API endpoint to use, one of 'test', 'staging', 'prod', or a custom https:// URL")
	gkeShape                       = flag.String("gke-shape", `{"default":{"Nodes":3,"MachineType":"n1-standard-2"}}`, `(gke only) A JSON description of node pools to create. The node pool 'default' is required and used for initial cluster creation. All node pools are symmetric across zones, so the cluster total node count is {total nodes in --gke-shape} * {1 + (length of --gke-additional-zones)}. Example: '{"default":{"Nodes":999,"MachineType:":"n1-standard-1"},"heapster":{"Nodes":1, "MachineType":"n1-standard-8"}}`)
	gkeCreateArgs                  = flag.String("gke-create-args", "", "(gke only) (deprecated, use a modified --gke-create-command') Additional arguments passed directly to 'gcloud container clusters create'")
	gkeCommandGroup                = flag.String("gke-command-group", "", "(gke only) Use a different gcloud track (e.g. 'alpha') for all 'gcloud container' commands. Note: This is added to --gke-create-command on create. You should only use --gke-command-group if you need to change the gcloud track for *every* gcloud container command.")
	gkeCreateCommand               = flag.String("gke-create-command", defaultCreate, "(gke only) gcloud subcommand used to create a cluster. Modify if you need to pass arbitrary arguments to create.")
	gkeCustomSubnet                = flag.String("gke-custom-subnet", "", "(gke only) if specified, we create a custom subnet with the specified options and use it for the gke cluster. The format should be '<subnet-name> --region=<subnet-gcp-region> --range=<subnet-cidr> <any other optional params>'.")
	gkeSingleZoneNodeInstanceGroup = flag.Bool("gke-single-zone-node-instance-group", true, "(gke only) Add instance groups from a single zone to the NODE_INSTANCE_GROUP env variable.")

	// poolRe matches instance group URLs of the form `https://www.googleapis.com/compute/v1/projects/some-project/zones/a-zone/instanceGroupManagers/gke-some-cluster-some-pool-90fcb815-grp`. Match meaning:
	// m[0]: path starting with zones/
	// m[1]: zone
	// m[2]: pool name (passed to e2es)
	// m[3]: unique hash (used as nonce for firewall rules)
	poolRe = regexp.MustCompile(`zones/([^/]+)/instanceGroupManagers/(gke-.*-([0-9a-f]{8})-grp)$`)

	urlRe = regexp.MustCompile(`https://.*/`)
)

type gkeNodePool struct {
	Nodes       int
	MachineType string
}

type gkeDeployer struct {
	project                     string
	zone                        string
	region                      string
	location                    string
	additionalZones             string
	nodeLocations               string
	cluster                     string
	shape                       map[string]gkeNodePool
	network                     string
	subnetwork                  string
	subnetworkRegion            string
	image                       string
	imageFamily                 string
	imageProject                string
	commandGroup                []string
	createCommand               []string
	singleZoneNodeInstanceGroup bool

	setup          bool
	kubecfg        string
	instanceGroups []*ig
}

type ig struct {
	path string
	zone string
	name string
	uniq string
}

var _ deployer = &gkeDeployer{}

func newGKE(provider, project, zone, region, network, image, imageFamily, imageProject, cluster string, testArgs *string, upgradeArgs *string) (*gkeDeployer, error) {
	if provider != "gke" {
		return nil, fmt.Errorf("--provider must be 'gke' for GKE deployment, found %q", provider)
	}
	g := &gkeDeployer{}

	if cluster == "" {
		return nil, fmt.Errorf("--cluster must be set for GKE deployment")
	}
	g.cluster = cluster

	if project == "" {
		return nil, fmt.Errorf("--gcp-project must be set for GKE deployment")
	}
	g.project = project

	if zone == "" && region == "" {
		return nil, fmt.Errorf("--gcp-zone or --gcp-region must be set for GKE deployment")
	} else if zone != "" && region != "" {
		return nil, fmt.Errorf("--gcp-zone and --gcp-region cannot both be set")
	}
	if zone != "" {
		g.zone = zone
		g.location = "--zone=" + zone
	} else if region != "" {
		g.region = region
		g.location = "--region=" + region
	}

	if network == "" {
		return nil, fmt.Errorf("--gcp-network must be set for GKE deployment")
	}
	g.network = network

	if image == "" {
		return nil, fmt.Errorf("--gcp-node-image must be set for GKE deployment")
	}
	if strings.ToUpper(image) == "CUSTOM" {
		if imageFamily == "" || imageProject == "" {
			return nil, fmt.Errorf("--image-family and --image-project must be set for GKE deployment if --gcp-node-image=CUSTOM")
		}
	}
	g.imageFamily = imageFamily
	g.imageProject = imageProject
	g.image = image

	g.additionalZones = *gkeAdditionalZones
	g.nodeLocations = *gkeNodeLocations

	err := json.Unmarshal([]byte(*gkeShape), &g.shape)
	if err != nil {
		return nil, fmt.Errorf("--gke-shape must be valid JSON, unmarshal error: %v, JSON: %q", err, *gkeShape)
	}
	if _, ok := g.shape[defaultPool]; !ok {
		return nil, fmt.Errorf("--gke-shape must include a node pool named 'default', found %q", *gkeShape)
	}

	g.commandGroup = strings.Fields(*gkeCommandGroup)

	g.createCommand = append([]string{}, g.commandGroup...)
	g.createCommand = append(g.createCommand, strings.Fields(*gkeCreateCommand)...)
	createArgs := strings.Fields(*gkeCreateArgs)
	if len(createArgs) > 0 {
		log.Printf("--gke-create-args is deprecated, please use '--gke-create-command=%s %s'", defaultCreate, *gkeCreateArgs)
	}
	g.createCommand = append(g.createCommand, createArgs...)

	if err := util.MigrateOptions([]util.MigratedOption{{
		Env:    "CLOUDSDK_API_ENDPOINT_OVERRIDES_CONTAINER",
		Option: gkeEnvironment,
		Name:   "--gke-environment",
	}}); err != nil {
		return nil, err
	}

	var endpoint string
	switch env := *gkeEnvironment; {
	case env == "test":
		endpoint = "https://test-container.sandbox.googleapis.com/"
	case env == "staging":
		endpoint = "https://staging-container.sandbox.googleapis.com/"
	case env == "prod":
		endpoint = "https://container.googleapis.com/"
	case urlRe.MatchString(env):
		endpoint = env
	default:
		return nil, fmt.Errorf("--gke-environment must be one of {test,staging,prod} or match %v, found %q", urlRe, env)
	}
	if err := os.Setenv("CLOUDSDK_API_ENDPOINT_OVERRIDES_CONTAINER", endpoint); err != nil {
		return nil, err
	}

	// Override kubecfg to a temporary file rather than trashing the user's.
	f, err := ioutil.TempFile("", "gke-kubecfg")
	if err != nil {
		return nil, err
	}
	defer f.Close()
	kubecfg := f.Name()
	if err := f.Chmod(0600); err != nil {
		return nil, err
	}
	g.kubecfg = kubecfg

	// We want no KUBERNETES_PROVIDER, but to set
	// KUBERNETES_CONFORMANCE_PROVIDER and
	// KUBERNETES_CONFORMANCE_TEST. This prevents ginkgo-e2e.sh from
	// using the cluster/gke functions.
	//
	// We do this in the deployer constructor so that
	// cluster/gce/list-resources.sh outputs the same provider for the
	// extent of the binary. (It seems like it belongs in TestSetup,
	// but that way leads to madness.)
	//
	// TODO(zmerlynn): This is gross.
	if err := os.Unsetenv("KUBERNETES_PROVIDER"); err != nil {
		return nil, err
	}
	if err := os.Setenv("KUBERNETES_CONFORMANCE_TEST", "yes"); err != nil {
		return nil, err
	}
	if err := os.Setenv("KUBERNETES_CONFORMANCE_PROVIDER", "gke"); err != nil {
		return nil, err
	}

	// TODO(zmerlynn): Another snafu of cluster/gke/list-resources.sh:
	// Set KUBE_GCE_INSTANCE_PREFIX so that we don't accidentally pick
	// up CLUSTER_NAME later.
	if err := os.Setenv("KUBE_GCE_INSTANCE_PREFIX", "gke-"+g.cluster); err != nil {
		return nil, err
	}

	// set --num-nodes flag for ginkgo, since NUM_NODES is not set for gke deployer.
	numNodes := strconv.Itoa(g.shape[defaultPool].Nodes)
	// testArgs can be empty, and we need to support this case
	*testArgs = strings.Join(util.SetFieldDefault(strings.Fields(*testArgs), "--num-nodes", numNodes), " ")

	if *upgradeArgs != "" {
		// --upgrade-target will be passed to e2e upgrade framework to get a valid update version.
		// See usage from https://github.com/kubernetes/kubernetes/blob/master/hack/get-build.sh for supported targets.
		// Here we special case for gke-latest and will extract an actual valid gke version.
		// - gke-latest will be resolved to the latest gke version, and
		// - gke-latest-1.7 will be resolved to the latest 1.7 patch version supported on gke.
		fields, val, exist := util.ExtractField(strings.Fields(*upgradeArgs), "--upgrade-target")
		if exist {
			if strings.HasPrefix(val, "gke-latest") {
				releasePrefix := ""
				if strings.HasPrefix(val, "gke-latest-") {
					releasePrefix = strings.TrimPrefix(val, "gke-latest-")
				}
				if val, err = getLatestGKEVersion(project, zone, region, releasePrefix); err != nil {
					return nil, fmt.Errorf("fail to get latest gke version : %v", err)
				}
			}
			fields = util.SetFieldDefault(fields, "--upgrade-target", val)
		}
		*upgradeArgs = strings.Join(util.SetFieldDefault(fields, "--num-nodes", numNodes), " ")
	}

	g.singleZoneNodeInstanceGroup = *gkeSingleZoneNodeInstanceGroup

	return g, nil
}

func (g *gkeDeployer) Up() error {
	// Create network if it doesn't exist.
	if control.NoOutput(exec.Command("gcloud", "compute", "networks", "describe", g.network,
		"--project="+g.project,
		"--format=value(name)")) != nil {
		// Assume error implies non-existent.
		log.Printf("Couldn't describe network '%s', assuming it doesn't exist and creating it", g.network)
		if err := control.FinishRunning(exec.Command("gcloud", "compute", "networks", "create", g.network,
			"--project="+g.project,
			"--subnet-mode=auto")); err != nil {
			return err
		}
	}
	// Create a custom subnet in that network if it was asked for.
	if *gkeCustomSubnet != "" {
		customSubnetFields := strings.Fields(*gkeCustomSubnet)
		createSubnetCommand := []string{"compute", "networks", "subnets", "create"}
		createSubnetCommand = append(createSubnetCommand, "--project="+g.project, "--network="+g.network)
		createSubnetCommand = append(createSubnetCommand, customSubnetFields...)
		if err := control.FinishRunning(exec.Command("gcloud", createSubnetCommand...)); err != nil {
			return err
		}
		g.subnetwork = customSubnetFields[0]
		g.subnetworkRegion = customSubnetFields[1]
	}

	def := g.shape[defaultPool]
	args := make([]string, len(g.createCommand))
	copy(args, g.createCommand)
	args = append(args,
		"--project="+g.project,
		g.location,
		"--machine-type="+def.MachineType,
		"--image-type="+g.image,
		"--num-nodes="+strconv.Itoa(def.Nodes),
		"--network="+g.network,
	)
	if strings.ToUpper(g.image) == "CUSTOM" {
		args = append(args, "--image-family="+g.imageFamily)
		args = append(args, "--image-project="+g.imageProject)
	}
	if g.subnetwork != "" {
		args = append(args, "--subnetwork="+g.subnetwork)
	}
	if g.additionalZones != "" {
		args = append(args, "--additional-zones="+g.additionalZones)
		if err := os.Setenv("MULTIZONE", "true"); err != nil {
			return fmt.Errorf("error setting MULTIZONE env variable: %v", err)
		}

	}
	if g.nodeLocations != "" {
		args = append(args, "--node-locations="+g.nodeLocations)
		numNodeLocations := strings.Split(g.nodeLocations, ",")
		if len(numNodeLocations) > 1 {
			if err := os.Setenv("MULTIZONE", "true"); err != nil {
				return fmt.Errorf("error setting MULTIZONE env variable: %v", err)
			}
		}
	}
	// TODO(zmerlynn): The version should be plumbed through Extract
	// or a separate flag rather than magic env variables.
	if v := os.Getenv("CLUSTER_API_VERSION"); v != "" {
		args = append(args, "--cluster-version="+v)
	}
	args = append(args, g.cluster)
	if err := control.FinishRunning(exec.Command("gcloud", args...)); err != nil {
		return fmt.Errorf("error creating cluster: %v", err)
	}
	for poolName, pool := range g.shape {
		if poolName == defaultPool {
			continue
		}
		if err := control.FinishRunning(exec.Command("gcloud", g.containerArgs(
			"node-pools", "create", poolName,
			"--cluster="+g.cluster,
			"--project="+g.project,
			g.location,
			"--machine-type="+pool.MachineType,
			"--num-nodes="+strconv.Itoa(pool.Nodes))...)); err != nil {
			return fmt.Errorf("error creating node pool %q: %v", poolName, err)
		}
	}
	return nil
}

func (g *gkeDeployer) IsUp() error {
	return isUp(g)
}

// DumpClusterLogs for GKE generates a small script that wraps
// log-dump.sh with the appropriate shell-fu to get the cluster
// dumped.
//
// TODO(zmerlynn): This whole path is really gross, but this seemed
// the least gross hack to get this done.
//
// TODO(shyamjvs): Make this work with multizonal and regional clusters.
func (g *gkeDeployer) DumpClusterLogs(localPath, gcsPath string) error {
	// gkeLogDumpTemplate is a template of a shell script where
	// - %[1]s is the project
	// - %[2]s is the zone
	// - %[3]s is a filter composed of the instance groups
	// - %[4]s is the log-dump.sh command line
	const gkeLogDumpTemplate = `
function log_dump_custom_get_instances() {
  if [[ $1 == "master" ]]; then
    return 0
  fi

  gcloud compute instances list '--project=%[1]s' '--filter=%[4]s' '--format=get(name)'
}
export -f log_dump_custom_get_instances
# Set below vars that log-dump.sh expects in order to use scp with gcloud.
export PROJECT=%[1]s
export ZONE='%[2]s'
export KUBERNETES_PROVIDER=gke
export KUBE_NODE_OS_DISTRIBUTION='%[3]s'
%[5]s
`
	// Prevent an obvious injection.
	if strings.Contains(localPath, "'") || strings.Contains(gcsPath, "'") {
		return fmt.Errorf("%q or %q contain single quotes - nice try", localPath, gcsPath)
	}

	// Generate a slice of filters to be OR'd together below
	if err := g.getInstanceGroups(); err != nil {
		return err
	}
	var filters []string
	for _, ig := range g.instanceGroups {
		filters = append(filters, fmt.Sprintf("(metadata.created-by:*%s)", ig.path))
	}

	// Generate the log-dump.sh command-line
	var dumpCmd string
	if gcsPath == "" {
		dumpCmd = fmt.Sprintf("./cluster/log-dump/log-dump.sh '%s'", localPath)
	} else {
		dumpCmd = fmt.Sprintf("./cluster/log-dump/log-dump.sh '%s' '%s'", localPath, gcsPath)
	}
	return control.FinishRunning(exec.Command("bash", "-c", fmt.Sprintf(gkeLogDumpTemplate,
		g.project,
		g.zone,
		os.Getenv("NODE_OS_DISTRIBUTION"),
		strings.Join(filters, " OR "),
		dumpCmd)))
}

func (g *gkeDeployer) TestSetup() error {
	if g.setup {
		// Ensure setup is a singleton.
		return nil
	}
	if err := g.getKubeConfig(); err != nil {
		return err
	}
	if err := g.getInstanceGroups(); err != nil {
		return err
	}
	if err := g.ensureFirewall(); err != nil {
		return err
	}
	if err := g.setupEnv(); err != nil {
		return err
	}
	g.setup = true
	return nil
}

func (g *gkeDeployer) getKubeConfig() error {
	info, err := os.Stat(g.kubecfg)
	if err != nil {
		return err
	}
	if info.Size() > 0 {
		// Assume that if we already have it, it's good.
		return nil
	}
	if err := os.Setenv("KUBECONFIG", g.kubecfg); err != nil {
		return err
	}
	if err := control.FinishRunning(exec.Command("gcloud", g.containerArgs("clusters", "get-credentials", g.cluster,
		"--project="+g.project,
		g.location)...)); err != nil {
		return fmt.Errorf("error executing get-credentials: %v", err)
	}
	return nil
}

// setupEnv is to appease ginkgo-e2e.sh and other pieces of the e2e infrastructure. It
// would be nice to handle this elsewhere, and not with env
// variables. c.f. kubernetes/test-infra#3330.
func (g *gkeDeployer) setupEnv() error {
	// If singleZoneNodeInstanceGroup is true, set NODE_INSTANCE_GROUP to the
	// names of instance groups that are in the same zone as the lexically first
	// instance group. Otherwise set NODE_INSTANCE_GROUP to the names of all
	// instance groups.
	var filt []string
	zone := g.instanceGroups[0].zone
	for _, ig := range g.instanceGroups {
		if !g.singleZoneNodeInstanceGroup || ig.zone == zone {
			filt = append(filt, ig.name)
		}
	}
	if err := os.Setenv("NODE_INSTANCE_GROUP", strings.Join(filt, ",")); err != nil {
		return fmt.Errorf("error setting NODE_INSTANCE_GROUP: %v", err)
	}
	return nil
}

func (g *gkeDeployer) ensureFirewall() error {
	firewall, err := g.getClusterFirewall()
	if err != nil {
		return fmt.Errorf("error getting unique firewall: %v", err)
	}
	if control.NoOutput(exec.Command("gcloud", "compute", "firewall-rules", "describe", firewall,
		"--project="+g.project,
		"--format=value(name)")) == nil {
		// Assume that if this unique firewall exists, it's good to go.
		return nil
	}
	log.Printf("Couldn't describe firewall '%s', assuming it doesn't exist and creating it", firewall)

	tagOut, err := exec.Command("gcloud", "compute", "instances", "list",
		"--project="+g.project,
		"--filter=metadata.created-by:*"+g.instanceGroups[0].path,
		"--limit=1",
		"--format=get(tags.items)").Output()
	if err != nil {
		return fmt.Errorf("instances list failed: %s", util.ExecError(err))
	}
	tag := strings.TrimSpace(string(tagOut))
	if tag == "" {
		return fmt.Errorf("instances list returned no instances (or instance has no tags)")
	}

	if err := control.FinishRunning(exec.Command("gcloud", "compute", "firewall-rules", "create", firewall,
		"--project="+g.project,
		"--network="+g.network,
		"--allow="+e2eAllow,
		"--target-tags="+tag)); err != nil {
		return fmt.Errorf("error creating e2e firewall: %v", err)
	}
	return nil
}

func (g *gkeDeployer) getInstanceGroups() error {
	if len(g.instanceGroups) > 0 {
		return nil
	}
	igs, err := exec.Command("gcloud", g.containerArgs("clusters", "describe", g.cluster,
		"--format=value(instanceGroupUrls)",
		"--project="+g.project,
		g.location)...).Output()
	if err != nil {
		return fmt.Errorf("instance group URL fetch failed: %s", util.ExecError(err))
	}
	igURLs := strings.Split(strings.TrimSpace(string(igs)), ";")
	if len(igURLs) == 0 {
		return fmt.Errorf("no instance group URLs returned by gcloud, output %q", string(igs))
	}
	sort.Strings(igURLs)
	for _, igURL := range igURLs {
		m := poolRe.FindStringSubmatch(igURL)
		if len(m) == 0 {
			return fmt.Errorf("instanceGroupUrl %q did not match regex %v", igURL, poolRe)
		}
		g.instanceGroups = append(g.instanceGroups, &ig{path: m[0], zone: m[1], name: m[2], uniq: m[3]})
	}
	return nil
}

func (g *gkeDeployer) getClusterFirewall() (string, error) {
	if err := g.getInstanceGroups(); err != nil {
		return "", err
	}
	// We want to ensure that there's an e2e-ports-* firewall rule
	// that maps to the cluster nodes, but the target tag for the
	// nodes can be slow to get. Use the hash from the lexically first
	// node pool instead.
	return "e2e-ports-" + g.instanceGroups[0].uniq, nil
}

// This function ensures that all firewall-rules are deleted from specific network.
// We also want to keep in logs that there were some resources leaking.
func (g *gkeDeployer) cleanupNetworkFirewalls() (int, error) {
	fws, err := exec.Command("gcloud", "compute", "firewall-rules", "list",
		"--format=value(name)",
		"--project="+g.project,
		"--filter=network:"+g.network).Output()
	if err != nil {
		return 0, fmt.Errorf("firewall rules list failed: %s", util.ExecError(err))
	}
	if len(fws) > 0 {
		fwList := strings.Split(strings.TrimSpace(string(fws)), "\n")
		log.Printf("Network %s has %v undeleted firewall rules %v", g.network, len(fwList), fwList)
		commandArgs := []string{"compute", "firewall-rules", "delete", "-q"}
		commandArgs = append(commandArgs, fwList...)
		commandArgs = append(commandArgs, "--project="+g.project)
		errFirewall := control.FinishRunning(exec.Command("gcloud", commandArgs...))
		if errFirewall != nil {
			return 0, fmt.Errorf("error deleting firewall: %v", errFirewall)
		}
		return len(fwList), nil
	}
	return 0, nil
}

func (g *gkeDeployer) Down() error {
	firewall, err := g.getClusterFirewall()
	if err != nil {
		// This is expected if the cluster doesn't exist.
		return nil
	}
	g.instanceGroups = nil

	// We best-effort try all of these and report errors as appropriate.
	errCluster := control.FinishRunning(exec.Command(
		"gcloud", g.containerArgs("clusters", "delete", "-q", g.cluster,
			"--project="+g.project,
			g.location)...))
	var errFirewall error
	if control.NoOutput(exec.Command("gcloud", "compute", "firewall-rules", "describe", firewall,
		"--project="+g.project,
		"--format=value(name)")) == nil {
		log.Printf("Found rules for firewall '%s', deleting them", firewall)
		errFirewall = control.FinishRunning(exec.Command("gcloud", "compute", "firewall-rules", "delete", "-q", firewall,
			"--project="+g.project))
	} else {
		log.Printf("Found no rules for firewall '%s', assuming resources are clean", firewall)
	}
	numLeakedFWRules, errCleanFirewalls := g.cleanupNetworkFirewalls()
	var errSubnet error
	if g.subnetwork != "" {
		errSubnet = control.FinishRunning(exec.Command("gcloud", "compute", "networks", "subnets", "delete", "-q", g.subnetwork,
			g.subnetworkRegion, "--project="+g.project))
	}
	errNetwork := control.FinishRunning(exec.Command("gcloud", "compute", "networks", "delete", "-q", g.network,
		"--project="+g.project))
	if errCluster != nil {
		return fmt.Errorf("error deleting cluster: %v", errCluster)
	}
	if errFirewall != nil {
		return fmt.Errorf("error deleting firewall: %v", errFirewall)
	}
	if errCleanFirewalls != nil {
		return fmt.Errorf("error cleaning-up firewalls: %v", errCleanFirewalls)
	}
	if errSubnet != nil {
		return fmt.Errorf("error deleting subnetwork: %v", errSubnet)
	}
	if errNetwork != nil {
		return fmt.Errorf("error deleting network: %v", errNetwork)
	}
	if numLeakedFWRules > 0 {
		return fmt.Errorf("leaked firewall rules")
	}
	return nil
}

func (g *gkeDeployer) containerArgs(args ...string) []string {
	return append(append(append([]string{}, g.commandGroup...), "container"), args...)
}

func (g *gkeDeployer) GetClusterCreated(gcpProject string) (time.Time, error) {
	res, err := control.Output(exec.Command(
		"gcloud",
		"compute",
		"instance-groups",
		"list",
		"--project="+gcpProject,
		"--format=json(name,creationTimestamp)"))
	if err != nil {
		return time.Time{}, fmt.Errorf("list instance-group failed : %v", err)
	}

	created, err := getLatestClusterUpTime(string(res))
	if err != nil {
		return time.Time{}, fmt.Errorf("parse time failed : got gcloud res %s, err %v", string(res), err)
	}
	return created, nil
}
