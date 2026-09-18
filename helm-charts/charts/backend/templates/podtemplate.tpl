{{- define "backend.podTemplate" -}}
metadata:
  labels:
    {{- include "backend.labels" . | nindent 4 }}
    version: {{ include "backend.tag" . | quote }}
    {{- with .Values.podLabels }}{{ toYaml . | nindent 4 }}{{ end }}
  annotations:
    checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
    # Istio merges app metrics into the sidecar's :15020/stats/prometheus endpoint so
    # Prometheus can scrape outside mTLS.
    prometheus.io/scrape: "true"
    prometheus.io/port: {{ .Values.service.port | quote }}
    prometheus.io/path: /metrics/
    {{- if .Values.istio.enabled }}
    sidecar.istio.io/inject: "true"
    proxy.istio.io/config: '{ "holdApplicationUntilProxyStarts": true }'
    {{- end }}
    {{- with .Values.podAnnotations }}{{ toYaml . | nindent 4 }}{{ end }}
spec:
  serviceAccountName: {{ include "backend.serviceAccountName" . }}
  automountServiceAccountToken: false
  {{- with .Values.imagePullSecrets }}
  imagePullSecrets: {{ toYaml . | nindent 4 }}
  {{- end }}
  securityContext: {{ toYaml .Values.podSecurityContext | nindent 4 }}
  terminationGracePeriodSeconds: 30
  containers:
    - name: api
      image: "{{ .Values.image.repository }}:{{ include "backend.tag" . }}"
      imagePullPolicy: {{ .Values.image.pullPolicy }}
      ports:
        - name: http
          containerPort: 8000
          protocol: TCP
      env:
        - name: APP_VERSION
          value: {{ include "backend.tag" . | quote }}
      envFrom:
        - configMapRef:
            name: {{ include "backend.fullname" . }}
        - secretRef:
            name: {{ include "backend.secretName" . }}
      startupProbe:
        httpGet: { path: {{ .Values.probes.startup.path }}, port: http }
        failureThreshold: {{ .Values.probes.startup.failureThreshold }}
        periodSeconds: {{ .Values.probes.startup.periodSeconds }}
      livenessProbe:
        httpGet: { path: {{ .Values.probes.liveness.path }}, port: http }
        periodSeconds: {{ .Values.probes.liveness.periodSeconds }}
        timeoutSeconds: {{ .Values.probes.liveness.timeoutSeconds }}
        failureThreshold: {{ .Values.probes.liveness.failureThreshold }}
      readinessProbe:
        httpGet: { path: {{ .Values.probes.readiness.path }}, port: http }
        periodSeconds: {{ .Values.probes.readiness.periodSeconds }}
        timeoutSeconds: {{ .Values.probes.readiness.timeoutSeconds }}
        failureThreshold: {{ .Values.probes.readiness.failureThreshold }}
      lifecycle:
        preStop:
          # Let endpoints/Envoy drain before SIGTERM reaches gunicorn.
          exec: { command: ["python", "-c", "import time; time.sleep(5)"] }
      resources: {{ toYaml .Values.resources | nindent 8 }}
      securityContext: {{ toYaml .Values.securityContext | nindent 8 }}
      volumeMounts:
        - { name: tmp, mountPath: /tmp }
  volumes:
    - name: tmp
      emptyDir: { sizeLimit: 64Mi }
  {{- if .Values.topologySpreadConstraints.enabled }}
  topologySpreadConstraints:
    - maxSkew: {{ .Values.topologySpreadConstraints.maxSkew }}
      topologyKey: topology.kubernetes.io/zone
      whenUnsatisfiable: ScheduleAnyway
      labelSelector:
        matchLabels: {{ include "backend.selectorLabels" . | nindent 10 }}
    - maxSkew: {{ .Values.topologySpreadConstraints.maxSkew }}
      topologyKey: kubernetes.io/hostname
      whenUnsatisfiable: ScheduleAnyway
      labelSelector:
        matchLabels: {{ include "backend.selectorLabels" . | nindent 10 }}
  {{- end }}
  {{- with .Values.nodeSelector }}
  nodeSelector: {{ toYaml . | nindent 4 }}
  {{- end }}
  {{- with .Values.affinity }}
  affinity: {{ toYaml . | nindent 4 }}
  {{- end }}
  {{- with .Values.tolerations }}
  tolerations: {{ toYaml . | nindent 4 }}
  {{- end }}
{{- end -}}
