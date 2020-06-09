#!/usr/bin/env bash
set -e -u -o pipefail

declare -r SCRIPT_DIR=$(cd -P $(dirname $0) && pwd)

declare -r NAMESPACE=${NAMESPACE:-release-tests-ci}

_log() {
    local level=$1; shift
    echo -e "$level: $@"
}

log.err() {
    _log "ERROR" "$@" >&2
}

info() {
    _log "\nINFO" "$@"
}

err() {
    local code=$1; shift
    local msg="$@"; shift
    log.err $msg
    exit $code
}

valid_command() {
  local fn=$1; shift
  [[ $(type -t "$fn") == "function" ]]
}

# helpers to avoid adding -n $NAMESPACE to oc and tkn
OC() {
  echo oc -n "$NAMESPACE" "$@"
  oc -n "$NAMESPACE" "$@"
}

TKN() {
 echo tkn -n "$NAMESPACE" "$@"
 tkn -n "$NAMESPACE" "$@"
}

demo.validate_tools() {
  info "validating tools"

  tkn version >/dev/null 2>&1 || err 1 "no tkn binary found"
  oc version --client >/dev/null 2>&1 || err 1 "no oc binary found"
  return 0
}

bootstrap() {
    demo.validate_tools

    info "ensure namespace $NAMESPACE exists"
    OC get ns "$NAMESPACE" 2>/dev/null  || {
      OC new-project $NAMESPACE
    }
  }

demo.setup-pipeline() {
  local run_bootstrap=${1:-"run"}
  [[ "$run_bootstrap" == "skip-bootstrap" ]] || bootstrap

  info "Applying pipeline tasks"
  OC apply -f tasks/


  info "Applying resources"
  OC apply -f resources/

  info "Applying pipeline"
  OC apply -f pipeline/release-tests-pipeline.yaml

  echo -e "\nPipeline"
  echo "==============="
  TKN p desc release-tests

}

demo.setup() {
  bootstrap
  demo.setup-pipeline skip-bootstrap
}

demo.logs() {
  TKN pipeline logs release-tests --last -f

  info "Validating the result of pipeline run"
  demo.validate_pipelinerun
}

demo.run() {
  info "Running API Build and deploy"
  OC apply -f pipelinerun/release-tests-pipelinerun.yaml
}

demo.validate_pipelinerun() {
  local failed=0
  local results=( $(oc get pipelinerun.tekton.dev -n "$NAMESPACE" --template='
    {{range .items -}}
      {{ $pr := .metadata.name -}}
      {{ $c := index .status.conditions 0 -}}
      {{ $pr }}={{ $c.type }}{{ $c.status }}
    {{ end }}
    ') )

  for result in ${results[@]}; do
    if [[ ! "${result,,}" == *"=succeededtrue" ]]; then
      echo "ERROR: test $result but should be SucceededTrue"
      failed=1
    fi
  done

  return "$failed"
}


demo.help() {
# NOTE: must insert leading TABS and not SPACE to align
  cat <<-EOF
		USAGE:
		  demo [command]

		COMMANDS:
		  setup             runs both pipeline and trigger setup
		  setup-pipeline    sets up project, tasks, pipeline and resources
		  run               starts pipeline
		  logs              Get pipelinerun logs in -f mode
EOF
}

main() {
  local fn="demo.${1:-help}"
  valid_command "$fn" || {
    demo.help
    err  1 "invalid command '$1'"
  }

  cd "$SCRIPT_DIR"
  $fn "$@"
  return $?
}

main "$@"