#!/usr/bin/env python3
"""Generate the CloudForge Grafana dashboards as JSON (dashboards-as-code).

Output: helm-charts/charts/platform/files/dashboards/*.json
  - The platform Helm chart ships them as ConfigMaps (grafana sidecar label grafana_dashboard=1).
  - docker compose mounts the same folder into Grafana.

Run: python monitoring/grafana/generate_dashboards.py
"""

import json
from pathlib import Path

OUT = Path(__file__).resolve().parents[2] / "helm-charts/charts/platform/files/dashboards"
DS = {"type": "prometheus", "uid": "${datasource}"}
LOKI = {"type": "loki", "uid": "${loki}"}


class Board:
    def __init__(self, uid, title, tags, variables=()):
        self.uid, self.title, self.tags = uid, title, tags
        self.panels, self.y, self.next_id = [], 0, 1
        self.variables = [
            {
                "name": "datasource",
                "label": "Prometheus",
                "type": "datasource",
                "query": "prometheus",
                "current": {},
                "hide": 0,
            },
            *variables,
        ]

    def _id(self):
        self.next_id += 1
        return self.next_id - 1

    def row(self, title):
        self.panels.append(
            {"id": self._id(), "type": "row", "title": title, "collapsed": False,
             "gridPos": {"h": 1, "w": 24, "x": 0, "y": self.y}, "panels": []}
        )
        self.y += 1

    def stats(self, items, h=4):
        """items: (title, expr, unit, thresholds or None)"""
        w = 24 // len(items)
        for i, (title, expr, unit, steps) in enumerate(items):
            self.panels.append({
                "id": self._id(), "type": "stat", "title": title, "datasource": DS,
                "gridPos": {"h": h, "w": w, "x": i * w, "y": self.y},
                "targets": [{"refId": "A", "expr": expr, "datasource": DS}],
                "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "colorMode": "value",
                            "graphMode": "area", "textMode": "auto"},
                "fieldConfig": {"defaults": {
                    "unit": unit,
                    "thresholds": {"mode": "absolute", "steps": steps or [{"color": "green", "value": None}]},
                }, "overrides": []},
            })
        self.y += h

    def ts(self, row_items, h=8):
        """row_items: list of (title, [(expr, legend)], unit, stack)"""
        w = 24 // len(row_items)
        for i, (title, targets, unit, stack) in enumerate(row_items):
            self.panels.append({
                "id": self._id(), "type": "timeseries", "title": title, "datasource": DS,
                "gridPos": {"h": h, "w": w, "x": i * w, "y": self.y},
                "targets": [
                    {"refId": chr(65 + j), "expr": e, "legendFormat": lg, "datasource": DS}
                    for j, (e, lg) in enumerate(targets)
                ],
                "fieldConfig": {"defaults": {
                    "unit": unit,
                    "custom": {"lineWidth": 1, "fillOpacity": 15 if stack else 0,
                               "stacking": {"mode": "normal" if stack else "none"},
                               "showPoints": "never"},
                }, "overrides": []},
                "options": {"legend": {"displayMode": "table", "placement": "bottom",
                                       "calcs": ["mean", "max", "lastNotNull"]},
                            "tooltip": {"mode": "multi", "sort": "desc"}},
            })
        self.y += h

    def table(self, title, expr, h=8):
        self.panels.append({
            "id": self._id(), "type": "table", "title": title, "datasource": DS,
            "gridPos": {"h": h, "w": 24, "x": 0, "y": self.y},
            "targets": [{"refId": "A", "expr": expr, "format": "table", "instant": True, "datasource": DS}],
            "transformations": [{"id": "organize", "options": {"excludeByName": {"Time": True}}}],
        })
        self.y += h

    def logs(self, title, expr, h=10):
        self.panels.append({
            "id": self._id(), "type": "logs", "title": title, "datasource": LOKI,
            "gridPos": {"h": h, "w": 24, "x": 0, "y": self.y},
            "targets": [{"refId": "A", "expr": expr, "datasource": LOKI}],
            "options": {"showTime": True, "wrapLogMessage": True, "sortOrder": "Descending",
                        "enableLogDetails": True},
        })
        self.y += h

    def render(self):
        return {
            "uid": self.uid, "title": self.title, "tags": ["cloudforge", *self.tags],
            "schemaVersion": 41, "version": 1, "editable": True, "graphTooltip": 1,
            "refresh": "30s", "time": {"from": "now-1h", "to": "now"},
            "timezone": "browser", "fiscalYearStartMonth": 0, "liveNow": False,
            "annotations": {"list": [{
                "builtIn": 1, "datasource": {"type": "grafana", "uid": "-- Grafana --"},
                "enable": True, "hide": True, "iconColor": "rgba(0, 211, 255, 1)",
                "name": "Annotations & Alerts", "type": "dashboard",
            }]},
            "templating": {"list": self.variables},
            "links": [{"title": "CloudForge", "type": "dashboards", "tags": ["cloudforge"],
                       "asDropdown": True}],
            "panels": self.panels,
        }


