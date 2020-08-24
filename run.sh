#!/bin/bash

set -eou pipefail

OBS_NS="observatorium"
OBS_LOKI_QF="observatorium-xyz-loki-query-frontend"
OBS_LOKI_QR="observatorium-xyz-loki-querier"
OBS_LOKI_DST="observatorium-xyz-loki-distributor"
OBS_LOKI_ING="observatorium-xyz-loki-ingester"

trap 'undeploy_observatorium;kill $(jobs -p); exit 0' EXIT

deploy_observatorium() {
    pushd ../deployments || exit 1
    ./tests/e2e.sh kind
    ./tests/e2e.sh deploy
    popd
}

undeploy_observatorium() {
    pushd ../deployments || exit 1
    echo -e "\nUndeploying observatorium dev manifests"
    ./kind delete cluster
    popd
}

forward_ports() {
    pushd ../deployments/ || exit 1

    echo -e "\nWaiting for available loki query frontend deployment"
    ./kubectl -n "$OBS_NS" wait --for=condition=Available "deploy/$OBS_LOKI_QF" --timeout=120s

    echo -e "\nSetup port-forward '3100:3100' to loki query frontend"
    (
        ./kubectl -n "$OBS_NS" port-forward "svc/$OBS_LOKI_QF-http" 3100:3100;
    ) &

    echo -e "\nWaiting for available loki distributor deployment"
    ./kubectl -n "$OBS_NS" wait --for=condition=Available "deploy/$OBS_LOKI_DST" --timeout=120s

    echo -e "\nSetup port-forward '3101:3100' to loki distributor frontend"
    (
        ./kubectl -n "$OBS_NS" port-forward "svc/$OBS_LOKI_DST-http" 3101:3100;
    ) &

    echo -e "\nWaiting for available loki ingester deployment"
    ./kubectl -n "$OBS_NS" wait --for=condition=Available "deploy/$OBS_LOKI_ING" --timeout=120s

    echo -e "\nSetup port-forward '3102:3100' to loki ingester frontend"
    (
        ./kubectl -n "$OBS_NS" port-forward "svc/$OBS_LOKI_ING-http" 3102:3100;
    ) &

    echo -e "\nWaiting for available querier deployment"
    ./kubectl -n "$OBS_NS" wait --for=condition=Available "deploy/$OBS_LOKI_ING" --timeout=120s

    echo -e "\nSetup port-forward '3103:3100' to loki ingester frontend"
    (
        ./kubectl -n "$OBS_NS" port-forward "svc/$OBS_LOKI_QR-http" 3103:3100;
    ) &

    popd
}

scrape_loki_metrics() {
    source .bingo/variables.env
    (
        $PROMETHEUS --log.level=warn --config.file=./config/prometheus/config.yaml --storage.tsdb.path="$(mktemp -d)";
    ) &
}

generate_report() {
    source .bingo/variables.env

    for f in $REPORT_DIR/*.gnuplot; do
        gnuplot -e "set term png; set output '$f.png'" "$f"
    done

    cp ./reports/README.template $REPORT_DIR/README.md
    sed -i "s/{{TARGET_ENV}}/$TARGET_ENV/i" $REPORT_DIR/README.md
    $EMBEDMD -w $REPORT_DIR/README.md
}


bench() {
    echo "Deploying observatorium dev manifests"
    deploy_observatorium

    echo -e "\nFoward ports to loki deployments"
    forward_ports

    echo -e "\n Scrape metrics from Loki deployments"
    scrape_loki_metrics

    source .bingo/variables.env

    echo -e "\nRun benchmarks"
    $GINKGO ./benchmarks

    echo -e "\nGenerate benchmark report"
    generate_report
}

bench

exit $?
