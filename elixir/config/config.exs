import Config

# Logger configuration – can be overridden at runtime via the
# GIT_REMOTE_S3_VERBOSE environment variable (see GitRemoteS3.Remote).
config :logger, :console,
  level: :error,
  format: "$time $metadata[$level] $message\n",
  metadata: [:pid]

# ExAws base configuration.
# Credentials are resolved in this order by ExAws:
#   1. Environment variables (AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY)
#   2. ~/.aws/credentials (via profile helper in GitRemoteS3.AwsProfile)
#   3. EC2/ECS instance metadata
config :ex_aws,
  json_codec: Jason,
  http_client: ExAws.Request.Hackney

# Import environment-specific config (e.g. config/test.exs).
import_config "#{config_env()}.exs"
