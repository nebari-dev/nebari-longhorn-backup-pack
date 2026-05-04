{{- /*
Validation guards. Rendered first by being included from every resource template.
Fails the render with a clear message instead of producing invalid YAML.
*/ -}}

{{- define "nebari-longhorn-backup.validate" -}}

{{- /* cron expressions */ -}}
{{- $cronRe := "^(\\S+\\s+){4}\\S+$" -}}
{{- if not (regexMatch $cronRe .Values.snapshot.cron) -}}
{{- fail (printf "snapshot.cron is not a valid 5-field cron expression: %q" .Values.snapshot.cron) -}}
{{- end -}}
{{- if not (regexMatch $cronRe .Values.backup.cron) -}}
{{- fail (printf "backup.cron is not a valid 5-field cron expression: %q" .Values.backup.cron) -}}
{{- end -}}

{{- /* retention is a positive integer */ -}}
{{- if le (int .Values.snapshot.retain) 0 -}}
{{- fail (printf "snapshot.retain must be > 0 (got %d)" (int .Values.snapshot.retain)) -}}
{{- end -}}
{{- if le (int .Values.backup.retain) 0 -}}
{{- fail (printf "backup.retain must be > 0 (got %d)" (int .Values.backup.retain)) -}}
{{- end -}}

{{- /* numberOfReplicas in {1,2,3} */ -}}
{{- if not (has (int .Values.storageClass.numberOfReplicas) (list 1 2 3)) -}}
{{- fail (printf "storageClass.numberOfReplicas must be 1, 2, or 3 (got %d)" (int .Values.storageClass.numberOfReplicas)) -}}
{{- end -}}

{{- end -}}
