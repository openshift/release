FROM openshift/origin:latest

RUN yum -y install PyYAML

COPY ./src /opt/app/src

RUN chmod g+rwx -R /opt/app/src

ENTRYPOINT ["/bin/bash"]

CMD ["-c", "/opt/app/src/main/resources/redhat/openshift/generateConfigMaps.sh && /opt/app/src/main/resources/redhat/openshift/applyConfigMaps.sh"]
