###############################################
## Auth=lhorsley@redhat.com, ematysek@redhat.com
## Description: Cluster resilience testing via creation and deletion of a large number of projects (in parallel) on a cluster (OVN or SDN)
## Polarion test case: OCP-41643 - Load cluster to test bad actor resilience	
## https://polarion.engineering.redhat.com/polarion/#/project/OSE/workitem?id=OCP-41643
## Bug related: https://issues.redhat.com/browse/OCPBUGS-12266
## Cluster config: 3 master (m5.4xlarge or equivalent) with 40 workers (vm_type_workers: m5.2xlarge or equivalent).
## The machine running the test should have at least 4 cores.
##
## Note: While the test runs, check the functionality of the cluster. A simple example (found in the Polarion test case):
##       while true; do oc get co --no-headers| grep -v 'True.*False.*False'; oc get nodes --no-headers| grep -v ' Ready'; date; sleep 10; done
################################################ 

base_namespace=${1:-baa}
num_projects=${2:-1000}
num_parallel_processes=${3:-10}
sleep_mins=${4:-5}
create_string="Create"
delete_string="Delete"
test_object_type="namespaces"
create_cycle_threshold=600
delete_cycle_thresshold=1800



# simple function to display the status of operators and nodes
function get_operator_and_node_status() {
  echo "Node and operator status"
  oc get nodes
  echo ""
  oc get co
  echo ""
}

# pass $string $my_namespace $my_projects $my_parallel_processes
# e.g. parallel_project_actions $create_string $my_namespace $my_projects $my_parallel_processes
function parallel_project_actions() {
  my_action=$1
  my_namespace=$2
  my_projects=$3
  my_paralllel_processes=$4
  my_num_jobs="\j"  # The prompt escape for number of jobs currently running

  if [ "$my_action" == "Create" ]; then
    my_command='oc new-project --skip-config-write "${my_namespace}${i}" > /dev/null && echo "Created project ${my_namespace}${i}" &>> op.log &'
  else
    my_command='oc delete project "${my_namespace}${i}" >> op.log &'
  fi

  cycle_start_time=`date +%s`

  for ((i=0; i<$my_projects; i++)); do
   	while (( ${my_num_jobs@P} >= $my_paralllel_processes )); do
  			 wait -n
	  done
    eval $my_command
  done

  cycle_end_time=`date +%s` 
  total_cycle_time=$((cycle_end_time - cycle_start_time))

  echo $total_cycle_time
}

# copied from perscale_regression_ci/common.sh
# pass $name_identifier $object_type
# e.g wait_for_obj_creation $my_namespace $my_object_type
function wait_for_obj_creation() {
  my_name_identifier=$1
  my_object_type=$2
  my_num_obj=$3

  COUNTER=0

  creating_obj=$(oc get $my_object_type -A | grep $my_name_identifier | grep  "Active" | wc -l)
  while [[ $creating_obj -ne $my_num_obj ]]; do
    sleep 5
    creating_obj=$(oc get $my_object_type -A | grep $my_name_identifier | grep  "Active" | wc -l)
    echo "$creating_obj $my_object_type created"
    COUNTER=$((COUNTER + 1))
    if [ $COUNTER -ge 60 ]; then
      echo "$creating_obj $my_object_type created after 5 minutes"
      exit 1
    fi
  done

  echo "All $my_num_obj $my_object_type have been created"
}

# copied from perscale_regression_ci/common.sh
# pass $name_identifier $object_type
# e.g wait_for_termination $my_namespace $my_object_type
function wait_for_termination() {
  my_name_identifier=$1
  my_object_type=$2

  COUNTER=0
  existing_obj=$(oc get $my_object_type -A| grep $my_name_identifier | wc -l)
  while [ $existing_obj -ne 0 ]; do
    sleep 5
    existing_obj=$(oc get $my_object_type -A | grep $my_name_identifier | wc -l | xargs )
    echo "Waiting for $my_object_type to be deleted: $existing_obj still exist"
    COUNTER=$((COUNTER + 1))
    if [ $COUNTER -ge 60 ]; then
      echo "$existing_obj $my_object_type are still not deleted after 5 minutes"
      exit 1
    fi
  done
  echo "All $my_object_type are deleted"
}


