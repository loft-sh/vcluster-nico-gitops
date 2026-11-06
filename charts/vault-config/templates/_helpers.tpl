{{- define "vc.on" -}}
{{- if eq (toString .) "true" }}true{{ end }}
{{- end }}

{{- define "vc.name" -}}
{{- regexReplaceAll "[^a-z0-9-]+" (lower .) "-" | trunc 63 | trimAll "-" }}
{{- end }}

{{- define "vc.policy" -}}
{{- printf "%s-%s" (replace "/" "-" .root.Values.prefix) .name }}
{{- end }}

{{- define "vc.approle" -}}
{{- .Values.staticToken.mount | default (printf "%s/approle" .Values.prefix) }}
{{- end }}

{{- define "vc.globalAuth" -}}
{{- .Values.global.authMount | default (printf "%s/kubernetes-global" .Values.prefix) }}
{{- end }}

{{- define "vc.auth" -}}
authentication:
  path: {{ .Values.authMount }}
  role: {{ .Values.operator.role }}
  serviceAccount:
    name: {{ .Values.operator.serviceAccount }}
{{- end }}

{{- define "vc.keep" -}}
helm.sh/resource-policy: keep
argocd.argoproj.io/sync-options: Prune=false,Delete=false
{{- end }}
