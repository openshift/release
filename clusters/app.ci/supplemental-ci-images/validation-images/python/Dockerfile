FROM centos:7

RUN yum update -y;yum install -y python3 python-pip; yum clean all
RUN curl -o get-pip.py https://bootstrap.pypa.io/pip/3.6/get-pip.py
RUN python3 get-pip.py
RUN pip install pyyaml
RUN pip install ruamel.yaml
RUN pip install pylint
