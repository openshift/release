#!/usr/bin/env groovy
@Library("release-library@master")
import static com.redhat.openshift.CleanupUtilities.PruneResources

pipeline {
  agent any

  stages {
    stage("Pruning Persistent Resources") {
      steps {
        script {
          PruneResources(this)
        }
      }
    }
  }
}