{{/* Names */}}
{{- define "polysite.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "polysite.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "polysite.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Labels. Call with (dict "ctx" . "component" "cms") */}}
{{- define "polysite.labels" -}}
helm.sh/chart: {{ include "polysite.chart" .ctx }}
app.kubernetes.io/name: {{ include "polysite.name" .ctx }}
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
app.kubernetes.io/version: {{ .ctx.Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .ctx.Release.Service }}
app.kubernetes.io/component: {{ .component }}
{{- with .ctx.Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{- define "polysite.selectorLabels" -}}
app.kubernetes.io/name: {{ include "polysite.name" .ctx }}
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{/* Annotations on every resource; renders nothing when there are none. */}}
{{- define "polysite.commonAnnotations" -}}
{{- with .Values.commonAnnotations }}
annotations:
{{ toYaml . | indent 2 }}
{{- end }}
{{- end -}}

{{- define "polysite.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "polysite.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/* Images. Call with (dict "ctx" . "img" .Values.image.cms) */}}
{{- define "polysite.image" -}}
{{- $root := .ctx.Values.image -}}
{{- $registry := default $root.registry .img.registry -}}
{{- if .img.digest -}}
{{- printf "%s/%s@%s" $registry .img.repository .img.digest -}}
{{- else -}}
{{- printf "%s/%s:%s" $registry .img.repository (default (default (printf "v%s" .ctx.Chart.AppVersion) $root.tag) .img.tag) -}}
{{- end -}}
{{- end -}}

{{- define "polysite.imagePullSecrets" -}}
{{- with .Values.image.pullSecrets }}
imagePullSecrets:
{{ toYaml . | indent 2 }}
{{- end }}
{{- end -}}

{{/* The Secret the apps read: yours, or the one this chart creates. */}}
{{- define "polysite.secretName" -}}
{{- if .Values.secrets.existingSecret -}}{{ .Values.secrets.existingSecret }}{{- else -}}{{ include "polysite.fullname" . }}{{- end -}}
{{- end -}}

{{/* The migration Job reads its own copies of the config and of the chart-made Secret: a hook runs before the release's own resources exist. */}}
{{- define "polysite.migrateSecretName" -}}
{{- if .Values.secrets.existingSecret -}}{{ .Values.secrets.existingSecret }}{{- else -}}{{ include "polysite.fullname" . }}-migrate{{- end -}}
{{- end -}}

{{/* In-cluster hostnames. */}}
{{- define "polysite.cmsHost" -}}{{ include "polysite.fullname" . }}-cms{{- end -}}
{{- define "polysite.webHost" -}}{{ include "polysite.fullname" . }}-web{{- end -}}
{{- define "polysite.dbHost" -}}{{ include "polysite.fullname" . }}-postgres{{- end -}}

{{/* DATABASE_URL for a chart-created Secret. */}}
{{- define "polysite.databaseUrl" -}}
{{- if .Values.postgresql.enabled -}}
{{- printf "postgres://%s:%s@%s:5432/%s" .Values.postgresql.user (required "postgresql.password is required with postgresql.enabled" .Values.postgresql.password | urlquery) (include "polysite.dbHost" .) .Values.postgresql.database -}}
{{- else -}}
{{- required "secrets.databaseUrl (or secrets.existingSecret with DATABASE_URL, or postgresql.enabled) is required" .Values.secrets.databaseUrl -}}
{{- end -}}
{{- end -}}

{{/* Refuses combinations that would break an install. Included once, from NOTES.txt-independent templates/validate.yaml. */}}
{{- define "polysite.guards" -}}
{{- if not .Values.domains.admin }}{{ fail "domains.admin is required (the admin and API hostname)" }}{{ end -}}
{{- if not .Values.domains.sites }}{{ fail "domains.sites is required (at least one public site hostname)" }}{{ end -}}
{{- if and (gt (int .Values.cms.replicaCount) 1) (not .Values.cms.allowMultiReplica) }}
{{- fail "cms.replicaCount > 1 is refused: uploads live on one disk, and role changes, sign-in limits and spam limits live in each process's memory. Read docs/guide/deploy/kubernetes.md (What is NOT safe with more than one replica), then set cms.allowMultiReplica=true" }}
{{- end }}
{{- if and (gt (int .Values.web.replicaCount) 1) (not .Values.web.allowMultiReplica) }}
{{- fail "web.replicaCount > 1 is refused: the web app keeps page caches and rate limits in each process, and the CMS's publish call reaches only one replica (a two-replica test showed a change on both within 2 seconds, but the rest of the per-process state was not examined). Read docs/guide/deploy/kubernetes.md (What is NOT safe with more than one replica), then set web.allowMultiReplica=true" }}
{{- end }}
{{- if and .Values.cms.autoscaling.enabled (not .Values.cms.allowMultiReplica) }}{{ fail "cms.autoscaling needs cms.allowMultiReplica=true (see the guide)" }}{{ end -}}
{{- if and .Values.web.autoscaling.enabled (not .Values.web.allowMultiReplica) }}{{ fail "web.autoscaling needs web.allowMultiReplica=true (see the guide)" }}{{ end -}}
{{- if and (eq .Values.domains.scheme "https") (not .Values.secrets.existingSecret) (not .Values.secrets.setupToken) }}{{ fail "domains.scheme=https needs a setup token: put POLYSITE_SETUP_TOKEN in your Secret or set secrets.setupToken" }}{{ end -}}
{{- if and .Values.backups.enabled (not .Values.backups.existingSecret) (not .Values.backups.persistence.enabled) }}{{ fail "backups.enabled needs somewhere to put the archives: backups.persistence.enabled=true, or backups.existingSecret with BACKUP_RCLONE_REMOTE" }}{{ end -}}
{{- if and (not .Values.media.persistence.enabled) (or (gt (int .Values.cms.replicaCount) 1) .Values.cms.autoscaling.enabled) }}{{ fail "media.persistence.enabled=false with several cms replicas would give each replica its own uploads" }}{{ end -}}
{{- end -}}

{{/* Non-secret environment shared by the cms and the migration Job. */}}
{{- define "polysite.configData" -}}
CMS_DOMAIN: {{ .Values.domains.admin | quote }}
CMS_SCHEME: {{ .Values.domains.scheme | quote }}
SITE_DOMAIN: {{ first .Values.domains.sites | quote }}
SITE_SCHEME: {{ .Values.domains.scheme | quote }}
NUXT_REVALIDATE_URL: {{ printf "http://%s:%v/api/revalidate" (include "polysite.webHost" .) .Values.web.service.port | quote }}
{{- range $k, $v := .Values.config }}
{{ $k }}: {{ $v | quote }}
{{- end }}
{{- end -}}

{{/* Secret data. Used for the release's Secret and for the migration Job's copy. */}}
{{- define "polysite.secretData" -}}
PAYLOAD_SECRET: {{ required "secrets.payloadSecret (or secrets.existingSecret) is required" .Values.secrets.payloadSecret | b64enc | quote }}
REVALIDATE_SECRET: {{ required "secrets.revalidateSecret (or secrets.existingSecret) is required" .Values.secrets.revalidateSecret | b64enc | quote }}
DATABASE_URL: {{ include "polysite.databaseUrl" . | b64enc | quote }}
{{- if .Values.secrets.setupToken }}
POLYSITE_SETUP_TOKEN: {{ .Values.secrets.setupToken | b64enc | quote }}
{{- end }}
{{- if .Values.secrets.smtpPassword }}
SMTP_PASS: {{ .Values.secrets.smtpPassword | b64enc | quote }}
{{- end }}
{{- if .Values.postgresql.enabled }}
POSTGRES_PASSWORD: {{ required "postgresql.password is required with postgresql.enabled" .Values.postgresql.password | b64enc | quote }}
{{- end }}
{{- end -}}
