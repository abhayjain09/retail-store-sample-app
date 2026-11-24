{{/*
Full image reference for a retail-store service built by the pipeline.
Usage: {{ include "retail-store.serviceImage" (dict "root" $ "name" "ui") }}
*/}}
{{- define "retail-store.serviceImage" -}}
{{- printf "%s/retail-store-sample-%s:%s" (trimSuffix "/" .root.Values.image.registry) .name (toString .root.Values.image.tag) -}}
{{- end -}}