def query_var(name, label, query, include_all=True, multi=True):
    return {
        "name": name, "label": label, "type": "query", "datasource": DS,
        "query": {"query": query, "refId": "Var"}, "definition": query,
        "refresh": 2, "includeAll": include_all, "multi": multi, "sort": 1,
        "current": {"text": "All", "value": "$__all"} if include_all else {},
    }


RED = [{"color": "green", "value": None}, {"color": "orange", "value": 0.01}, {"color": "red", "value": 0.05}]
LAT = [{"color": "green", "value": None}, {"color": "orange", "value": 0.3}, {"color": "red", "value": 0.5}]
PCT = [{"color": "green", "value": None}, {"color": "orange", "value": 0.75}, {"color": "red", "value": 0.9}]


def cluster():
    b = Board("cloudforge-cluster", "CloudForge / Cluster", ["kubernetes", "cluster"],
              [query_var("namespace", "Namespace", "label_values(kube_pod_info, namespace)")])
    b.row("Capacity")
    b.stats([
        ("Nodes", "count(kube_node_info)", "none", None),
        ("Pods running", 'sum(kube_pod_status_phase{phase="Running"})', "none", None),
        ("CPU requests / allocatable",
         'sum(kube_pod_container_resource_requests{resource="cpu"}) / sum(kube_node_status_allocatable{resource="cpu"})',
         "percentunit", PCT),
        ("Memory requests / allocatable",
         'sum(kube_pod_container_resource_requests{resource="memory"}) / sum(kube_node_status_allocatable{resource="memory"})',
         "percentunit", PCT),
        ("Pods not ready",
         'sum(kube_pod_status_ready{condition="false",namespace=~"$namespace"}) or vector(0)', "none",
         [{"color": "green", "value": None}, {"color": "red", "value": 1}]),
        ("Restarts (1h)", 'sum(increase(kube_pod_container_status_restarts_total{namespace=~"$namespace"}[1h]))',
         "none", [{"color": "green", "value": None}, {"color": "orange", "value": 1}, {"color": "red", "value": 5}]),
    ])
    b.row("Workloads")
    b.ts([
        ("CPU usage by namespace",
         [('sum by (namespace) (rate(container_cpu_usage_seconds_total{container!="",namespace=~"$namespace"}[5m]))', "{{namespace}}")],
         "cores", True),
        ("Memory working set by namespace",
         [('sum by (namespace) (container_memory_working_set_bytes{container!="",namespace=~"$namespace"})', "{{namespace}}")],
         "bytes", True),
    ])
    b.ts([
        ("Network receive by namespace",
         [('sum by (namespace) (rate(container_network_receive_bytes_total{namespace=~"$namespace"}[5m]))', "{{namespace}}")],
         "Bps", False),
        ("Network transmit by namespace",
         [('sum by (namespace) (rate(container_network_transmit_bytes_total{namespace=~"$namespace"}[5m]))', "{{namespace}}")],
         "Bps", False),
    ])
    b.row("Autoscaling & disruption")
    b.ts([
        ("HPA current vs max replicas", [
            ('kube_horizontalpodautoscaler_status_current_replicas{namespace=~"$namespace"}', "{{horizontalpodautoscaler}} current"),
            ('kube_horizontalpodautoscaler_spec_max_replicas{namespace=~"$namespace"}', "{{horizontalpodautoscaler}} max"),
        ], "none", False),
        ("PDB allowed disruptions",
         [('kube_poddisruptionbudget_status_pod_disruptions_allowed{namespace=~"$namespace"}', "{{namespace}}/{{poddisruptionbudget}}")],
         "none", False),
    ])
    b.table("Pods not running",
            'sum by (namespace, pod, phase) (kube_pod_status_phase{phase!~"Running|Succeeded",namespace=~"$namespace"}) > 0')
    b.row("Service mesh (Istio)")
    b.ts([
        ("Mesh request rate by destination", [
            ('sum by (destination_workload) (rate(istio_requests_total{reporter="destination"}[5m]))', "{{destination_workload}}")
        ], "reqps", False),
        ("mTLS share of mesh traffic", [
            ('sum(rate(istio_requests_total{reporter="destination",connection_security_policy="mutual_tls"}[5m])) '
             '/ sum(rate(istio_requests_total{reporter="destination"}[5m]))', "mTLS")
        ], "percentunit", False),
    ])
    return b


