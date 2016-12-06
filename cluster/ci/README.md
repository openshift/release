Deploy the OpenShift CI instance to GCE

    $ ./up.sh

Will download the appropriate version of OpenShift and install it to
GCE. You must populate the data directory with the appropriate secret
data first (instructions pending).

To get a shell into the container with the right data, run:

    $ $(./run.sh)
