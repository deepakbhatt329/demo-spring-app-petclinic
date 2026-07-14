import groovy.json.JsonOutput

def call(String kind, Map extras) {
  def iidCredId = [
    'build'          : 'iid-build',
    'deployment'     : 'iid-deployment',
    'quality'        : 'iid-quality',
    'security_issues': 'iid-security',
    'custom'         : 'iid-custom'
  ][kind]
  if (!iidCredId) {
    error "upsert(): unknown kind '${kind}'"
  }

  withCredentials([
    string(credentialsId: 'harness-api-key',    variable: 'HARNESS_API_KEY'),
    string(credentialsId: 'harness-account-id', variable: 'HARNESS_ACCOUNT_ID'),
    string(credentialsId: iidCredId,            variable: 'IID')
  ]) {
    def identifier
    switch (kind) {
      case 'build':      identifier = env.BUILD_ID_STR; break
      case 'deployment': identifier = env.DEPLOY_ID; break
      default:           identifier = extras.remove('identifier')
    }
    if (!identifier) {
      error "upsert(): no identifier resolved for kind '${kind}'"
    }

    if (!env.IDP_ENTITY_REF) {
      error "upsert(): IDP_ENTITY_REF env var is not set (populate it in bootstrap/demo.env)"
    }

    def record = [
      identifier: identifier,
      timestamp : env.ISO_TS,
      entity_ref: env.IDP_ENTITY_REF
    ] + extras

    def body = JsonOutput.toJson([records: [record]])
    def url  = "${env.HARNESS_IM_URL}/api/v1/accounts/${env.HARNESS_ACCOUNT_ID}/integrations/${env.IID}/data/${kind}"

    httpRequest(
      url:                url,
      httpMode:           'POST',
      contentType:        'APPLICATION_JSON',
      customHeaders:      [[name: 'Authorization', value: "Bearer ${env.HARNESS_API_KEY}"]],
      requestBody:        body,
      validResponseCodes: '202'
    )
  }
}