def node():
    b = Board("cloudforge-node", "CloudForge / Nodes", ["node"],
              [query_var("instance", "Node", "label_values(node_uname_info, instance)")])
    inst = 'instance=~"$instance"'
    b.row("Summary")
    b.stats([
        ("CPU busy", f'1 - avg(rate(node_cpu_seconds_total{{mode="idle",{inst}}}[5m]))', "percentunit", PCT),
        ("Memory used", f"1 - sum(node_memory_MemAvailable_bytes{{{inst}}}) / sum(node_memory_MemTotal_bytes{{{inst}}})", "percentunit", PCT),
        ("Root disk used",
         f'1 - sum(node_filesystem_avail_bytes{{mountpoint="/",fstype!~"tmpfs|overlay",{inst}}}) '
         f'/ sum(node_filesystem_size_bytes{{mountpoint="/",fstype!~"tmpfs|overlay",{inst}}})', "percentunit", PCT),
        ("Load (1m) per core",
         f"sum(node_load1{{{inst}}}) / count(node_cpu_seconds_total{{mode=\"idle\",{inst}}})", "none",
         [{"color": "green", "value": None}, {"color": "orange", "value": 1}, {"color": "red", "value": 2}]),
        ("Uptime", f"min(time() - node_boot_time_seconds{{{inst}}})", "s", None),
    ])
    b.row("CPU & memory")
    b.ts([
        ("CPU by mode", [(f'sum by (mode) (rate(node_cpu_seconds_total{{mode!="idle",{inst}}}[5m]))', "{{mode}}")], "cores", True),
        ("Memory", [
            (f"sum by (instance) (node_memory_MemTotal_bytes{{{inst}}} - node_memory_MemAvailable_bytes{{{inst}}})", "{{instance}} used"),
            (f"sum by (instance) (node_memory_MemTotal_bytes{{{inst}}})", "{{instance}} total"),
        ], "bytes", False),
    ])
    b.row("Disk")
    b.ts([
        ("Disk space used %", [(
            f'1 - node_filesystem_avail_bytes{{fstype!~"tmpfs|overlay",{inst}}} / node_filesystem_size_bytes{{fstype!~"tmpfs|overlay",{inst}}}',
            "{{instance}} {{mountpoint}}")], "percentunit", False),
        ("Disk IO", [
            (f"sum by (instance) (rate(node_disk_read_bytes_total{{{inst}}}[5m]))", "{{instance}} read"),
            (f"sum by (instance) (rate(node_disk_written_bytes_total{{{inst}}}[5m]))", "{{instance}} write"),
        ], "Bps", False),
    ])
    b.row("Network")
    b.ts([
        ("Network throughput", [
            (f'sum by (instance) (rate(node_network_receive_bytes_total{{device!~"lo|veth.*|cali.*|cni.*",{inst}}}[5m]))', "{{instance}} rx"),
            (f'sum by (instance) (rate(node_network_transmit_bytes_total{{device!~"lo|veth.*|cali.*|cni.*",{inst}}}[5m]))', "{{instance}} tx"),
        ], "Bps", False),
        ("Network errors / drops", [
            (f"sum by (instance) (rate(node_network_receive_errs_total{{{inst}}}[5m]) + rate(node_network_transmit_errs_total{{{inst}}}[5m]))", "{{instance}} errors"),
            (f"sum by (instance) (rate(node_network_receive_drop_total{{{inst}}}[5m]) + rate(node_network_transmit_drop_total{{{inst}}}[5m]))", "{{instance}} drops"),
        ], "pps", False),
    ])
    return b


