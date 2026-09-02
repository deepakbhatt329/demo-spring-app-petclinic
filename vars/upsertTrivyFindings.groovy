import groovy.json.JsonOutput

def call(String trivyJsonPath, String idBase, Map opts = [:]) {
  def defaults = [
    status  : 'OPEN',
    type    : 'VULNERABILITY',
    rule    : 'trivy:cve',
    toolName: 'trivy',
    service : 'petclinic',
    tags    : [scanner: 'trivy']
  ]
  def cfg = defaults + opts
  if (!fileExists(trivyJsonPath)) {
    echo "No trivy report at ${trivyJsonPath} — skipping security_issues upsert."
    return
  }

  if (!env.IDP_ENTITY_REF) {
    error "upsertTrivyFindings(): IDP_ENTITY_REF env var is not set (populate it in bootstrap/demo.env)"
  }

  def report = readJSON file: trivyJsonPath
  def records = []
  (report.Results ?: []).each { result ->
    (result.Vulnerabilities ?: []).each { v ->
      records << [
        identifier    : "${idBase}-${v.VulnerabilityID}-${env.BUILD_NUMBER}",
        name          : "${v.VulnerabilityID} in ${v.PkgName}",
        timestamp     : env.ISO_TS,
        service       : cfg.service,
        entity_ref    : env.IDP_ENTITY_REF,
        url           : v.PrimaryURL ?: '',
        severity      : (v.Severity ?: 'MEDIUM'),
        status        : cfg.status,
        type          : cfg.type,
        rule          : cfg.rule,
        cve           : v.VulnerabilityID,
        packageVersion: "${v.PkgName}@${v.InstalledVersion}",
        toolName      : cfg.toolName,
        tags          : cfg.tags + [pkgType: (result.Type ?: 'unknown')]
      ]
    }
  }

  if (records.isEmpty()) {
    records << [
      identifier    : "${idBase}-clean",
      name          : "Trivy scan clean for petclinic #${env.BUILD_NUMBER}",
      timestamp     : env.ISO_TS,
      service       : cfg.service,
      entity_ref    : env.IDP_ENTITY_REF,
      severity      : 'INFO',
      status        : 'RESOLVED',
      type          : cfg.type,
      rule          : 'trivy:scan-clean',
      toolName      : cfg.toolName,
      tags          : cfg.tags
    ]
    echo "Trivy report contained no vulnerabilities — posting scan-clean marker record."
  }

  withCredentials([
    string(credentialsId: 'harness-api-key',    variable: 'HARNESS_API_KEY'),
    string(credentialsId: 'harness-account-id', variable: 'HARNESS_ACCOUNT_ID'),
    string(credentialsId: 'iid-security',       variable: 'IID')
  ]) {
    def body = JsonOutput.toJson([records: records])
    def url  = "${env.HARNESS_IM_URL}/api/v1/accounts/${env.HARNESS_ACCOUNT_ID}/integrations/${env.IID}/data/security_issues"

    echo "--- upsert(security_issues) payload (${records.size()} records) ---\n${JsonOutput.prettyPrint(body)}\n--- end ---"

    httpRequest(
      url:                url,
      httpMode:           'POST',
      contentType:        'APPLICATION_JSON',
      customHeaders:      [[name: 'x-api-key', value: "${env.HARNESS_API_KEY}"]],
      requestBody:        body,
      validResponseCodes: '202'
    )
    echo "Upserted ${records.size()} security_issues records."
  }
}
