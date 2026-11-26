{{/*
Full image reference for a retail-store service built by the pipeline.
Usage: {{ include "retail-store.serviceImage" (dict "root" $ "name" "ui") }}
*/}}
{{- define "retail-store.serviceImage" -}}
{{- printf "%s/retail-store-sample-%s:%s" (trimSuffix "/" .root.Values.image.registry) .name (toString .root.Values.image.tag) -}}
{{- end -}}

{{/*
Pod annotations opting out of CloudWatch Application Signals / OpenTelemetry
auto-instrumentation (the injected agent slows JVM startup a lot on small nodes).
*/}}
{{- define "retail-store.podAnnotations" -}}
{{- if .Values.applicationSignals.optOut }}
instrumentation.opentelemetry.io/inject-java: "false"
instrumentation.opentelemetry.io/inject-nodejs: "false"
instrumentation.opentelemetry.io/inject-python: "false"
instrumentation.opentelemetry.io/inject-dotnet: "false"
{{- end }}
{{- end -}}