def application():
    b = Board("cloudforge-application", "CloudForge / Application (RED)", ["application", "slo"],
              [query_var("route", "Route", 'label_values(http_requests_total{namespace="backend"}, route)'),
               {"name": "loki", "label": "Loki", "type": "datasource", "query": "loki", "current": {}, "hide": 0}])
    sel = 'namespace="backend",route=~"$route"'
    b.row("Golden signals")
    b.stats([
        ("Throughput", f"sum(rate(http_requests_total{{{sel}}}[5m]))", "reqps", None),
        ("Error rate (5xx)",
         f'sum(rate(http_requests_total{{{sel},status=~"5.."}}[5m])) / clamp_min(sum(rate(http_requests_total{{{sel}}}[5m])), 1e-9)',
         "percentunit", RED),
        ("p95 latency", f"histogram_quantile(0.95, sum by (le) (rate(http_request_duration_seconds_bucket{{{sel}}}[5m])))", "s", LAT),
        ("p99 latency", f"histogram_quantile(0.99, sum by (le) (rate(http_request_duration_seconds_bucket{{{sel}}}[5m])))", "s", LAT),
        ("In-flight", 'sum(http_requests_in_flight{namespace="backend"})', "none", None),
        ("30d availability",
         'clamp_max(1 - (sum(increase(http_requests_total{namespace="backend",status=~"5.."}[30d])) '
         '/ clamp_min(sum(increase(http_requests_total{namespace="backend"}[30d])), 1)), 1)',
         "percentunit", [{"color": "red", "value": None}, {"color": "orange", "value": 0.99}, {"color": "green", "value": 0.995}]),
    ])
    b.row("Rate / errors / duration")
    b.ts([
        ("Requests by route", [(f"sum by (route) (rate(http_requests_total{{{sel}}}[5m]))", "{{route}}")], "reqps", True),
        ("Responses by status", [(f"sum by (status) (rate(http_requests_total{{{sel}}}[5m]))", "{{status}}")], "reqps", True),
    ])
    b.ts([
        ("Latency percentiles", [
            (f"histogram_quantile({q}, sum by (le) (rate(http_request_duration_seconds_bucket{{{sel}}}[5m])))", f"p{int(q*100)}")
            for q in (0.5, 0.9, 0.95, 0.99)
        ], "s", False),
        ("p95 latency by route", [(
            f"histogram_quantile(0.95, sum by (le, route) (rate(http_request_duration_seconds_bucket{{{sel}}}[5m])))", "{{route}}")],
            "s", False),
    ])
    b.row("Canary / rollout view")
    b.ts([
        ("Error ratio by pod template hash (stable vs canary)", [(
            'sum by (rollouts_pod_template_hash) (rate(http_requests_total{namespace="backend",status=~"5.."}[2m])) '
            '/ sum by (rollouts_pod_template_hash) (rate(http_requests_total{namespace="backend"}[2m]))',
            "{{rollouts_pod_template_hash}}")], "percentunit", False),
        ("Mesh traffic split to backend-api by version", [(
            'sum by (destination_version) (rate(istio_requests_total{reporter="destination",destination_workload="backend-api"}[2m]))',
            "{{destination_version}}")], "reqps", True),
    ])
    b.row("Dependencies")
    b.ts([
        ("Cache hit ratio", [(
            'sum(rate(cloudforge_cache_events_total{result="hit"}[5m])) / clamp_min(sum(rate(cloudforge_cache_events_total{result=~"hit|miss"}[5m])), 1e-9)',
            "hit ratio")], "percentunit", False),
        ("PostgreSQL connections & TPS", [
            ("sum(pg_stat_activity_count)", "connections"),
            ('sum(rate(pg_stat_database_xact_commit{datname="cloudforge"}[5m]))', "commits/s"),
        ], "short", False),
        ("Redis memory & clients", [
            ("redis_memory_used_bytes", "used bytes"),
            ("redis_connected_clients", "clients"),
        ], "short", False),
    ])
    b.ts([
        ("Apache proxy requests/s", [("sum(rate(apache_accesses_total[5m]))", "req/s")], "reqps", False),
        ("Pod CPU (backend)", [(
            'sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="backend",container!="",container!="POD"}[5m]))', "{{pod}}")],
            "cores", False),
        ("Pod memory (backend)", [(
            'sum by (pod) (container_memory_working_set_bytes{namespace="backend",container!="",container!="POD"})', "{{pod}}")],
            "bytes", False),
    ])
    b.row("Logs")
    b.logs("Backend errors (Loki)", '{namespace="backend"} | json | level=~"ERROR|WARNING"')
    return b


