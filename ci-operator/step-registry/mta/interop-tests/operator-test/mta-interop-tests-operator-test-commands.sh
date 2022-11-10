#!/bin/sh

echo "${OPENSHIFT_CI}"
cat "${OPENSHIFT_CI}"

echo "${SHARED_DIR}"
cat "${SHARED_DIR}"	

echo "${ARTIFACT_DIR}"	
cat "${ARTIFACT_DIR}"	

echo "${CLUSTER_PROFILE_DIR}"
cat "${CLUSTER_PROFILE_DIR}"

echo "${KUBECONFIG}"	
cat "${KUBECONFIG}"	

echo "${KUBEADMIN_PASSWORD_FILE}"	
cat "${KUBEADMIN_PASSWORD_FILE}"	


echo "${RELEASE_IMAGE_INITIAL}"
cat "${RELEASE_IMAGE_INITIAL}"

echo "${RELEASE_IMAGE_LATEST}"	
cat "${RELEASE_IMAGE_LATEST}"	

echo "${LEASED_RESOURCE}"	
cat "${LEASED_RESOURCE}"	

echo "${IMAGE_FORMAT}"
cat "${IMAGE_FORMAT}"

# #Keeping for future use, where the script can be used to run test case by passing the -t flag directly
# : 'function argsHelp()
# {
#     echo -e "\n *** Usage help ***"
#     echo -e "\n $0 [-t path/to/testcase.py] \n"
#     exit 1
# }
# while getopts ":t:" flag
# do
#     case "$flag" in
#         t) testcase=${OPTARG} ;;
#         :) argsHelp ;;
#         \?) argsHelp ;;
#     esac
# done
# #Check if t param is missing
# if [ -z "$testcase" ]
# then
#     echo -e "\n ### Command line param -t missing. Please provide the test case to be executed ! ###"
#     argsHelp
# fi
# '
# #Build the mta docker image from dockerfile
# docker build -t mta:latest dockerfiles/docker_fedora31/

# #Run the mta container on port 8080 in detached mode
# if [[ $(docker ps | grep windup_mta) = *windup_mta* ]]
# then
#     echo -e "\n MTA web console container is already running !"
# else
#     if [[ $(docker ps -a | grep windup_mta) = *windup_mta* ]]
#     then
#         echo -e "\n Starting the existing MTA web console docker container !"
#         docker start windup_mta
#     else
#         echo -e "\n Starting new MTA web console container !"
#         docker run -d -p 8080:8080 --name windup_mta -it mta:latest
#     fi
# fi

# #Wait for mta web console to be fully up
# echo -e "\n Waiting for mta web console to be available ..."
# count=0
# threshold=3
# until $(curl --output /dev/null --silent --head --fail http://localhost:8080/mta-web); do
#     if [ ${count} == ${threshold} ]
#     then
#       echo -e "\n Could not reach web console after all tries, exiting ..."
#       exit 1
#     fi
#     echo ' \....\ '
#     count=$(($count+1))
#     sleep 10
# done

# echo -e "\n MTA web console is available now ! \n"

# #Setup python3 virtual environment
# echo -e "\n Activating python venv !"
# python3.7 -m venv .mta_venv
# source ./.mta_venv/bin/activate
# pip install -e .

# #Setup ftp
# echo -e "\n Setting up ftp host details ..."
# source mta/ftp_host_cred
# mta conf local-env --ftp-host $ftp_host --ftp-username $ftp_user --ftp-password $ftp_password

# #Start selenium container and vnc viewer
# echo -e "\n Starting selenium container and VNC Viewer ..."
# mta selenium start -w