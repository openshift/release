FROM centos

# Install required packages
RUN yum update -y; yum clean all
RUN yum-builddep -y python; yum -y install make gcc python-devel; yum clean all

ENV PYTHON_VERSION="3.7.0"
# Downloading and building python
RUN mkdir /tmp/python-build && cd /tmp/python-build && \
  curl https://www.python.org/ftp/python/$PYTHON_VERSION/Python-$PYTHON_VERSION.tgz > python.tgz && \
  tar xzf python.tgz && cd Python-$PYTHON_VERSION && \
  ./configure --prefix=/usr/local --enable-shared && make install && cd / && rm -rf /tmp/python-build

# Install locale
RUN localedef -v -c -i en_US -f UTF-8 en_US.UTF-8 || true
ENV LC_ALL "en_US.UTF-8"

ENV LD_LIBRARY_PATH "$LD_LIBRARY_PATH:/usr/local/lib"

RUN pip3 install pyyaml
RUN pip3 install pylint