def business():
    b = Board("cloudforge-business", "CloudForge / Business", ["business", "kpi"])
    b.row("KPIs")
    money = [{"color": "blue", "value": None}]
    b.stats([
        ("Orders (24h)", "sum(increase(cloudforge_orders_created_total[24h]))", "none", money),
        ("Revenue (24h)", "sum(increase(cloudforge_order_revenue_cents_total[24h])) / 100", "currencyUSD", money),
        ("Avg order value (24h)",
         "(sum(increase(cloudforge_order_revenue_cents_total[24h])) / 100) / clamp_min(sum(increase(cloudforge_orders_created_total[24h])), 1)",
         "currencyUSD", money),
        ("Orders / min (now)", "sum(rate(cloudforge_orders_created_total[5m])) * 60", "none", money),
        ("Checkout success rate",
         '1 - sum(rate(http_requests_total{route="/api/v1/orders",method="POST",status=~"5..|409"}[1h])) '
         '/ clamp_min(sum(rate(http_requests_total{route="/api/v1/orders",method="POST"}[1h])), 1e-9)',
         "percentunit", [{"color": "red", "value": None}, {"color": "orange", "value": 0.9}, {"color": "green", "value": 0.97}]),
    ])
    b.row("Trends")
    b.ts([
        ("Orders per minute by product", [("sum by (product) (rate(cloudforge_orders_created_total[5m])) * 60", "{{product}}")], "none", True),
        ("Revenue per hour (USD)", [("sum(rate(cloudforge_order_revenue_cents_total[1h])) * 3600 / 100", "revenue/h")], "currencyUSD", False),
    ])
    b.ts([
        ("Checkout outcomes", [
            ('sum by (status) (rate(http_requests_total{route="/api/v1/orders",method="POST"}[5m]))', "{{status}}")
        ], "reqps", True),
        ("Catalog views/s", [
            ('sum(rate(http_requests_total{route=~"/api/v1/products.*",method="GET"}[5m]))', "views/s")
        ], "reqps", False),
    ])
    b.table("Top products by orders (24h)",
            "sort_desc(sum by (product) (increase(cloudforge_orders_created_total[24h])))")
    return b


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    for board in (cluster(), node(), application(), business()):
        name = board.uid.removeprefix("cloudforge-")
        path = OUT / f"{name}.json"
        path.write_text(json.dumps(board.render(), indent=2) + "\n", encoding="utf-8")
        print(f"wrote {path.relative_to(OUT.parents[4])}")


if __name__ == "__main__":
    main()
