import groovy.json.JsonOutput

def call(String trivyJsonPath, String identifier, Map opts = [:]) {
  def defaults = [
    toolName: 'trivy',
    service : 'petclinic',
    tags    : [scanner: 'trivy']
  ]
  def cfg = defaults + opts

  if (!fileExists(trivyJsonPath)) {
    echo "No trivy report at ${trivyJsonPath} — skipping security_scans upsert."
    return
  }

  if (!env.IDP_ENTITY_REF) {
    error "upsertTrivyScan(): IDP_ENTITY_REF env var is not set (populate it in bootstrap/demo.env)"
  }

  def report   = readJSON file: trivyJsonPath
  def counts   = [critical: 0, high: 0, medium: 0, low: 0]

  (report.Results ?: []).each { result ->
    (result.Vulnerabilities ?: []).each { v ->
      def sev = (v.Severity ?: 'LOW').toLowerCase()
      if (counts.containsKey(sev)) counts[sev]++
    }
  }

  def target = report.ArtifactName ? [
    name   : report.ArtifactName,
    type   : (report.ArtifactType ?: 'Other'),
    version: (report.Metadata?.ImageID ?: null)
  ] : null

  def record = [
    identifier: identifier,
    timestamp : env.ISO_TS,
    name      : "Trivy scan petclinic #${env.BUILD_NUMBER}",
    entity_ref: env.IDP_ENTITY_REF,
    service   : cfg.service,
    toolName  : cfg.toolName,
    url       : env.BUILD_URL,
    scanResult: counts,
    tags      : cfg.tags
  ]
  if (target) record.target = target

  withCredentials([
    string(credentialsId: 'harness-api-key',    variable: 'HARNESS_API_KEY'),
    string(credentialsId: 'harness-account-id', variable: 'HARNESS_ACCOUNT_ID'),
    string(credentialsId: 'iid-security-scan',  variable: 'IID')
  ]) {
    def body = JsonOutput.toJson([records: [record]])
    def url  = "${env.HARNESS_IM_URL}/api/v1/accounts/${env.HARNESS_ACCOUNT_ID}/integrations/${env.IID}/data/security_scan"

    echo "--- upsert(security_scans) payload ---\n${JsonOutput.prettyPrint(body)}\n--- end ---"

    httpRequest(
      url:                url,
      httpMode:           'POST',
      contentType:        'APPLICATION_JSON',
      customHeaders:      [[name: 'x-api-key', value: "${env.HARNESS_API_KEY}"]],
      requestBody:        body,
      validResponseCodes: '202'
    )
    echo "Upserted security_scans record: ${identifier} (critical=${counts.critical}, high=${counts.high}, medium=${counts.medium}, low=${counts.low})"
  }
}
