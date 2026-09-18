// CloudForge Platform — CI pipeline (Jenkins declarative).
//
// Flow: checkout -> unit tests (parallel) -> SonarQube + quality gate -> OWASP Dependency-Check
//       -> Trivy fs/IaC scan -> docker build (parallel) -> Trivy image scan + SBOM -> push
//       -> helm lint/render -> bump image tags in gitops/environments/<env> -> git push
//       -> Argo CD detects the commit and syncs (canary backend / blue-green frontend).
//
// Jenkins requirements (provisioned by infra-ansible role 'jenkins' / jenkins/casc/jenkins.yaml):
//   plugins: workflow-aggregator, docker-workflow, git, credentials-binding, sonar,
//            dependency-check-jenkins-plugin, junit, coverage, timestamper, ws-cleanup, pipeline-utility-steps
//   agent:   Docker CLI + access to a Docker daemon. With Docker-outside-of-Docker the Jenkins
//            home must be bind-mounted at the SAME path on the host (see jenkins/docker-compose.yml),
//            otherwise `docker run -v $PWD:...` from a stage mounts an empty host directory.
//   SonarQube: add a webhook to http://jenkins:8080/sonarqube-webhook/ for waitForQualityGate.
//   credentials:
//     github-push        (username/token)  push GitOps commits
//     sonarqube-token    (secret text)     used via SonarQube server config 'sonarqube'
//     nvd-api-key        (secret text)     OWASP Dependency-Check NVD API key
//     aws-ci             (AWS creds)       ECR push when TARGET_ENV=eks (or use instance role)

def IMAGES = [
  [name: 'api',          context: 'app-backend',  chart: 'backend'],
  [name: 'web',          context: 'app-frontend', chart: 'frontend'],
  [name: 'apache-proxy', context: 'apache-proxy', chart: 'apache-proxy'],
]

