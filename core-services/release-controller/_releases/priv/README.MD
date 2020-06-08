These files contain release controller configurations for the private release controller instances (i.e. those
monitoring ocp-priv, ocp-s390x-priv, ...). All prowjobs triggered as part of verification MUST have the
"hidden: true" ProwJob attribute set. Without the attribute, the test results will be visible within the public
deck instance.