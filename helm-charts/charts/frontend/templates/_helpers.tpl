{{- define "frontend.fullname" -}}
{{- default .Chart.Name .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "frontend.tag" -}}
{{- default .Chart.AppVersion .Values.image.tag -}}
{{- end -}}

{{- define "frontend.selectorLabels" -}}
app.kubernetes.io/name: {{ include "frontend.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "frontend.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{ include "frontend.selectorLabels" . }}
app.kubernetes.io/version: {{ include "frontend.tag" . | quote }}
app.kubernetes.io/component: web
app.kubernetes.io/part-of: cloudforge
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "frontend.podTemplate" -}}
metadata:
  labels:
    {{- include "frontend.labels" . | nindent 4 }}
    version: {{ include "frontend.tag" . | quote }}
  annotations:
    checksum/upstream: {{ .Values.apiUpstreamHost | sha256sum }}
    {{- if .Values.istio.enabled }}
    sidecar.istio.io/inject: "true"
    proxy.istio.io/config: '{ "holdApplicationUntilProxyStarts": true }'
    {{- end }}
spec:
  serviceAccountName: {{ include "frontend.fullname" . }}
  automountServiceAccountToken: false
  {{- with .Values.imagePullSecrets }}
  imagePullSecrets: {{ toYaml . | nindent 4 }}
  {{- end }}
  securityContext:
    runAsNonRoot: true
    runAsUser: 101
    runAsGroup: 101
    seccompProfile: { type: RuntimeDefault }
  containers:
    - name: web
      image: "{{ .Values.image.repository }}:{{ include "frontend.tag" . }}"
      imagePullPolicy: {{ .Values.image.pullPolicy }}
      env:
        - { name: API_UPSTREAM_HOST, value: {{ .Values.apiUpstreamHost | quote }} }
      ports:
        - { name: http, containerPort: {{ .Values.service.targetPort }}, protocol: TCP }
      readinessProbe:
        httpGet: { path: /nginx-health, port: http }
        periodSeconds: 5
      livenessProbe:
        httpGet: { path: /nginx-health, port: http }
        periodSeconds: 10
      lifecycle:
        preStop:
          exec: { command: ["/bin/sh", "-c", "sleep 5"] }
      resources: {{ toYaml .Values.resources | nindent 8 }}
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: { drop: [ALL] }
      volumeMounts:
        - { name: tmp, mountPath: /tmp }
        - { name: nginx-conf, mountPath: /etc/nginx/conf.d }
  volumes:
    - { name: tmp, emptyDir: { sizeLimit: 32Mi } }
    - { name: nginx-conf, emptyDir: { sizeLimit: 1Mi } }   # envsubst renders templates here
  topologySpreadConstraints:
    - maxSkew: 1
      topologyKey: kubernetes.io/hostname
      whenUnsatisfiable: ScheduleAnyway
      labelSelector:
        matchLabels: {{- include "frontend.selectorLabels" . | nindent 10 }}
{{- end -}}