echo "Starting run basename: $base_namespace"
echo "number of projects: $num_projects"
echo "Parallel processes: $num_parallel_processes"
echo "Sleep time between create cycle and delete cycle: $sleep_mins"
echo ""

# Start the log file
echo "Writing subprocess logs to ./op.log"
if [ -e op.log ]; then
	echo "op.og exists, subprocess logs will be appended"
fi
echo "$(date) - New Run" >> op.log
echo ""

# Start the timer
echo "======= $(date) - Test start time ======="
start_time=`date +%s`
echo ""

# Create the projects in parallel
echo "$(date) - Create cycle start time"
total_create_cycle_time=$(parallel_project_actions $create_string $base_namespace $num_projects $num_parallel_processes)

# Wait for all projects to be created (the test will exit if the process lasts longer than five minutes)
wait_for_obj_creation $base_namespace $test_object_type $num_projects
echo "$(date) - Create cycle end time"
echo ""

# Display the node and operator status
get_operator_and_node_status

# Wait for  $sleep_mins minues
echo "Sleeping $sleep_mins mins..."
sleep "${sleep_mins}m"
echo ""

# Display the node and operator status
get_operator_and_node_status


# Delete the projects in parallel
echo "$(date) - Delete cycle start time"
total_delete_cycle_time=$(parallel_project_actions $delete_string $base_namespace $num_projects $num_parallel_processes)

# Wait for all projects to be deleted (the test will exit if the process lasts longer than five minutes)
wait_for_termination $base_namespace $test_object_type
echo "$(date) - Delete cycle end time"
echo ""

# Stop the timer and calculate the test time
echo "======= $(date) - Test end time =======" 
end_time=`date +%s`
echo ""

# Display the node and operator status
get_operator_and_node_status

# Check for operators and nodes in a bad state
bad_operators=$(oc get co --no-headers| grep -v 'True.*False.*False' | wc -l)
nodes_not_ready=$(oc get nodes --no-headers | grep -v Ready | wc -l)

echo ""
echo "======Final test result======"
final_time=$((end_time - start_time))
echo "execution time for test $final_time s."
echo "Total time for create cycle: $total_create_cycle_time s."
echo "Total time for delete cycle: $total_delete_cycle_time s."
echo ""

if [[ ( $bad_operators -eq 0 ) && ( $nodes_not_ready -eq 0 )  && ( $total_create_cycle_time -le $create_cycle_threshold ) && ( $total_delete_cycle_time -le $delete_cycle_thresshold )]]; then
  echo -e "\nBad Actor Testcase result:  PASS"
  echo "Expected: Cluster operators are stable."
  echo "Expected: All nodes are Ready."
  echo "Expected: $num_projects projects created in $create_cycle_threshold seconds (or less): $total_create_cycle_time s."
  echo "Expected: $num_projects projects deleted in $delete_cycle_thresshold seconds (or less): $total_delete_cycle_time s."
  exit 0
else
  echo -e "\nBad Actor Testcase result:  FAIL"
  echo "Operators (oc get co --no-headers| grep -v 'True.*False.*False'):"
  oc get co --no-headers| grep -v 'True.*False.*False'
  echo ""
  echo "Nodes oc get nodes --no-headers | grep -v Ready):"
  oc get nodes --no-headers | grep -v Ready
  echo ""
  echo "Actual creation time for $num_projects projects (expected time $create_cycle_threshold seconds (or less): $total_create_cycle_time s."
  echo "Actual celetion time for $num_projects projects (expected time $delete_cycle_thresshold seconds (or less): $total_delete_cycle_time s."
  exit 1
fi 
parallel_project_actions mynamespace 1 2 3
