@Library('idp-lib') _

pipeline {
  agent {
    kubernetes {
      yaml '''
apiVersion: v1
kind: Pod
spec:
  serviceAccountName: jenkins-agent
  containers:
    - name: jnlp
      image: jenkins/inbound-agent:latest
      resources:
        requests: { memory: 256Mi, cpu: 200m }
      envFrom:
        - secretRef: { name: harness-idp-secrets }
    - name: docker
      image: docker:24-cli
      command: [cat]
      tty: true
      envFrom:
        - secretRef: { name: harness-idp-secrets }
      volumeMounts:
        - { name: dockersock, mountPath: /var/run/docker.sock }
    - name: trivy
      image: aquasec/trivy:0.60.0
      command: [cat]
      tty: true
      envFrom:
        - secretRef: { name: harness-idp-secrets }
    - name: kubectl
      image: alpine/k8s:1.29.2
      command: [cat]
      tty: true
      envFrom:
        - secretRef: { name: harness-idp-secrets }
    - name: maven
      image: maven:3.9-eclipse-temurin-17
      command: [cat]
      tty: true
      envFrom:
        - secretRef: { name: harness-idp-secrets }
  volumes:
    - name: dockersock
      hostPath: { path: /var/run/docker.sock }
'''
    }
  }

  options {
    timeout(time: 30, unit: 'MINUTES')
    buildDiscarder(logRotator(numToKeepStr: '20'))
  }

  environment {
    BUILD_ID_STR      = "jenkins-petclinic-${env.BUILD_NUMBER}"
    DEPLOY_ID         = "deploy-petclinic-${env.BUILD_NUMBER}"
    SECURITY_ID_BASE  = "trivy-petclinic-${env.BUILD_NUMBER}"
    IMAGE_REPO        = 'ghcr.io/deepakbhatt329/petclinic'
    IMAGE_TAG         = "${env.BUILD_NUMBER}"
    IMAGE             = "${IMAGE_REPO}:${IMAGE_TAG}"
    K8S_NAMESPACE     = 'custom-integrartion-ipd-demo'
  }

  stages {
    stage('Checkout') {
      steps {
        checkout scm
        script {
          env.ISO_TS   = sh(script: "date -u +%Y-%m-%dT%H:%M:%SZ", returnStdout: true).trim()
          env.GIT_SHA  = sh(script: "git rev-parse HEAD", returnStdout: true).trim()
          env.REPO_URL = sh(script: "git config --get remote.origin.url", returnStdout: true).trim()
        }
      }
    }

    stage('Upsert build: RUNNING') {
      steps {
        upsert('build', [
          name         : "petclinic #${env.BUILD_NUMBER}",
          status       : 'RUNNING',
          branch       : (env.BRANCH_NAME ?: 'main'),
          sha          : env.GIT_SHA,
          repositoryUrl: env.REPO_URL,
          buildNumber  : env.BUILD_NUMBER.toInteger(),
          triggeredBy  : (env.BUILD_USER ?: 'scm'),
          url          : env.BUILD_URL
        ])
      }
    }

    stage('Build JAR') {
      steps {
        catchError(buildResult: 'FAILURE', stageResult: 'FAILURE', message: 'BUILD_STAGE_FAILED') {
          container('maven') {
            sh './mvnw -B -DskipTests package'
          }
        }
      }
    }

    stage('Build & push image') {
      when { expression { currentBuild.currentResult == 'SUCCESS' } }
      steps {
        catchError(buildResult: 'FAILURE', stageResult: 'FAILURE', message: 'BUILD_STAGE_FAILED') {
          container('docker') {
            withCredentials([usernamePassword(credentialsId: 'ghcr', usernameVariable: 'U', passwordVariable: 'P')]) {
              sh 'echo "$P" | docker login ghcr.io -u "$U" --password-stdin'
              sh 'docker build -t $IMAGE -f Dockerfile .'
              sh 'docker push $IMAGE'
            }
          }
        }
      }
    }

    stage('Trivy scan') {
      when { expression { currentBuild.currentResult == 'SUCCESS' } }
      steps {
        container('trivy') {
          sh '''
            JAR=$(ls target/spring-petclinic-*.jar | head -n1)
            trivy fs --format json --output trivy.json \
              --severity CRITICAL,HIGH,MEDIUM \
              --scanners vuln \
              --skip-dirs .git \
              "$JAR"
          '''
        }
      }
    }

    stage('Upsert build: SUCCESS + security_issues') {
      when { expression { currentBuild.currentResult == 'SUCCESS' } }
      steps {
        upsert('build', [
          name         : "petclinic #${env.BUILD_NUMBER}",
          status       : 'SUCCESS',
          branch       : (env.BRANCH_NAME ?: 'main'),
          sha          : env.GIT_SHA,
          repositoryUrl: env.REPO_URL,
          durationInSec: (currentBuild.duration / 1000) as int,
          artifact     : [env.IMAGE],
          url          : env.BUILD_URL,
          buildNumber  : env.BUILD_NUMBER.toInteger(),
          triggeredBy  : (env.BUILD_USER ?: 'scm')
        ])
        upsertTrivyFindings('trivy.json', env.SECURITY_ID_BASE)
      }
    }

    stage('Upsert deployment: RUNNING') {
      when { expression { currentBuild.currentResult == 'SUCCESS' } }
      steps {
        upsert('deployment', [
          name       : "petclinic deploy #${env.BUILD_NUMBER}",
          status     : 'RUNNING',
          environment: 'dev',
          artifact   : env.IMAGE,
          service    : 'petclinic'
        ])
      }
    }

    stage('kubectl apply + rollout status') {
      when { expression { currentBuild.currentResult == 'SUCCESS' } }
      steps {
        catchError(buildResult: 'UNSTABLE', stageResult: 'FAILURE', message: 'DEPLOY_STAGE_FAILED') {
          container('kubectl') {
            sh '''
              sed "s|IMAGE_PLACEHOLDER|${IMAGE}|g" k8s/deploy.yaml \
                | kubectl -n "${K8S_NAMESPACE}" apply -f -
              kubectl -n "${K8S_NAMESPACE}" rollout status deploy/petclinic-demo --timeout=180s
            '''
          }
        }
      }
    }

    stage('Upsert deployment: outcome') {
      when { expression { currentBuild.currentResult in ['SUCCESS', 'UNSTABLE'] } }
      steps {
        script {
          def deployOk = currentBuild.currentResult == 'SUCCESS'
          upsert('deployment', [
            name         : "petclinic deploy #${env.BUILD_NUMBER}",
            status       : deployOk ? 'SUCCESS' : 'FAILED',
            environment  : 'dev',
            artifact     : env.IMAGE,
            service      : 'petclinic',
            durationInSec: (currentBuild.duration / 1000) as int,
            url          : "http://petclinic-demo.${env.K8S_NAMESPACE}.svc:8080"
          ])
        }
      }
    }
  }

  post {
    failure {
      script {
        upsert('build', [
          name         : "petclinic #${env.BUILD_NUMBER}",
          status       : 'FAILED',
          branch       : (env.BRANCH_NAME ?: 'main'),
          sha          : env.GIT_SHA,
          repositoryUrl: env.REPO_URL,
          buildNumber  : env.BUILD_NUMBER.toInteger(),
          triggeredBy  : (env.BUILD_USER ?: 'scm'),
          url          : env.BUILD_URL
        ])
      }
    }
  }
}
