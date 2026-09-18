{{- define "redis.fullname" -}}
{{- default .Chart.Name .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "redis.selectorLabels" -}}
app.kubernetes.io/name: {{ include "redis.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "redis.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{ include "redis.selectorLabels" . }}
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
app.kubernetes.io/component: cache
app.kubernetes.io/part-of: cloudforge
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "redis.secret" -}}
{{- if .Values.auth.createSecret -}}{{ include "redis.fullname" . }}{{- else -}}{{ .Values.auth.existingSecret }}{{- end -}}
{{- end -}}
