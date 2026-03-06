const { Storage } = require("@google-cloud/storage");
const { ExternalAccountClient } = require("google-auth-library");

/**
 * Builds a Google external_account credential config that tells the
 * Google Auth Library how to fetch an Azure Managed Identity token
 * and exchange it for GCP credentials via Workload Identity Federation.
 *
 * Two distinct audience values are in play:
 *  - "audience" (GCP-side): the full WIF provider resource name, used by
 *    the GCP STS to identify which pool/provider handles the token.
 *  - "resource" (Azure-side): the Application ID URI of the Azure App
 *    Registration (api://<CLIENT_ID>), used as the Azure token audience.
 *    The GCP WIF provider's allowed_audiences must match this value.
 *
 * Relies on env vars injected by Azure App Service (IDENTITY_ENDPOINT,
 * IDENTITY_HEADER) and app-level configuration (GCP_*, AZURE_WIF_*).
 */
function buildCredentialConfig() {
  const identityEndpoint = process.env.IDENTITY_ENDPOINT;
  const identityHeader = process.env.IDENTITY_HEADER;
  const projectNumber = process.env.GCP_PROJECT_NUMBER;
  const poolId = process.env.GCP_WIF_POOL_ID;
  const providerId = process.env.GCP_WIF_PROVIDER_ID;
  const serviceAccountEmail = process.env.GCP_SERVICE_ACCOUNT_EMAIL;
  const azureWifAppIdUri = process.env.AZURE_WIF_APP_ID_URI;

  if (!identityEndpoint || !identityHeader) {
    throw new Error(
      "IDENTITY_ENDPOINT and IDENTITY_HEADER are not set. " +
        "This app must run in Azure App Service with Managed Identity enabled."
    );
  }

  if (!projectNumber || !poolId || !providerId || !serviceAccountEmail || !azureWifAppIdUri) {
    throw new Error(
      "Missing required env vars. Ensure GCP_PROJECT_NUMBER, GCP_WIF_POOL_ID, " +
        "GCP_WIF_PROVIDER_ID, GCP_SERVICE_ACCOUNT_EMAIL, and AZURE_WIF_APP_ID_URI are set."
    );
  }

  const gcpAudience =
    `//iam.googleapis.com/projects/${projectNumber}` +
    `/locations/global/workloadIdentityPools/${poolId}/providers/${providerId}`;

  return {
    type: "external_account",
    audience: gcpAudience,
    subject_token_type: "urn:ietf:params:oauth:token-type:jwt",
    token_url: "https://sts.googleapis.com/v1/token",
    credential_source: {
      url: `${identityEndpoint}?resource=${encodeURIComponent(azureWifAppIdUri)}&api-version=2019-08-01`,
      headers: {
        "X-IDENTITY-HEADER": identityHeader,
        Metadata: "true",
      },
      format: {
        type: "json",
        subject_token_field_name: "access_token",
      },
    },
    service_account_impersonation_url:
      `https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/${serviceAccountEmail}:generateAccessToken`,
  };
}

/**
 * Downloads a file from GCS using WIF-backed credentials.
 * @param {string} bucketName
 * @param {string} fileName
 * @returns {Promise<string>} file contents as UTF-8 text
 */
async function readFile(bucketName, fileName) {
  const credConfig = buildCredentialConfig();
  const authClient = ExternalAccountClient.fromJSON(credConfig);
  const storage = new Storage({ authClient });
  const [contents] = await storage.bucket(bucketName).file(fileName).download();
  return contents.toString("utf-8");
}

module.exports = { readFile };