pipeline {
  agent any

  parameters {
    choice(name: 'TARGET_ENV', choices: ['local', 'eks'], description: 'GitOps environment to promote to')
    booleanParam(name: 'SKIP_OWASP', defaultValue: false, description: 'Skip OWASP Dependency-Check (slow on first run: NVD download)')
    booleanParam(name: 'PROMOTE', defaultValue: true, description: 'Commit new image tags to gitops/ (main branch only)')
  }

  options {
    timestamps()
    ansiColor('xterm')
    timeout(time: 60, unit: 'MINUTES')
    buildDiscarder(logRotator(numToKeepStr: '30', artifactNumToKeepStr: '10'))
    disableConcurrentBuilds(abortPrevious: true)
    skipDefaultCheckout(true)
  }

  environment {
    DOCKER_BUILDKIT = '1'
    // kind local registry (scripts/kind-with-registry.sh) or ECR
    LOCAL_REGISTRY  = 'localhost:5001'
    AWS_REGION      = 'us-east-1'
    AWS_ACCOUNT_ID  = '123456789012'
    ECR_REGISTRY    = "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
    TRIVY_IMAGE     = 'aquasec/trivy:0.66.0'
    HELM_IMAGE      = 'alpine/helm:3.19.0'
    YQ_IMAGE        = 'mikefarah/yq:4.47.2'
    TRIVY_CACHE     = "${WORKSPACE}/.cache/trivy"
  }

  stages {
    stage('Checkout') {
      steps {
        cleanWs()
        checkout scm
        script {
          env.GIT_SHA   = sh(returnStdout: true, script: 'git rev-parse --short=12 HEAD').trim()
          env.VERSION   = "${env.GIT_SHA}-${env.BUILD_NUMBER}"
          env.REGISTRY  = params.TARGET_ENV == 'eks' ? env.ECR_REGISTRY : env.LOCAL_REGISTRY
          env.IS_MAIN   = (env.BRANCH_NAME ?: 'main') == 'main' ? 'true' : 'false'
          // Skip the pipeline for the bot's own GitOps commits.
          def msg = sh(returnStdout: true, script: 'git log -1 --pretty=%B').trim()
          if (msg.contains('[skip ci]')) {
            currentBuild.result = 'NOT_BUILT'
            error('GitOps bump commit — nothing to build')
          }
          currentBuild.displayName = "#${env.BUILD_NUMBER} ${env.GIT_SHA} -> ${params.TARGET_ENV}"
        }
      }
    }

    stage('Unit tests') {
      parallel {
        stage('Backend') {
          agent {
            docker { image 'python:3.13-slim'; reuseNode true }
          }
          environment { HOME = "${WORKSPACE}/.cache/home" }
          steps {
            dir('app-backend') {
              sh '''
                python -m venv "$HOME/venv" && . "$HOME/venv/bin/activate"
                pip install -q --no-cache-dir -r requirements-dev.txt
                ruff check app tests
                ruff format --check app tests || true
                pytest
              '''
            }
          }
          post {
            always {
              junit allowEmptyResults: true, testResults: 'app-backend/test-results.xml'
              recordCoverage(tools: [[parser: 'COBERTURA', pattern: 'app-backend/coverage.xml']],
                             sourceCodeRetention: 'NEVER')
            }
          }
        }
        stage('Frontend') {
          agent {
            docker { image 'node:24-alpine'; reuseNode true }
          }
          environment {
            HOME = "${WORKSPACE}/.cache/home"
            npm_config_cache = "${WORKSPACE}/.cache/npm"
          }
          steps {
            dir('app-frontend') {
              sh '''
                npm ci --no-audit --no-fund
                npm run lint
                npm test
                npm run build
              '''
            }
          }
        }
      }
    }

    stage('SonarQube') {
      steps {
        script {
          def scanner = 'sonarsource/sonar-scanner-cli:11'
          withSonarQubeEnv('sonarqube') {
            ['app-backend', 'app-frontend'].each { mod ->
              sh """
                docker run --rm --network cloudforge-ci_default \
                  -e SONAR_HOST_URL="\$SONAR_HOST_URL" -e SONAR_TOKEN="\$SONAR_AUTH_TOKEN" \
                  -v "\$PWD/${mod}:/usr/src" -w /usr/src ${scanner} \
                  -Dsonar.projectVersion=${env.VERSION} \
                  -Dsonar.scm.revision=${env.GIT_SHA}
              """
            }
          }
        }
      }
    }

    stage('Quality gate') {
      steps {
        timeout(time: 10, unit: 'MINUTES') {
          waitForQualityGate abortPipeline: true
        }
      }
    }

    stage('Security scans') {
      parallel {
        stage('OWASP Dependency-Check') {
          when { expression { !params.SKIP_OWASP } }
          steps {
            withCredentials([string(credentialsId: 'nvd-api-key', variable: 'NVD_API_KEY')]) {
              sh '''
                mkdir -p reports .cache/odc
                docker run --rm -u "$(id -u):$(id -g)" \
                  -v "$PWD:/src:ro" -v "$PWD/reports:/report" -v "$PWD/.cache/odc:/usr/share/dependency-check/data" \
                  owasp/dependency-check:12.1.6 \
                  --scan /src/app-backend --scan /src/app-frontend/package-lock.json \
                  --project cloudforge --format HTML --format XML --format JSON \
                  --nvdApiKey "$NVD_API_KEY" \
                  --suppression /src/security/dependency-check-suppressions.xml \
                  --failOnCVSS 9 --out /report
              '''
            }
          }
          post {
            always {
              dependencyCheckPublisher pattern: 'reports/dependency-check-report.xml'
            }
          }
        }
        stage('Trivy filesystem + IaC') {
          steps {
            sh '''
              mkdir -p reports "$TRIVY_CACHE"
              # Vulnerable dependencies + leaked secrets in the source tree
              docker run --rm -v "$PWD:/src:ro" -v "$TRIVY_CACHE:/root/.cache/trivy" $TRIVY_IMAGE \
                fs --scanners vuln,secret --severity HIGH,CRITICAL --ignore-unfixed \
                --exit-code 1 --ignorefile /src/security/.trivyignore /src
              # Misconfigurations in Terraform, Helm charts, Dockerfiles, Kubernetes YAML
              docker run --rm -v "$PWD:/src:ro" -v "$TRIVY_CACHE:/root/.cache/trivy" $TRIVY_IMAGE \
                config --severity HIGH,CRITICAL --exit-code 1 \
                --config /src/security/trivy.yaml /src
            '''
          }
        }
      }
    }

    stage('Build images') {
      steps {
        script {
          def builds = [:]
          IMAGES.each { img ->
            builds[img.name] = {
              sh """
                docker build \
                  --pull \
                  --build-arg APP_VERSION=${env.VERSION} \
                  --label org.opencontainers.image.revision=${env.GIT_SHA} \
                  --label org.opencontainers.image.created=\$(date -u +%Y-%m-%dT%H:%M:%SZ) \
                  -t ${env.REGISTRY}/cloudforge/${img.name}:${env.VERSION} \
                  ${img.context}
              """
            }
          }
          parallel builds
        }
      }
    }

    stage('Image scan + SBOM') {
      steps {
        script {
          IMAGES.each { img ->
            def ref = "${env.REGISTRY}/cloudforge/${img.name}:${env.VERSION}"
            sh """
              docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
                -v "\$TRIVY_CACHE:/root/.cache/trivy" -v "\$PWD/reports:/reports" ${env.TRIVY_IMAGE} \
                image --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 \
                --format table ${ref}
              docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
                -v "\$TRIVY_CACHE:/root/.cache/trivy" -v "\$PWD/reports:/reports" ${env.TRIVY_IMAGE} \
                image --format cyclonedx --output /reports/sbom-${img.name}.cdx.json ${ref}
            """
          }
        }
      }
      post {
        always { archiveArtifacts artifacts: 'reports/**', allowEmptyArchive: true }
      }
    }

    stage('Push images') {
      when { expression { env.IS_MAIN == 'true' } }
      steps {
        script {
          if (params.TARGET_ENV == 'eks') {
            withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', credentialsId: 'aws-ci']]) {
              sh 'aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$ECR_REGISTRY"'
            }
          }
          IMAGES.each { img ->
            sh "docker push ${env.REGISTRY}/cloudforge/${img.name}:${env.VERSION}"
          }
        }
      }
    }

    stage('Helm lint + render') {
      steps {
        sh '''
          for c in platform postgres redis backend apache-proxy frontend; do
            docker run --rm -v "$PWD:/w" -w /w $HELM_IMAGE lint helm-charts/charts/$c \
              -f gitops/environments/$TARGET_ENV/$c.yaml
          done
          docker run --rm -v "$PWD:/w" -w /w --entrypoint sh $HELM_IMAGE -c \
            "apk add --no-cache bash >/dev/null && HELM=helm bash scripts/render-manifests.sh"
          docker run --rm -v "$PWD:/w" ghcr.io/yannh/kubeconform:v0.7.0 \
            -strict -summary -ignore-missing-schemas \
            -schema-location default \
            -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
            /w/k8s-manifests/rendered/$TARGET_ENV
        '''
      }
    }

    stage('Promote via GitOps') {
      when {
        allOf {
          expression { env.IS_MAIN == 'true' }
          expression { params.PROMOTE }
        }
      }
      steps {
        script {
          IMAGES.each { img ->
            sh """
              docker run --rm -u "\$(id -u):\$(id -g)" -v "\$PWD:/w" -w /w ${env.YQ_IMAGE} -i \
                '.image.tag = "${env.VERSION}" | .image.repository = "${env.REGISTRY}/cloudforge/${img.name}"' \
                gitops/environments/${params.TARGET_ENV}/${img.chart}.yaml
            """
          }
        }
        withCredentials([usernamePassword(credentialsId: 'github-push', usernameVariable: 'GIT_USER', passwordVariable: 'GIT_TOKEN')]) {
          sh '''
            git config user.name  "cloudforge-ci"
            git config user.email "ci@cloudforge.dev"
            git add gitops/environments/$TARGET_ENV k8s-manifests/rendered/$TARGET_ENV
            if git diff --cached --quiet; then echo "nothing to promote"; exit 0; fi
            git commit -m "chore(gitops): promote $VERSION to $TARGET_ENV [skip ci]"
            REMOTE=$(git config --get remote.origin.url | sed -E "s#https://#https://${GIT_USER}:${GIT_TOKEN}@#")
            git push "$REMOTE" HEAD:main
          '''
        }
      }
    }
  }

  post {
    success {
      echo "Promoted ${env.VERSION} to ${params.TARGET_ENV}. Argo CD will sync; watch: kubectl argo rollouts get rollout backend-api -n backend -w"
    }
    failure {
      echo 'Pipeline failed — see stage logs and archived reports/.'
    }
    always {
      sh 'docker image prune -f --filter "until=24h" || true'
    }
  }
}
