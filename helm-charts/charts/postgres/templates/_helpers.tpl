{{- define "pg.fullname" -}}
{{- default .Chart.Name .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "pg.selectorLabels" -}}
app.kubernetes.io/name: {{ include "pg.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "pg.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{ include "pg.selectorLabels" . }}
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
app.kubernetes.io/component: database
app.kubernetes.io/part-of: cloudforge
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "pg.secret" -}}
{{- if .Values.auth.createSecret -}}{{ include "pg.fullname" . }}{{- else -}}{{ .Values.auth.existingSecret }}{{- end -}}
{{- end -}}

{{- define "pg.restricted" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
runAsNonRoot: true
capabilities: { drop: [ALL] }
{{- end -}}
