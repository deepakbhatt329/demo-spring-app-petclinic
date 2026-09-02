import groovy.json.JsonOutput

def call(String reportPath, String identifier, Map opts = [:]) {
  def defaults = [
    toolName: 'dependency-check',
    service : 'petclinic',
    tags    : [scanner: 'dependency-check']
  ]
  def cfg = defaults + opts

  if (!fileExists(reportPath)) {
    echo "No Dependency-Check report at ${reportPath} — skipping security_scan upsert."
    return
  }

  if (!env.IDP_ENTITY_REF) {
    error "upsertDepCheckScan(): IDP_ENTITY_REF env var is not set (populate it in bootstrap/demo.env)"
  }

  def report = readJSON file: reportPath
  def counts = [critical: 0, high: 0, medium: 0, low: 0]

  (report.dependencies ?: []).each { dep ->
    (dep.vulnerabilities ?: []).each { v ->
      def sev = (v.severity ?: 'LOW').toLowerCase()
      if (counts.containsKey(sev)) counts[sev]++
    }
  }

  def record = [
    identifier: identifier,
    timestamp : env.ISO_TS,
    name      : "Dependency-Check scan petclinic #${env.BUILD_NUMBER}",
    entity_ref: env.IDP_ENTITY_REF,
    service   : cfg.service,
    toolName  : cfg.toolName,
    url       : env.BUILD_URL,
    scanResult: counts,
    target    : [name: 'petclinic', type: 'Repo', url: env.REPO_URL],
    tags      : cfg.tags
  ]

  withCredentials([
    string(credentialsId: 'harness-api-key',    variable: 'HARNESS_API_KEY'),
    string(credentialsId: 'harness-account-id', variable: 'HARNESS_ACCOUNT_ID'),
    string(credentialsId: 'iid-security-scan',  variable: 'IID')
  ]) {
    def body = JsonOutput.toJson([records: [record]])
    def url  = "${env.HARNESS_IM_URL}/api/v1/accounts/${env.HARNESS_ACCOUNT_ID}/integrations/${env.IID}/data/security_scan"

    echo "--- upsert(security_scan/dep-check) payload ---\n${JsonOutput.prettyPrint(body)}\n--- end ---"

    httpRequest(
      url:                url,
      httpMode:           'POST',
      contentType:        'APPLICATION_JSON',
      customHeaders:      [[name: 'x-api-key', value: "${env.HARNESS_API_KEY}"]],
      requestBody:        body,
      validResponseCodes: '202'
    )
    echo "Upserted security_scan record: ${identifier} (critical=${counts.critical}, high=${counts.high}, medium=${counts.medium}, low=${counts.low})"
  }
}
