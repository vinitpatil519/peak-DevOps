{{- define "apache.fullname" -}}
{{- default .Chart.Name .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "apache.tag" -}}
{{- default .Chart.AppVersion .Values.image.tag -}}
{{- end -}}

{{- define "apache.selectorLabels" -}}
app.kubernetes.io/name: {{ include "apache.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "apache.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{ include "apache.selectorLabels" . }}
app.kubernetes.io/version: {{ include "apache.tag" . | quote }}
app.kubernetes.io/component: reverse-proxy
app.kubernetes.io/part-of: cloudforge
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}
