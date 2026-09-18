{{- define "platform.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
app.kubernetes.io/part-of: cloudforge
app.kubernetes.io/component: platform
app.kubernetes.io/managed-by: {{ .Release.Service }}
cloudforge.dev/environment: {{ .Values.environment }}
{{- end -}}
